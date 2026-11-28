/**
 * agent-mobile-gateway 主入口：挂载独立手机网关 HTTP 服务与桌面设置面板路由，
 * 协调配对鉴权、提问接管桥接、会话流、工作区文件/Git/终端及本机预览代理各子模块。
 *
 * @module agent-mobile-gateway
 */
import { createHmac } from 'node:crypto'
import { EventEmitter } from 'node:events'
import { readFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { hostname } from 'node:os'
import { dirname, extname, join, resolve, sep } from 'node:path'
import { Readable } from 'node:stream'
import { fileURLToPath } from 'node:url'
import { createAskBridge } from './ask-bridge.ts'
import { BackendRegistry } from './backends/registry.ts'
import {
  generateX25519Keypair,
  NoiseCipherState,
  NoiseInitiator,
  NoiseResponder,
  x25519PublicFromPrivate,
} from './crypto/noise.ts'
import {
  hostPort,
  isLocalHostHeader,
  lanAddresses,
  parsePreviewPorts,
  presentedToken,
  readJson,
  send,
  tokenMatches,
  validatePublicUrl,
} from './http-util.ts'
import { DEFAULT_PUSH_RELAY, NotifyMonitor, sanitizeRelayUrl } from './notify-monitor.ts'
import { createPanel } from './panel.ts'
import { createDeepContextReader, createWorkspaceFlags, projectSessions } from './projections.ts'
import { createE2eeRoutes, type InternalDispatchRequest, type InternalDispatchResult } from './routes/e2ee.ts'
import { createBackendRoutes } from './routes/backends.ts'
import { createGitRoutes } from './routes/git.ts'
import { createHostExtrasRoutes } from './routes/host-extras.ts'
import { createSessionRoutes } from './routes/sessions.ts'
import { createTerminalRoutes } from './routes/terminal.ts'
import { createWebConsoleRoutes } from './routes/web-console.ts'
import { createWorkspaceFsRoutes } from './routes/workspace-fs.ts'
import {
  allowTerminal,
  answerMode,
  DEFAULT_PORT,
  dshHome,
  enabledBackends,
  lanBases,
  PairingRuntime,
  pairPayload,
  pairPrefs,
  PRESENCE_TTL_MS,
  previewPorts,
  pushTargets,
  record,
  removePushTarget,
  resolveE2eeKeypair,
  resolveHostId,
  resolveToken,
  setBackendEnabled,
  statePath,
  upsertPushTarget,
  VERSION,
  writeState,
  type AnswerMode,
  type MobileState,
  type PairPrefs,
} from './state.ts'
import { findSessionFile, historyOf, zstdDecompressSync } from './transcript.ts'

export const name = 'mobile'
export type { PairPrefs }

export interface Config {
  readonly enabled?: boolean
  readonly port?: number
  readonly host?: string
  readonly token?: string
  readonly logFile?: string
}

/** 导出给外部冒烟/纯函数测试使用的内部投影、日志读取与 Noise 加密工具。 */
export const internals = {
  projectSessions,
  findSessionFile,
  historyOf,
  generateX25519Keypair,
  x25519PublicFromPrivate,
  NoiseCipherState,
  NoiseInitiator,
  NoiseResponder,
  BackendRegistry,
}

const SIG_TTL_SEC = 300

const MIME: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
}

