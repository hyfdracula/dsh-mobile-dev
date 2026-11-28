/**
 * 多 Agent 后端路由（Codex / Claude Code / OpenCode / Antigravity）：
 * - `GET /api/backends` & `POST /api/backends/:id/toggle`：探测与开关；
 * - `POST /api/sessions`（当 `backend !== 'dsh'`）：创建外部后端会话；
 * - 所有带 `codex:` / `claude:` / `opencode:` / `antigravity:` 前缀的 `/api/sessions/:id/*` 请求：
 *   统一转交对应驱动，复用相同 JSON 与 SSE `event: update` 契约，自动继承 E2EE 端到端加密。
 */
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { BackendRegistry } from '../backends/registry.ts'
import type {
  AgentBackend,
  BackendId,
  BackendImageInput,
  BackendStreamEvent,
} from '../backends/types.ts'
import { readJson, send } from '../http-util.ts'
import { record } from '../state.ts'
import type { ChatMessage, ToolTrace } from '../transcript.ts'

export interface BackendRoutesDeps {
  registry: BackendRegistry
  sigOf: (kind: string, value: string, exp: string) => string
  sigTtlSec: number
  logFile: string
}

export interface BackendRoutesBundle {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  disposeStreams: () => void
}

function parseImagesFromBody(body: Record<string, unknown>): BackendImageInput[] {
  const raw = Array.isArray(body.images) ? body.images : []
  const out: BackendImageInput[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const o = item as Record<string, unknown>
    const data = typeof o.data === 'string' ? o.data : typeof o.base64 === 'string' ? o.base64 : ''
    const mime = typeof o.mime === 'string' ? o.mime : typeof o.mediaType === 'string' ? o.mediaType : 'image/jpeg'
    if (data.length > 0) {
      out.push({ mime, data, name: typeof o.name === 'string' ? o.name : undefined })
    }
  }
  return out
}

function buildAskPayload(driver: AgentBackend, rawId: string): { active: Array<Record<string, unknown>>; mode: string } {
  const ask = driver.getAsk(rawId).pending
  if (!ask) return { active: [], mode: 'phone' }
  return {
    mode: 'phone',
    active: [
      {
        callId: ask.askId,
        id: ask.askId,
        state: 'pending',
        synthetic: true,
        sessionId: ask.sessionId,
        createdAt: ask.createdAt,
        questions: ask.questions.map((q, idx) => ({
          id: `q${String(idx)}`,
          header: q.header,
          prompt: q.question,
          question: q.question,
          multiSelect: q.multiSelect === true,
          options: q.options.map((o) => ({
            label: o.label,
            description: o.description ?? '',
          })),
        })),
      },
    ],
  }
}