export function apply(ctx: any, rawConfig?: Config): void {
  const enabled = rawConfig?.enabled !== false
  const port = rawConfig?.port ?? DEFAULT_PORT
  const host = rawConfig?.host ?? '::'
  const logFile = rawConfig?.logFile ?? join(dshHome(), 'dsh-mobile.log')
  const token = enabled ? resolveToken(rawConfig?.token) : ''

  if (!enabled) return

  // 确保首次启动即持久化主机唯一 hostId 与 X25519 静态密钥对。
  const hostId = resolveHostId()
  const { pub: e2eePub } = resolveE2eeKeypair()

  const sigOf = (kind: string, value: string, exp: string): string =>
    createHmac('sha256', token).update(`${kind}\n${value}\n${exp}`).digest('hex')

  const signedOk = (kind: string, value: string, url: URL): boolean => {
    const exp = url.searchParams.get('e') ?? ''
    const sig = (url.searchParams.get('sig') ?? '').toLowerCase()
    if (exp === '' || sig === '') return false
    const expN = Number(exp)
    if (!Number.isFinite(expN) || expN < Math.floor(Date.now() / 1000)) return false
    return tokenMatches(sigOf(kind, value, exp), sig)
  }

  const controller = (): any => {
    try {
      return ctx.get('sessionController')
    } catch {
      return undefined
    }
  }

  const service = (svcName: string): any => {
    try {
      const found: unknown = ctx.get(svcName)
      return found === undefined ? null : found
    } catch {
      return null
    }
  }

  let notifyMonitor: NotifyMonitor | null = null

  const pairing = new PairingRuntime(port, logFile)
  const askBridge = createAskBridge(ctx, logFile, (sid, callId) => {
    notifyMonitor?.onDshAsk(sid, callId)
  })
  const deepContext = createDeepContextReader(service, logFile)
  const flags = createWorkspaceFlags(service)

  const backendRegistry = new BackendRegistry({
    getEnabledMap: enabledBackends,
    setEnabled: (id, on) => setBackendEnabled(id, on),
    dshVersion: VERSION,
  })
  const fsRoutes = createWorkspaceFsRoutes({
    controller,
    service,
    sigOf,
    sigTtlSec: SIG_TTL_SEC,
    logFile,
    resolveExternalCwd: async (sid: string): Promise<string> => {
      const resolved = backendRegistry.resolveBySessionId(sid)
      if (resolved.backend === 'dsh' || !resolved.driver) return ''
      const info = await resolved.driver.getMessages(resolved.rawId, { limit: 1, compact: true }).catch(() => null)
      return info?.cwd ?? ''
    },
  })
  const gitRoutes = createGitRoutes(fsRoutes)
  const terminalRoutes = createTerminalRoutes(fsRoutes, logFile)
  notifyMonitor = new NotifyMonitor({
    controller,
    askBridge,
    backendRegistry,
    markArchived: flags.markArchived,
    markPinned: flags.markPinned,
    logFile,
  })
  notifyMonitor.start()
  const backendRoutes = createBackendRoutes({
    registry: backendRegistry,
    sigOf,
    sigTtlSec: SIG_TTL_SEC,
    logFile,
  })
  const sessionRoutes = createSessionRoutes({
    controller,
    service,
    askBridge,
    deepContext,
    markArchived: flags.markArchived,
    markPinned: flags.markPinned,
    pinnedIds: flags.pinnedIds,
    sigOf,
    sigTtlSec: SIG_TTL_SEC,
    logFile,
    backendRegistry,
    onSessionsListed: (rows) => {
      if (!notifyMonitor) return rows
      notifyMonitor.observeRows(rows, true)
      return notifyMonitor.enrichRows(rows)
    },
  })
  const hostExtras = createHostExtrasRoutes({
    service,
    sigOf,
    sigTtlSec: SIG_TTL_SEC,
    logFile,
  })
  const webConsoleRoutes = createWebConsoleRoutes({ ctx, logFile })

  let handleRef!: (req: IncomingMessage, res: ServerResponse) => Promise<void>

  /** 轻量内存分发器：供 `/api/e2ee/rpc` 复用同一套 HTTP 路由处理逻辑，无需回环 TCP 连接。 */
  const dispatchInternal = async (inner: InternalDispatchRequest): Promise<InternalDispatchResult> => {
    const bodyBuf = inner.body !== undefined
      ? Buffer.from(typeof inner.body === 'string' ? inner.body : JSON.stringify(inner.body), 'utf8')
      : Buffer.alloc(0)

    const mockReq = Readable.from(bodyBuf.length > 0 ? [bodyBuf] : []) as unknown as IncomingMessage
    mockReq.method = inner.method
    mockReq.url = inner.path
    const headers: Record<string, string> = {
      host: String(inner.outerReq.headers.host ?? `127.0.0.1:${String(port)}`),
      authorization: `Bearer ${token}`,
    }
    if (bodyBuf.length > 0) {
      headers['content-type'] = 'application/json; charset=utf-8'
      headers['content-length'] = String(bodyBuf.length)
    }
    if (inner.idem !== undefined && inner.idem !== '') {
      headers['idempotency-key'] = inner.idem
    }
    mockReq.headers = headers
    ;(mockReq as unknown as { socket: unknown }).socket = inner.outerReq.socket

    return await new Promise<InternalDispatchResult>((resolveDone, rejectDone) => {
      const emitter = new EventEmitter()
      const resHeaders = new Map<string, string | string[]>()
      const chunks: Buffer[] = []
      let settled = false
      let statusCode = 200
      let headersSent = false
      let writableEnded = false
      let destroyed = false

      const finish = (): void => {
        if (settled) return
        settled = true
        const raw = Buffer.concat(chunks)
        const ctRaw = resHeaders.get('content-type')
        const ct = Array.isArray(ctRaw) ? (ctRaw[0] ?? '') : (ctRaw ?? '')
        let parsedBody: unknown
        if (raw.length === 0) {
          parsedBody = null
        } else if (ct.toLowerCase().includes('application/json')) {
          try {
            parsedBody = JSON.parse(raw.toString('utf8'))
          } catch {
            parsedBody = raw.toString('utf8')
          }
        } else if (ct === '' || ct.toLowerCase().startsWith('text/')) {
          parsedBody = raw.toString('utf8')
        } else {
          parsedBody = raw.toString('base64')
        }
        resolveDone({ status: statusCode, body: parsedBody })
      }

      const mockRes = Object.assign(emitter, {
        get statusCode(): number { return statusCode },
        set statusCode(code: number) { statusCode = code },
        get headersSent(): boolean { return headersSent },
        get writableEnded(): boolean { return writableEnded },
        get destroyed(): boolean { return destroyed },
        setHeader(name: string, value: string | number | readonly string[]): void {
          resHeaders.set(name.toLowerCase(), Array.isArray(value) ? value.map(String) : String(value))
        },
        getHeader(name: string): string | string[] | undefined {
          return resHeaders.get(name.toLowerCase())
        },
        removeHeader(name: string): void {
          resHeaders.delete(name.toLowerCase())
        },
        writeHead(code: number, hdrs?: Record<string, string | string[] | number>): unknown {
          statusCode = code
          headersSent = true
          if (hdrs !== undefined && typeof hdrs === 'object') {
            for (const [k, v] of Object.entries(hdrs)) {
              resHeaders.set(k.toLowerCase(), Array.isArray(v) ? v.map(String) : String(v))
            }
          }
          return mockRes
        },
        write(chunk: Uint8Array | string): boolean {
          headersSent = true
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
          return true
        },
        end(chunk?: Uint8Array | string): unknown {
          headersSent = true
          if (chunk !== undefined) {
            chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
          }
          writableEnded = true
          emitter.emit('finish')
          emitter.emit('close')
          finish()
          return mockRes
        },
        destroy(): unknown {
          destroyed = true
          writableEnded = true
          emitter.emit('close')
          finish()
          return mockRes
        },
      }) as unknown as ServerResponse

      void handleRef(mockReq, mockRes).then(() => {
        if (!settled) finish()
      }, (err) => {
        if (!settled) rejectDone(err)
      })
    })
  }

  const e2eeRoutes = createE2eeRoutes({ dispatchInternal, logFile })

  const WEB_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'web')

  /** 安全提供 `web/` 下的静态资源，严格校验路径边界防前缀穿越。 */
  const serveStatic = (res: ServerResponse, relative: string): void => {
    const cleanRel = relative.replace(/^[/\\]+/, '')
    const target = resolve(WEB_ROOT, cleanRel === '' ? '.' : cleanRel)
    if (!(target === WEB_ROOT || target.startsWith(WEB_ROOT + sep))) {
      send(res, 403, { error: 'forbidden' })
      return
    }
    let body: Buffer
    try {
      body = readFileSync(target)
    } catch {
      send(res, 404, { error: 'not found', path: relative })
      return
    }
    res.writeHead(200, {
      'content-type': MIME[extname(target)] ?? 'application/octet-stream',
      'content-length': String(body.length),
      'cache-control': 'no-store',
    })
    res.end(body)
  }

  const handle = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const started = Date.now()
    const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
    const path = url.pathname
    const method = req.method ?? 'GET'

    if (method === 'OPTIONS') {
      send(res, 204, '')
      return
    }

    if (path === '/health') {
      send(res, 200, { ok: true, name: 'dsh-mobile', version: VERSION, pid: process.pid, host: hostname(), hostId })
      return
    }

    if (path === '/api/pair/info') {
      const prefs = pairPrefs()
      send(res, 200, {
        ok: true,
        name: 'dsh-mobile',
        version: VERSION,
        host: hostname(),
        hostId,
        e2eePub,
        e2ee: true,
        port,
        lan: prefs.allowLan ? lanBases(port) : [],
        publicUrl: prefs.publicUrl,
        needCode: true,
      })
      return
    }

    if (path === '/api/pair/claim' && method === 'POST') {
      const prefs = pairPrefs()
      if (!prefs.allowLan && !prefs.allowRemote) {
        send(res, 403, { error: 'pairing is off', hint: 'turn 允许连接 on in the DSH panel' })
        return
      }
      const local = isLocalHostHeader(req.headers.host)
      if (local && !prefs.allowLan) {
        send(res, 403, { error: 'lan pairing is off', hint: 'turn 局域网直连 on in the DSH panel' })
        return
      }
      if (!local && !prefs.allowRemote) {
        send(res, 403, { error: 'remote pairing is off', hint: 'turn 公网访问 on in the DSH panel' })
        return
      }
      const now = Date.now()
      const peer = pairing.peerKey(req.socket.remoteAddress, local, req.headers)
      const until = pairing.lockedUntil(peer, now)
      if (until > now) {
        send(res, 429, { error: 'too many wrong codes', retryAt: until })
        return
      }
      const attempt = pairing.reserveAttempt(peer, now)
      let body: Record<string, unknown>
      try {
        body = await readJson(req)
      } catch (err) {
        const status = typeof (err as { status?: unknown })?.status === 'number' ? (err as { status: number }).status : 400
        send(res, status, { error: status === 413 ? 'body too large' : 'body must be a JSON object' })
        return
      }
      const given = String(body.code ?? '').trim()
      const verify = pairing.verifyClaim(peer, attempt, given, peer.startsWith('tunnel:'))
      if (!verify.ok) {
        await record(logFile, `401 PAIR claim bad code from ${peer} left=${String(verify.left)} rotated=${String(verify.rotated)}`)
        send(res, 401, {
          error: 'wrong code',
          code: 'bad-code',
          left: verify.left,
          rotated: verify.rotated,
        })
        return
      }

      const headerHost = req.headers.host
      const forwarded = req.headers['x-forwarded-proto']
      const scheme = typeof forwarded === 'string' && forwarded.toLowerCase() === 'https' ? 'https' : 'http'
      const lan = lanBases(port)
      const base =
        typeof headerHost === 'string' && headerHost.length > 0
          ? `${scheme}://${headerHost}`
          : (lan[0] ?? `http://127.0.0.1:${String(port)}`)
      await record(logFile, `200 PAIR claim base=${base} from ${peer} local=${String(local)}`)
      send(res, 200, {
        ok: true,
        token,
        base,
        host: hostname(),
        hostId,
        e2eePub,
        e2ee: true,
        version: VERSION,
        port,
        lan: prefs.allowLan ? lan : [],
        qr: pairPayload(base, pairing.ensurePair().code, lan.slice(1)),
      })
      return
    }

    if (path === '/api/pair/remote/request' && method === 'POST') {
      const prefs = pairPrefs()
      if (!prefs.allowLan && !prefs.allowRemote) {
        send(res, 403, { error: '电脑端已关闭允许连接，请先在 DSH 面板打开' })
        return
      }
      const local = isLocalHostHeader(req.headers.host)
      if (local && !prefs.allowLan) {
        send(res, 403, { error: '电脑端已关闭局域网配对' })
        return
      }
      if (!local && !prefs.allowRemote) {
        send(res, 403, { error: '电脑端已关闭公网远程配对，请先打开「公网访问」' })
        return
      }
      const peer = pairing.peerKey(req.socket.remoteAddress, local, req.headers)
      let body: Record<string, unknown> = {}
      try {
        body = await readJson(req)
      } catch (err) {
        const status = typeof (err as { status?: unknown })?.status === 'number' ? (err as { status: number }).status : 400
        send(res, status, { error: status === 413 ? 'body too large' : 'body must be a JSON object' })
        return
      }
      const devName = typeof body.deviceName === 'string' ? body.deviceName : ''
      const created = pairing.createRemoteRequest(peer, devName, local)
      if (!created.ok) {
        send(res, 429, { error: `请求过于频繁，请 ${String(created.retryAfterSec)} 秒后重试`, retryAfterSec: created.retryAfterSec })
        return
      }
      send(res, 200, {
        ok: true,
        requestId: created.request.id,
        secret: created.request.secret,
        verifyCode: created.request.verifyCode,
        host: hostname(),
        hostId,
        e2eePub,
        expiresAt: created.request.expiresAt,
      })
      return
    }

    if (path === '/api/pair/remote/poll' && method === 'POST') {
      const prefs = pairPrefs()
      let body: Record<string, unknown> = {}
      try {
        body = await readJson(req)
      } catch (err) {
        const status = typeof (err as { status?: unknown })?.status === 'number' ? (err as { status: number }).status : 400
        send(res, status, { error: status === 413 ? 'body too large' : 'body must be a JSON object' })
        return
      }
      const requestId = typeof body.requestId === 'string' ? body.requestId.trim() : ''
      const secret = typeof body.secret === 'string' ? body.secret.trim() : ''
      const polled = pairing.pollRemoteRequest(requestId, secret)
      if (polled.status === 'expired') {
        send(res, 404, { ok: false, status: 'expired', error: '远程配对申请已过期或不存在' })
        return
      }
      if (polled.status === 'pending') {
        send(res, 200, { ok: true, status: 'pending', expiresAt: polled.expiresAt })
        return
      }
      if (polled.status === 'rejected') {
        send(res, 200, { ok: true, status: 'rejected', error: '对方拒绝了本次远程配对申请' })
        return
      }
      const headerHost = req.headers.host
      const forwarded = req.headers['x-forwarded-proto']
      const scheme = typeof forwarded === 'string' && forwarded.toLowerCase() === 'https' ? 'https' : 'http'
      const lan = lanBases(port)
      const base =
        typeof headerHost === 'string' && headerHost.length > 0
          ? `${scheme}://${headerHost}`
          : (prefs.publicUrl || lan[0] || `http://127.0.0.1:${String(port)}`)
      send(res, 200, {
        ok: true,
        status: 'approved',
        token,
        base,
        host: hostname(),
        hostId,
        e2eePub,
        e2ee: true,
        version: VERSION,
        port,
        lan: prefs.allowLan ? lan : [],
      })
      return
    }

    // 短签名免长令牌直链通道（图片附件、工作区预览图、SSE 实时流、日志导出、本机开发服预览、网页控制台代理）
    const attSigned = path.startsWith('/api/attachments/') && method === 'GET'
      ? signedOk('att', path.slice('/api/attachments/'.length).toLowerCase(), url)
      : false
    const rawMatch = /^\/api\/sessions\/([^/]+)\/fs\/raw$/.exec(path)
    const rawSigned = rawMatch !== null && method === 'GET'
      && signedOk('raw', `${decodeURIComponent(rawMatch[1] as string)}|${url.searchParams.get('path') ?? ''}`, url)
    const streamMatch = /^\/api\/sessions\/([^/]+)\/stream$/.exec(path)
    const streamSigned = streamMatch !== null && method === 'GET'
      && signedOk('stream', decodeURIComponent(streamMatch[1] as string), url)
    const exportMatch = /^\/api\/sessions\/([^/]+)\/export$/.exec(path)
    const exportFormat = (url.searchParams.get('format') ?? 'markdown').trim().toLowerCase()
    const exportSigned = exportMatch !== null && method === 'GET'
      && (exportFormat === 'markdown' || exportFormat === 'zip')
      && signedOk('export', `${decodeURIComponent(exportMatch[1] as string)}|${exportFormat}`, url)
    const loopbackSigned = hostExtras.isLoopbackAuthorized(req, url, path, method)
    const webConsoleBypass = webConsoleRoutes.isBypassPath(path, method)

    if (
      !attSigned
      && !rawSigned
      && !streamSigned
      && !exportSigned
      && !loopbackSigned
      && !webConsoleBypass
      && !tokenMatches(presentedToken(req, url), token)
    ) {
      await record(logFile, `401 ${method} ${path} from ${req.socket.remoteAddress ?? '?'}`)
      send(res, 401, { error: 'unauthorized', hint: 'send Authorization: Bearer <token>, or ?t=<token>' })
      return
    }

    pairing.phoneSeenAt = Date.now()

    {
      const prefs = pairPrefs()
      const local = isLocalHostHeader(req.headers.host)
      if (local && !prefs.allowLan) {
        send(res, 403, { error: 'lan access is off', hint: 'turn 局域网直连 on in the DSH panel' })
        return
      }
      if (!local && !prefs.allowRemote) {
        send(res, 403, { error: 'remote access is off', hint: 'turn 公网访问 on in the DSH panel' })
        return
      }
    }

    try {
      if (path === '/' || path === '/index.html') {
        serveStatic(res, 'index.html')
        return
      }

      if (path.startsWith('/app/')) {
        serveStatic(res, path.slice('/app/'.length))
        return
      }

      if (path === '/api/info') {
        send(res, 200, {
          ok: true,
          version: VERSION,
          host: hostname(),
          hostId,
          e2eePub,
          e2ee: true,
          addresses: lanAddresses(),
          port,
          sessions: true,
          messages: zstdDecompressSync !== undefined,
          send: true,
          stop: true,
          create: true,
          rename: true,
          pin: true,
          images: true,
          files: true,
          attachments: true,
          stream: true,
          git: true,
          terminal: allowTerminal(),
          plan: true,
          commands: true,
          webConsole: webConsoleRoutes.isReady(),
          loopback: previewPorts().length > 0,
          push: true,
        })
        return
      }

      if (path === '/api/presence') {
        let online = true
        let sessionId = String(url.searchParams.get('sessionId') ?? '').trim()
        if (method === 'POST') {
          const body = await readJson(req).catch(() => undefined)
          if (body !== undefined && typeof body === 'object' && body !== null) {
            const b = body as { online?: unknown; sessionId?: unknown }
            if (b.online === false) online = false
            if (typeof b.sessionId === 'string' && b.sessionId.trim() !== '') {
              sessionId = b.sessionId.trim()
            }
          }
        }
        pairing.phoneSeenAt = online ? Date.now() : 0
        notifyMonitor?.updatePresence(online, sessionId)
        send(res, 200, {
          ok: true,
          online,
          ttlMs: PRESENCE_TTL_MS,
          sessionId,
        })
        return
      }

      if (path === '/api/push/register' && method === 'POST') {
        const body = await readJson(req)
        const pushToken = String(body.pushToken ?? '').trim()
        if (pushToken.length < 16 || pushToken.length > 512) {
          send(res, 400, { ok: false, error: 'invalid pushToken' })
          return
        }
        const deviceId = String(body.deviceId ?? '').trim() || pushToken.slice(0, 16)
        const relayUrl = sanitizeRelayUrl(typeof body.relayUrl === 'string' ? body.relayUrl : DEFAULT_PUSH_RELAY)
        const relaySecret = typeof body.relaySecret === 'string' ? body.relaySecret.trim() : ''
        const enabled = body.enabled !== false
        const bgOnly = body.bgOnly !== false
        const showTitle = body.showTitle !== false
        const list = upsertPushTarget({
          deviceId,
          pushToken,
          relayUrl,
          relaySecret,
          enabled,
          bgOnly,
          showTitle,
          updatedAt: Date.now(),
        })
        await record(
          logFile,
          `200 PUSH register device=${deviceId} enabled=${String(enabled)} bgOnly=${String(bgOnly)} bound=${relaySecret.length >= 32 ? '1' : '0'}`,
        )
        send(res, 200, { ok: true, count: list.length })
        return
      }

      if ((path === '/api/push/unregister' && method === 'POST') || (path === '/api/push/register' && method === 'DELETE')) {
        const body = method === 'POST' ? await readJson(req).catch(() => ({})) : {}
        const key = String((body as Record<string, unknown>).deviceId ?? (body as Record<string, unknown>).pushToken ?? url.searchParams.get('deviceId') ?? '')
        const list = removePushTarget(key)
        send(res, 200, { ok: true, count: list.length })
        return
      }

      if (path === '/api/push/status' && method === 'GET') {
        const targets = pushTargets()
        const devId = (url.searchParams.get('deviceId') ?? '').trim()
        const clientState = (url.searchParams.get('clientState') ?? '').trim()
        const errCode = (url.searchParams.get('errCode') ?? '').trim()
        if (devId !== '' && (errCode !== '' || (clientState !== '' && clientState !== 'ready'))) {
          await record(
            logFile,
            `PUSH status device=${devId} clientState=${clientState || '-'} errCode=${errCode || '0'}`,
          )
        }
        const relay = await notifyMonitor!.relayStatus(url.searchParams.get('relayUrl') ?? undefined)
        send(res, 200, {
          ok: true,
          registeredCount: targets.length,
          enabledCount: targets.filter((t) => t.enabled).length,
          boundCount: targets.filter((t) => t.relaySecret.length >= 32).length,
          currentDeviceRegistered: devId !== '' ? targets.some((t) => t.deviceId === devId) : targets.length > 0,
          relayOk: relay.ok,
          relayConfigured: relay.configured,
          category: relay.category ?? 'WORK',
          testMode: relay.testMode === true,
          relayError: relay.error ?? '',
        })
        return
      }

      if (path === '/api/push/test' && method === 'POST') {
        const body = await readJson(req).catch(() => ({})) as Record<string, unknown>
        const deviceId = String(body.deviceId ?? body.pushToken ?? '')
        const relayUrl = typeof body.relayUrl === 'string' ? body.relayUrl : undefined
        const result = await notifyMonitor!.sendTestPush(deviceId, relayUrl)
        send(res, result.ok ? 200 : 200, result)
        return
      }

      if (path === '/api/answer-mode' && method === 'GET') {
        send(res, 200, { ok: true, mode: answerMode() })
        return
      }

      if (path === '/api/answer-mode' && method === 'POST') {
        const body = await readJson(req)
        const wanted = body.mode
        if (wanted !== 'phone' && wanted !== 'desktop') {
          send(res, 400, { error: 'mode must be "phone" or "desktop"' })
          return
        }
        const persisted = writeState({ answerMode: wanted }, (error) => {
          void record(logFile, `answer mode persist failed: ${String(error)}`)
        })
        if (!persisted) {
          await record(logFile, `500 ANSWER wanted=${wanted} persist failed`)
          send(res, 500, { ok: false, error: 'answer mode not saved', mode: answerMode() })
          return
        }
        if (wanted === 'desktop') {
          askBridge.delegateAll('api-answer-mode-desktop')
        }
        await record(logFile, `200 ANSWER mode=${wanted}`)
        send(res, 200, { ok: true, mode: wanted })
        return
      }

      if (path === '/api/pair/state' && method === 'GET') {
        send(res, 200, pairing.snapshot())
        return
      }

      if (path === '/api/pair/newcode' && method === 'POST') {
        pairing.rotatePair(true)
        send(res, 200, pairing.snapshot())
        return
      }

      if (path === '/api/pair/invite' && method === 'POST') {
        const inv = pairing.buildRemoteInvitePayload(true)
        if (!inv.ok) {
          send(res, 409, { error: '当前没有可用的连接地址，请先开启局域网或配置公网地址' })
          return
        }
        send(res, 200, inv)
        return
      }

      if (path === '/api/pair/requests' && method === 'GET') {
        send(res, 200, { ok: true, requests: pairing.listPendingRemoteRequests() })
        return
      }

      if (path === '/api/pair/requests/decide' && method === 'POST') {
        const body = await readJson(req)
        const id = typeof body.id === 'string' ? body.id.trim() : ''
        if (id === '' || typeof body.approve !== 'boolean') {
          send(res, 400, { error: 'id 不能为空且 approve 必须为布尔值' })
          return
        }
        const resDecide = pairing.decideRemoteRequest(id, body.approve)
        if (!resDecide.ok) {
          send(res, 404, { error: resDecide.error })
          return
        }
        send(res, 200, { ok: true, status: resDecide.status, requests: pairing.listPendingRemoteRequests() })
        return
      }

      if (path === '/api/pair/config' && method === 'POST') {
        const body = await readJson(req)
        const current = pairPrefs()
        let publicUrl = current.publicUrl
        if (body.publicUrl !== undefined) {
          if (typeof body.publicUrl !== 'string') {
            send(res, 400, { error: '公网地址必须是字符串' })
            return
          }
          const checked = validatePublicUrl(body.publicUrl)
          if (!checked.ok) {
            send(res, 400, { error: checked.error })
            return
          }
          publicUrl = checked.url
        }

        const nextPair: PairPrefs = {
          allowLan: typeof body.allowLan === 'boolean' ? body.allowLan : current.allowLan,
          allowRemote: typeof body.allowRemote === 'boolean' ? body.allowRemote : current.allowRemote,
          publicUrl,
        }
        const patch: Partial<MobileState> = { pair: nextPair }

        if (body.answerMode !== undefined) {
          if (body.answerMode !== 'phone' && body.answerMode !== 'desktop') {
            send(res, 400, { error: '回答模式只能是 phone 或 desktop' })
            return
          }
          patch.answerMode = body.answerMode as AnswerMode
        }
        if (body.allowTerminal !== undefined) {
          if (typeof body.allowTerminal !== 'boolean') {
            send(res, 400, { error: 'allowTerminal 必须是布尔值' })
            return
          }
          patch.allowTerminal = body.allowTerminal
        }
        if (body.previewPorts !== undefined) {
          const checkedPorts = parsePreviewPorts(body.previewPorts)
          if (!checkedPorts.ok) {
            send(res, 400, { error: checkedPorts.error })
            return
          }
          patch.previewPorts = checkedPorts.ports
        }

        writeState(patch)
        if (patch.answerMode === 'desktop') {
          askBridge.delegateAll('pair-config-desktop')
        }
        await record(logFile, `200 PAIR config lan=${String(nextPair.allowLan)} remote=${String(nextPair.allowRemote)}`)
        send(res, 200, pairing.snapshot())
        return
      }

      if (path === '/api/attachments/sign' && method === 'POST') {
        const body = await readJson(req)
        const ids = Array.isArray(body.ids) ? body.ids : []
        if (ids.length > 64) {
          send(res, 400, { error: 'at most 64 ids per request' })
          return
        }
        const exp = String(Math.floor(Date.now() / 1000) + SIG_TTL_SEC)
        const items = ids
          .map((raw) => String(raw).toLowerCase())
          .filter((id) => /^[0-9a-f]{8,128}$/.test(id))
          .map((id) => ({ id, e: exp, sig: sigOf('att', id, exp) }))
        send(res, 200, { ok: true, items })
        return
      }

      if (path.startsWith('/api/attachments/') && method === 'GET') {
        const digest = path.slice('/api/attachments/'.length).toLowerCase()
        if (!/^[0-9a-f]{8,128}$/.test(digest)) {
          send(res, 400, { error: 'bad attachment id' })
          return
        }
        const file = join(dshHome(), 'attachments', 'v1', 'objects', digest.slice(0, 2), digest)
        let body: Buffer
        try {
          body = readFileSync(file)
        } catch {
          send(res, 404, { error: 'attachment not found', id: digest })
          return
        }
        const asked = String(url.searchParams.get('m') ?? '')
        const type =
          asked === 'image/jpeg' || asked === 'image/webp' || asked === 'image/gif' || asked === 'image/png'
            ? asked
            : 'image/png'
        res.writeHead(200, {
          'content-type': type,
          'content-length': String(body.length),
          'cache-control': 'private, max-age=86400',
        })
        res.end(body)
        return
      }

      if (await webConsoleRoutes.tryHandle(req, res, url, path, method)) return
      if (await e2eeRoutes.tryHandle(req, res, url, path, method)) return
      if (await backendRoutes.tryHandle(req, res, url, path, method)) return
      if (await fsRoutes.tryHandle(req, res, url, path, method)) return
      if (await gitRoutes.tryHandle(req, res, url, path, method)) return
      if (await terminalRoutes.tryHandle(req, res, url, path, method)) return
      if (await hostExtras.tryHandle(req, res, url, path, method)) return
      if (await sessionRoutes.tryHandle(req, res, url, path, method)) return

      send(res, 404, { error: 'not found', path })
    } catch (error) {
      const status = typeof (error as { status?: unknown })?.status === 'number'
        ? (error as { status: number }).status
        : 500
      const message = error instanceof Error ? error.message : String(error)
      await record(logFile, `${String(status)} ${method} ${path} ${message}`)
      if (!res.headersSent) {
        send(res, status, { error: message })
      } else {
        res.destroy()
      }
    } finally {
      const qp: string[] = []
      url.searchParams.forEach((v: string, k: string) => {
        qp.push(`${k}=${k === 't' || k === 'payload' || k === 'sig' || k === 'g' ? '***' : v}`)
      })
      const q = qp.length === 0 ? '' : `?${qp.join('&').slice(0, 40)}`
      void record(logFile, `${String(res.statusCode)} ${method} ${path}${q} ${String(Date.now() - started)}ms`)
    }
  }
  handleRef = handle

  const panel = createPanel({
    pairState: () => pairing.snapshot(),
    pendingAsks: () => askBridge.listLive(),
    pendingPairRequests: () => pairing.listPendingRemoteRequests(),
    decidePairRequest: (id, approve) => {
      const r = pairing.decideRemoteRequest(id, approve)
      return r.ok ? { ok: true } : { ok: false, error: r.error }
    },
    takeoverAsk: (callId, switchToDesktop) => {
      if (switchToDesktop === true) {
        writeState({ answerMode: 'desktop' })
        const delegated = askBridge.delegateAll('panel-takeover-desktop')
        return { delegated, pending: askBridge.listLive() }
      }
      if (callId !== undefined && callId !== '') {
        const delegated = askBridge.delegateOne(callId, 'panel-takeover') ? 1 : 0
        return { delegated, pending: askBridge.listLive() }
      }
      const delegated = askBridge.delegateAll('panel-takeover-all')
      return { delegated, pending: askBridge.listLive() }
    },
    rotatePair: () => {
      pairing.rotatePair(true)
    },
    writePrefs: (next) => {
      writeState({
        pair: {
          allowLan: next.allowLan,
          allowRemote: next.allowRemote,
          publicUrl: next.publicUrl,
        },
        answerMode: next.answerMode,
        allowTerminal: next.allowTerminal,
        previewPorts: next.previewPorts,
      })
      if (next.answerMode === 'desktop') {
        askBridge.delegateAll('panel-answer-mode-desktop')
      }
    },
    revokeDevice: (deviceId, revoked) => e2eeRoutes.revokeDevice(deviceId, revoked),
    pairPayload: (base, code, alts) => pairPayload(base, code, alts),
    record: (line) => record(logFile, line),
  })

  try {
    ctx.inject(['connection'], (connCtx: any) => {
      const registry = connCtx?.connection?.fetch
      if (registry === undefined || typeof registry.register !== 'function') {
        void record(logFile, 'panel routes skipped: connection.fetch unavailable')
        return
      }
      for (const route of panel.routes) {
        try {
          const dispose = registry.register(route)
          connCtx.effect(() => dispose, `dsh-mobile: panel ${String(route.path)}`)
        } catch (error) {
          void record(logFile, `panel route ${String(route.path)} not registered: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
      void record(logFile, 'panel routes registered on connection.fetch')
    })
  } catch (error) {
    void record(logFile, `panel registration failed: ${error instanceof Error ? error.message : String(error)}`)
  }

  const server = createServer((req, res) => {
    void handle(req, res).catch(() => {
      try {
        if (!res.headersSent) {
          send(res, 500, { error: 'internal gateway error' })
        } else {
          res.destroy()
        }
      } catch {
        // ignore
      }
    })
  })

  server.on('upgrade', (req, socket, head) => {
    const prefs = pairPrefs()
    const local = isLocalHostHeader(req.headers.host)
    if ((local && !prefs.allowLan) || (!local && !prefs.allowRemote)) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
      socket.destroy()
      return
    }
    if (!webConsoleRoutes.handleUpgrade(req, socket, head)) {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n')
      socket.destroy()
    }
  })

  ctx.effect(function* () {
    server.on('error', (error: NodeJS.ErrnoException) => {
      void record(logFile, `listen failed on ${host}:${String(port)} ${error.code ?? ''} ${error.message}`)
    })
    server.listen(port, host, () => {
      const urls = lanAddresses().map((a) => `http://${hostPort(a, port)}/?t=<token>`)
      void record(logFile, `listening on ${host}:${String(port)}; urls ${urls.join(' ')}`)
      process.stdout.write(`[dsh-mobile] listening on ${host}:${String(port)} token file ${statePath()}\n`)
    })
    yield () => {
      void record(logFile, 'disposing; releasing live asks, streams, terminals, e2ee, web-console and listener')
      askBridge.delegateAll('plugin-dispose')
      notifyMonitor?.dispose()
      backendRoutes.disposeStreams()
      backendRegistry.dispose()
      sessionRoutes.disposeStreams()
      terminalRoutes.disposeTerminals()
      webConsoleRoutes.dispose()
      e2eeRoutes.dispose()
      server.close()
      server.closeAllConnections?.()
    }
  }, 'mobile listener')
}