export function createBackendRoutes(deps: BackendRoutesDeps): BackendRoutesBundle {
  const activeStreamClosers = new Set<() => void>()

  const streamExternalSession = async (
    res: ServerResponse,
    sessionId: string,
    rawId: string,
    driver: AgentBackend,
    limit: number,
  ): Promise<void> => {
    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    })

    let closed = false
    const writeSse = (chunk: string): void => {
      if (closed || res.writableEnded || res.destroyed) return
      try {
        res.write(chunk)
      } catch {
        cleanup()
      }
    }

    let baseMessages: ChatMessage[] = []
    let liveAssistant: ChatMessage | null = null
    let running = driver.isRunning(rawId)
    let lastErr: { code: string; text: string; time: number } | null = null
    let lastPushedFp = ''
    let pollBusy = false

    const buildSnapshotFingerprint = (merged: readonly ChatMessage[], isRunning: boolean): string => {
      const tail = merged.length > 0 ? merged[merged.length - 1] : undefined
      const toolsSig = tail?.tools
        ? tail.tools.map((t) => `${t.id}:${t.name}:${t.status}:${String(t.summary.length)}`).join(',')
        : ''
      const turnSig = tail?.turn ? `${tail.turn.status}:${String(tail.turn.tokensOut)}` : ''
      const ask = driver.getAsk(rawId).pending
      return [
        String(merged.length),
        isRunning ? '1' : '0',
        String(tail?.seq ?? 0),
        tail?.role ?? '',
        String(tail?.text.length ?? 0),
        tail?.text.slice(-48) ?? '',
        String(tail?.thinking?.length ?? 0),
        tail?.thinking?.slice(-48) ?? '',
        toolsSig,
        turnSig,
        ask?.askId ?? '',
        lastErr?.text ?? '',
      ].join('|')
    }

    const loadBase = async (): Promise<void> => {
      try {
        const resMsg = await driver.getMessages(rawId, { limit })
        baseMessages = resMsg.messages.map((m, idx) => ({ ...m, seq: m.seq || idx + 1 }))
        running = resMsg.running
      } catch {
        // keep current base
      }
    }

    const pushSnapshot = (force = false): void => {
      const merged: ChatMessage[] = liveAssistant ? [...baseMessages, liveAssistant] : [...baseMessages]
      const fp = buildSnapshotFingerprint(merged, running)
      if (!force && fp === lastPushedFp) return
      lastPushedFp = fp
      const total = merged.length > 0 ? Math.max(merged.length, merged[merged.length - 1]?.seq ?? merged.length) : 0
      const windowMsgs = merged.slice(-40)
      const firstSeq = windowMsgs.length > 0 ? (windowMsgs[0]?.seq ?? 1) : 1
      const payload = {
        ok: true,
        sessionId,
        total,
        firstSeq,
        messages: windowMsgs,
        lastTurn: null,
        lastErr,
        running,
        context: null,
        plan: { active: false, pending: false },
        queue: [],
        questions: buildAskPayload(driver, rawId),
      }
      writeSse(`event: update\ndata: ${JSON.stringify(payload)}\n\n`)
    }

    const ensureLive = (): ChatMessage => {
      if (!liveAssistant) {
        const nextSeq = (baseMessages.length > 0 ? baseMessages[baseMessages.length - 1]!.seq : 0) + 1
        liveAssistant = {
          seq: nextSeq,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
          time: Date.now(),
        }
      }
      return liveAssistant
    }

    let flushTimer: ReturnType<typeof setTimeout> | null = null
    const scheduleFlush = (): void => {
      if (flushTimer || closed) return
      flushTimer = setTimeout(() => {
        flushTimer = null
        pushSnapshot()
      }, 120)
    }

    const onEvent = (ev: BackendStreamEvent): void => {
      if (closed) return
      if (ev.type === 'status') {
        running = ev.running === true
        if (running) {
          lastErr = null
          void loadBase().then(() => pushSnapshot())
        } else {
          pushSnapshot()
        }
        return
      }
      if (ev.type === 'delta' && ev.text) {
        running = true
        const a = ensureLive()
        a.text += ev.text
        scheduleFlush()
        return
      }
      if (ev.type === 'thinking' && ev.thinking) {
        running = true
        const a = ensureLive()
        a.thinking = (a.thinking ?? '') + ev.thinking
        scheduleFlush()
        return
      }
      if (ev.type === 'tool') {
        running = true
        const a = ensureLive()
        if (!a.tools) a.tools = []
        const tid = ev.toolId || `t-${a.tools.length}`
        const st: ToolTrace['status'] =
          ev.toolStatus === 'error' ? 'err' : ev.toolStatus === 'done' ? 'ok' : 'run'
        const summary = (ev.toolInput || ev.toolOutput || ev.toolName || 'tool').slice(0, 200)
        const existing = a.tools.find((t) => t.id === tid)
        if (existing) {
          if (ev.toolName) existing.name = ev.toolName
          if (summary) existing.summary = summary
          existing.status = st
        } else {
          a.tools.push({ id: tid, name: ev.toolName || 'tool', summary, status: st })
        }
        scheduleFlush()
        return
      }
      if (ev.type === 'ask') {
        pushSnapshot()
        return
      }
      if (ev.type === 'error' && ev.error) {
        lastErr = { code: 'backend_error', text: ev.error, time: Date.now() }
        pushSnapshot()
        return
      }
      if (ev.type === 'done') {
        running = false
        const finalLive = liveAssistant
        liveAssistant = null
        void loadBase().then(() => {
          // 若后端尚未落盘刚完成的回复，把 finalLive 保留在视图里避免闪白
          if (
            finalLive &&
            finalLive.text.trim() !== '' &&
            (baseMessages.length === 0 || baseMessages[baseMessages.length - 1]?.role !== 'assistant')
          ) {
            baseMessages = [...baseMessages, { ...finalLive, seq: baseMessages.length + 1 }]
          }
          pushSnapshot()
        })
      }
    }

    const unsubscribe = driver.subscribe(rawId, onEvent)
    // 定期轻量同步桌面端直接发起的新消息、思考过程与运行状态（通过增量 stat/offset，无变更零推送）
    const pollTimer = setInterval(() => {
      if (closed || pollBusy || liveAssistant !== null) return
      pollBusy = true
      void loadBase()
        .then(() => pushSnapshot(false))
        .finally(() => {
          pollBusy = false
        })
    }, 650)
    const pingTimer = setInterval(() => {
      writeSse(': ping\n\n')
    }, 15_000)

    const cleanup = (): void => {
      if (closed) return
      closed = true
      if (flushTimer) {
        clearTimeout(flushTimer)
        flushTimer = null
      }
      clearInterval(pollTimer)
      clearInterval(pingTimer)
      unsubscribe()
      activeStreamClosers.delete(cleanup)
      try {
        if (!res.writableEnded) res.end()
      } catch {
        // ignore
      }
    }

    activeStreamClosers.add(cleanup)
    res.on('close', cleanup)
    res.on('error', cleanup)

    await loadBase()
    pushSnapshot(true)
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    // 1. 列出全部 Agent 后端及本机检测状态
    if (path === '/api/backends' && method === 'GET') {
      const refresh = url.searchParams.get('refresh') === '1'
      const backends = await deps.registry.listBackendInfos(refresh)
      send(res, 200, { ok: true, backends })
      return true
    }

    // 2. 开关某个外部后端
    const toggleMatch = /^\/api\/backends\/(codex|claude|opencode|antigravity)\/toggle$/.exec(path)
    if (toggleMatch && method === 'POST') {
      const id = toggleMatch[1] as BackendId
      const body = await readJson(req)
      const want = body.enabled === true
      const backend = await deps.registry.toggle(id, want)
      await record(deps.logFile, `200 BACKEND toggle ${id}=${String(want)}`)
      send(res, 200, { ok: true, backend })
      return true
    }

    // 3. 新建外部后端会话（若 body.backend 未传或为 'dsh'，交由原有 sessionRoutes 处理）
    if (path === '/api/sessions' && method === 'POST') {
      const body = await readJson(req)
      const backendRaw = typeof body.backend === 'string' ? body.backend.trim().toLowerCase() : 'dsh'
      if (backendRaw === '' || backendRaw === 'dsh') {
        // 把已解析好的 body 挂回 req 避免 sessionRoutes 重复 readJson 读空流
        ;(req as unknown as { __parsedBody?: Record<string, unknown> }).__parsedBody = body
        return false
      }
      const id = backendRaw as BackendId
      const driver = deps.registry.getExternal(id)
      if (!driver) {
        send(res, 400, { error: `不支持的后端类型: ${backendRaw}` })
        return true
      }
      if (!deps.registry.isEnabled(id)) {
        send(res, 403, { error: `${driver.label} 后端尚未开启，请先在「设置 -> Agent 引擎与协作」中开启` })
        return true
      }
      const cwd = typeof body.cwd === 'string' ? body.cwd.trim() : ''
      const title = typeof body.title === 'string' ? body.title.trim() : undefined
      const model = typeof body.model === 'string' ? body.model.trim() : undefined
      const created = await driver.createSession(cwd, { title, model })
      await record(deps.logFile, `200 POST create external session=${created.id}`)
      send(res, 200, { ok: true, sessionId: created.id, backend: id, session: created })
      return true
    }

    // 3.5 模型与权限查询（带外部 sessionId 时拦截，兼容 AgentConfigApi）
    if (path === '/api/models' && method === 'GET') {
      const sidParam = (url.searchParams.get('sessionId') ?? '').trim()
      if (sidParam !== '') {
        const resolvedM = deps.registry.resolveBySessionId(sidParam)
        if (resolvedM.backend !== 'dsh' && resolvedM.driver) {
          const msgInfo = await resolvedM.driver.getMessages(resolvedM.rawId, { limit: 1 }).catch(() => null)
          const list = await resolvedM.driver.listModels()
          const curModel = msgInfo?.model ?? ''
          send(res, 200, {
            ok: true,
            sessionId: sidParam,
            catalog: {
              current: curModel ? { provider: resolvedM.backend, model: curModel, reasoningEffort: '' } : null,
              routable: true,
              groups: list.length > 0
                ? [
                    {
                      id: resolvedM.backend,
                      name: resolvedM.driver.label,
                      models: list.map((m) => ({
                        id: m.id,
                        name: m.name,
                        description: m.description ?? '',
                        efforts: [],
                        defaultEffort: '',
                      })),
                    },
                  ]
                : [],
              failures: [],
            },
          })
          return true
        }
      }
      return false
    }

    if (path === '/api/permissions' && method === 'GET') {
      const sidParam = (url.searchParams.get('sessionId') ?? '').trim()
      if (sidParam !== '') {
        const resolvedP = deps.registry.resolveBySessionId(sidParam)
        if (resolvedP.backend !== 'dsh' && resolvedP.driver) {
          send(res, 200, { ok: true, current: '', presets: [] })
          return true
        }
      }
      return false
    }

    // 4. 所有带外部后端前缀（codex: / claude: / opencode:）的会话接口
    const sessMatch = /^\/api\/sessions\/([^/]+)(?:\/(.+))?$/.exec(path)
    if (!sessMatch) return false
    const sessionId = decodeURIComponent(sessMatch[1] as string)
    const sub = sessMatch[2] ?? ''
    const resolved = deps.registry.resolveBySessionId(sessionId)
    if (resolved.backend === 'dsh' || !resolved.driver) {
      return false
    }

    const driver = resolved.driver
    const rawId = resolved.rawId
    if (!deps.registry.isEnabled(resolved.backend)) {
      send(res, 403, { error: `${driver.label} 后端已关闭` })
      return true
    }

    if (sub === 'messages' && method === 'GET') {
      const limitRaw = Number(url.searchParams.get('limit') ?? '50')
      const limit = Number.isFinite(limitRaw) && limitRaw > 0 ? Math.min(limitRaw, 200) : 50
      const sinceRaw = url.searchParams.get('since')
      const since = sinceRaw !== null && sinceRaw !== '' ? Number(sinceRaw) : NaN
      const beforeRaw = url.searchParams.get('before')
      const before = beforeRaw !== null && beforeRaw !== '' ? Number(beforeRaw) : NaN
      const compact = url.searchParams.get('compact') === '1'
      const needAll = Number.isFinite(before) && before > 0
      const data = await driver.getMessages(rawId, { limit: needAll ? 0 : limit, compact })
      const allMsgs = data.messages.map((m, idx) => ({ ...m, seq: m.seq || idx + 1 }))
      let msgs: ChatMessage[]
      let hasMore = data.hasMore
      if (Number.isFinite(since) && since >= 0) {
        msgs = allMsgs.filter((m) => m.seq > since)
      } else if (needAll) {
        const older = allMsgs.filter((m) => m.seq < before)
        msgs = older.slice(-limit)
        hasMore = older.length > msgs.length
      } else {
        msgs = allMsgs
      }
      const firstSeq = msgs.length > 0 ? (msgs[0]?.seq ?? 1) : (allMsgs.length > 0 ? (allMsgs[0]?.seq ?? 1) : 1)
      send(res, 200, {
        ok: true,
        sessionId,
        backend: resolved.backend,
        capabilities: driver.capabilities,
        total: data.total,
        firstSeq,
        hasMore,
        messages: msgs,
        running: data.running,
        model: data.model ? { provider: resolved.backend, model: data.model } : null,
        cwd: data.cwd ?? '',
        context: null,
        plan: { active: false, pending: false },
        queue: [],
        questions: buildAskPayload(driver, rawId),
        lastTurn: null,
        lastErr: null,
      })
      return true
    }

    if ((sub === 'messages' || sub === 'send' || sub === 'outbox') && method === 'POST') {
      const body = await readJson(req)
      const text = typeof body.text === 'string' ? body.text : typeof body.content === 'string' ? body.content : ''
      const images = parseImagesFromBody(body)
      const model = typeof body.model === 'string' ? body.model.trim() : undefined
      const cwd = typeof body.cwd === 'string' ? body.cwd.trim() : undefined
      const result = await driver.sendMessage(rawId, text, { images, model, cwd })
      await record(deps.logFile, `200 POST send external session=${sessionId}`)
      send(res, 200, { ...result, parts: (text.trim() !== '' ? 1 : 0) + images.length })
      return true
    }

    if (sub === 'stream/sign' && method === 'POST') {
      const exp = String(Math.floor(Date.now() / 1000) + deps.sigTtlSec)
      const sig = deps.sigOf('stream', sessionId, exp)
      send(res, 200, { ok: true, e: exp, sig })
      return true
    }

    if (sub === 'stream' && method === 'GET') {
      const limit = Number(url.searchParams.get('limit') ?? '50')
      await streamExternalSession(res, sessionId, rawId, driver, Number.isFinite(limit) && limit > 0 ? limit : 50)
      return true
    }

    if ((sub === 'abort' || sub === 'stop') && method === 'POST') {
      await driver.abort(rawId)
      send(res, 200, { ok: true, accepted: true })
      return true
    }

    if (sub === 'ask' && method === 'GET') {
      send(res, 200, { ok: true, ...buildAskPayload(driver, rawId) })
      return true
    }

    if ((sub === 'ask' || sub === 'questions/answer') && method === 'POST') {
      const body = await readJson(req)
      const askId =
        typeof body.callId === 'string'
          ? body.callId
          : typeof body.askId === 'string'
            ? body.askId
            : typeof body.id === 'string'
              ? body.id
              : ''
      const answers: Record<string, string> = {}
      if (Array.isArray(body.answers)) {
        for (const item of body.answers) {
          if (!item || typeof item !== 'object') continue
          const a = item as Record<string, unknown>
          const qid = typeof a.id === 'string' ? a.id : 'q0'
          const sel = Array.isArray(a.selected) && a.selected.length > 0 ? String(a.selected[0]) : ''
          const txt = typeof a.text === 'string' ? a.text : ''
          answers[qid] = sel || txt
        }
      } else if (body.answers && typeof body.answers === 'object') {
        for (const [k, v] of Object.entries(body.answers as Record<string, unknown>)) {
          answers[k] = typeof v === 'string' ? v : Array.isArray(v) ? String(v[0] ?? '') : String(v ?? '')
        }
      }
      const ok = await driver.answerAsk(rawId, askId, answers)
      send(res, ok ? 200 : 404, ok ? { ok: true } : { error: '未找到待处理的审批请求' })
      return true
    }

    if (sub === 'models' && method === 'GET') {
      const msgInfo = await driver.getMessages(rawId, { limit: 1 }).catch(() => null)
      const list = await driver.listModels()
      const curModel = msgInfo?.model ?? ''
      send(res, 200, {
        ok: true,
        current: curModel ? { provider: resolved.backend, model: curModel } : null,
        catalog: list.length > 0
          ? [
              {
                id: resolved.backend,
                name: driver.label,
                models: list.map((m) => ({
                  id: m.id,
                  name: m.name,
                  provider: m.provider,
                  description: m.description ?? '',
                })),
              },
            ]
          : [],
      })
      return true
    }

    if (sub === 'model' && method === 'POST') {
      const body = await readJson(req)
      const model = typeof body.model === 'string' ? body.model.trim() : ''
      if (!driver.setModel || !model) {
        send(res, 400, { error: `${driver.label} 暂不支持运行时切换模型` })
        return true
      }
      const switched = await driver.setModel(rawId, model)
      if (!switched) {
        send(res, 400, { error: `${driver.label} 暂不支持运行时切换模型` })
        return true
      }
      send(res, 200, { ok: true, model: { provider: resolved.backend, model } })
      return true
    }

    if (sub === 'commands' && method === 'GET') {
      send(res, 200, { ok: true, commands: [] })
      return true
    }

    if (sub === 'stats' && method === 'GET') {
      const data = await driver.getMessages(rawId, { limit: 200 }).catch(() => null)
      const msgs = data?.messages ?? []
      let userMsgs = 0
      let assistantMsgs = 0
      let toolCalls = 0
      for (const m of msgs) {
        if (m.role === 'user') userMsgs++
        else {
          assistantMsgs++
          toolCalls += m.tools?.length ?? 0
        }
      }
      send(res, 200, {
        ok: true,
        stats: {
          turns: assistantMsgs,
          userMsgs,
          assistantMsgs,
          toolCalls,
          tokens: { uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 },
        },
      })
      return true
    }

    if (sub === 'team' && method === 'GET') {
      send(res, 200, { ok: true, enabled: false, sawMode: false, members: [], tasks: [] })
      return true
    }

    if (sub === 'goal' && method === 'GET') {
      send(res, 200, { ok: true, goal: null })
      return true
    }

    send(res, 400, { error: `${driver.label} 暂不支持该操作 (${sub || method})` })
    return true
  }

  return {
    tryHandle,
    disposeStreams: () => {
      for (const close of Array.from(activeStreamClosers)) close()
    },
  }
}
