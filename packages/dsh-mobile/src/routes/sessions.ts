/**
 * 会话相关路由：列表、创建、重命名、消息历史（含精简模式）、SSE 实时流、
 * 模型与权限切换、分叉/归档/置顶、统一消息与附件投递、宿主排队管理、AgentTeams 与 Goal。
 */
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { AskBridge } from '../ask-bridge.ts'
import type { BackendRegistry } from '../backends/registry.ts'
import type { BackendId, BackendSessionRow } from '../backends/types.ts'
import { buildExportMetaJson, buildZipBuffer, renderSessionMarkdown } from '../export-zip.ts'
import { readJson, send } from '../http-util.ts'
import {
  buildEditedQueueContent,
  createIdempotencyStore,
  dispatchSessionMessage,
  hostEnqueue,
  hostMutate,
  hostQueued,
  hostQueueView,
  IMAGE_TYPES,
  MAX_UPLOAD_BYTES,
  parseImageParts,
  saveMobileFiles,
  withSessionLock,
} from '../outbox.ts'
import {
  normalizeAskAnswers,
  normalizeCatalog,
  planOf,
  presetCurrent,
  presetRows,
  projectSessions,
  rowsOf,
  type ContextUsage,
  type PlanState,
  type SessionRow,
} from '../projections.ts'
import { hashText, record } from '../state.ts'
import { taskStepsFingerprint, type TaskStep } from '../task-steps.ts'
import {
  applyCompactMode,
  findSessionFile,
  historyOf,
  previewOf,
  rawSessionJsonl,
  teamOf,
  zstdDecompressSync,
  type ChatMessage,
} from '../transcript.ts'

export interface SessionRouteDeps {
  controller: () => any
  service: (name: string) => any
  askBridge: AskBridge
  deepContext: (sessionId: string) => ContextUsage | null
  markArchived: (rows: SessionRow[]) => SessionRow[]
  markPinned: (rows: SessionRow[]) => SessionRow[]
  pinnedIds: () => string[] | null
  sigOf: (kind: string, value: string, exp: string) => string
  sigTtlSec: number
  logFile: string
  backendRegistry?: BackendRegistry
  onSessionsListed?: (rows: Array<(SessionRow & { backend?: string }) | BackendSessionRow>) => Array<(SessionRow & { backend?: string }) | BackendSessionRow>
}

export interface SessionRoutesBundle {
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
  disposeStreams: () => void
}

const ADD_SECTION_COMMANDS = new Set(['file', 'goal', 'plan', 'feedback'])

const FALLBACK_COMMANDS: ReadonlyArray<{
  name: string
  description: string
  hint?: string
  section: 'add' | 'commands'
}> = [
  { name: 'file', description: '添加文件到当前对话', section: 'add' },
  { name: 'goal', description: '设置或管理会话目标', hint: '<目标内容>', section: 'add' },
  { name: 'plan', description: '开启或关闭计划模式', section: 'add' },
  { name: 'feedback', description: '提交会话反馈', hint: '<反馈内容>', section: 'add' },
  { name: 'compact', description: '压缩当前对话上下文', section: 'commands' },
  { name: 'permission', description: '切换工具权限级别', section: 'commands' },
  { name: 'model', description: '切换当前会话模型', section: 'commands' },
  { name: 'export', description: '导出当前会话日志', section: 'commands' },
  { name: 'restart', description: '平滑重启电脑端服务', section: 'commands' },
  { name: 'restart-force', description: '强制重启电脑端服务', section: 'commands' },
  { name: 'web', description: '打开电脑端网页控制台', section: 'commands' },
]

function normalizePlanValue(raw: unknown): PlanState {
  if (typeof raw === 'boolean') {
    return { active: raw, pending: false }
  }
  if (raw !== null && typeof raw === 'object') {
    const o = raw as Record<string, unknown>
    return {
      active: o.active === true,
      pending: o.pending === true,
    }
  }
  return { active: false, pending: false }
}

export function createSessionRoutes(deps: SessionRouteDeps): SessionRoutesBundle {
  const idem = createIdempotencyStore()
  const activeStreamClosers = new Set<() => void>()

  /**
   * 优先读取内存中已存活的 agent；若是冷会话则自动调用 `sessionController.resolveAgent(sid)` 唤醒，
   * 彻底消除手机端操作冷会话时的 404/503 错误。
   */
  const resolveLiveAgent = async (sid: string): Promise<any> => {
    const agents = deps.service('agents')
    if (agents !== null && typeof agents.get === 'function') {
      try {
        const live = agents.get(sid)
        if (live !== null && live !== undefined) return live
      } catch {
        // fall through
      }
    }
    const ctl = deps.controller()
    if (ctl && typeof ctl.resolveAgent === 'function') {
      try {
        const resolved = await Promise.resolve(ctl.resolveAgent(sid))
        if (resolved !== null && resolved !== undefined) return resolved
      } catch {
        try {
          const resolved = await Promise.resolve(ctl.resolveAgent({ sessionId: sid }))
          if (resolved !== null && resolved !== undefined) return resolved
        } catch {
          // fall through
        }
      }
    }
    if (agents !== null && typeof agents.resolve === 'function') {
      try {
        const resolved = await Promise.resolve(agents.resolve(sid))
        if (resolved !== null && resolved !== undefined) return resolved
      } catch {
        // fall through
      }
    }
    if (agents !== null && typeof agents.get === 'function') {
      try {
        return agents.get(sid) ?? null
      } catch {
        return null
      }
    }
    return null
  }

  /** 读取会话计划模式状态（优先结合投影与 `planMode.get(agent)`）。 */
  const readPlanState = async (
    sid: string,
    projectedPlan?: PlanState,
    wakeCold = false,
  ): Promise<PlanState> => {
    const planSvc = deps.service('planMode')
    if (planSvc !== null && typeof planSvc.get === 'function') {
      const agents = deps.service('agents')
      const live = wakeCold
        ? await resolveLiveAgent(sid)
        : (agents !== null && typeof agents.get === 'function' ? agents.get(sid) : null)
      if (live !== null && live !== undefined) {
        try {
          const val = await Promise.resolve(planSvc.get(live))
          if (val !== null && val !== undefined) {
            return normalizePlanValue(val)
          }
        } catch {
          // fall through to projection
        }
      }
    }
    if (projectedPlan !== undefined) return projectedPlan
    try {
      const registry = deps.service('sessionProjections')
      const sessions = deps.service('sessions')
      const liveSession = sessions !== null && typeof sessions.get === 'function' ? sessions.get(sid) : undefined
      if (registry !== null && liveSession !== undefined && typeof registry.snapshot === 'function') {
        const snap = registry.snapshot(liveSession) as { values?: Record<string, unknown> } | undefined
        return planOf(snap?.values)
      }
    } catch {
      // ignore
    }
    return { active: false, pending: false }
  }

  const disposeStreams = (): void => {
    for (const close of [...activeStreamClosers]) {
      try {
        close()
      } catch {
        // ignore
      }
    }
    activeStreamClosers.clear()
  }

  const serializeTailMsg = (msg: ChatMessage | undefined): string => {
    if (msg === undefined) return ''
    return JSON.stringify({
      seq: msg.seq,
      textLen: msg.text.length,
      thinkingLen: msg.thinking?.length ?? 0,
      tools: msg.tools ?? null,
      turn: msg.turn ?? null,
    })
  }

  /** 启动指定会话的 SSE 实时流式推送（首帧立即推 `update`，450ms 检查增量，15s 心跳）。 */
  const serveSessionStream = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    sessionId: string,
  ): Promise<void> => {
    const sinceRaw = Number(url.searchParams.get('since') ?? '0')
    const initialSince = Number.isFinite(sinceRaw) ? Math.max(Math.trunc(sinceRaw), 0) : 0
    const compact = url.searchParams.get('compact') === '1' || url.searchParams.get('compact') === 'true'

    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-store, no-transform',
      'connection': 'keep-alive',
      'x-accel-buffering': 'no',
      'access-control-allow-origin': '*',
    })

    let closed = false
    let ticking = false
    let lastSentSeq = initialSince
    let lastTailSeq = 0
    let lastTailSnap = ''
    let lastFingerprint = ''

    const writeSse = (chunk: string): boolean => {
      if (closed || res.writableEnded || res.destroyed) return false
      try {
        res.write(chunk)
        return true
      } catch {
        cleanup()
        return false
      }
    }

    const pushIfChanged = async (forceFirst: boolean): Promise<void> => {
      if (closed || ticking) return
      ticking = true
      try {
        let all: ChatMessage[] = []
        let lastTurn = ''
        let lastErr = null
        let byteOffset = 0
        let total = 0
        let firstSeq = 0
        let tasks: TaskStep[] = []

        if (zstdDecompressSync !== undefined) {
          const file = findSessionFile(sessionId)
          if (file !== null) {
            try {
              const hist = historyOf(file)
              all = hist.messages
              lastTurn = hist.lastTurn
              lastErr = hist.lastErr
              byteOffset = hist.byteOffset
              tasks = hist.tasks
              total = all.length
              firstSeq = all.length > 0 ? (all[0]?.seq ?? 0) : 0
            } catch {
              // 会话文件正在创建或暂不可读。
            }
          }
        }

        let running = false
        let context: ContextUsage | null = null
        let projectedPlan: PlanState | undefined
        const ctl = deps.controller()
        let listed: unknown = []
        if (ctl && typeof ctl.list === 'function') {
          try {
            listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(5000)))
            const row = projectSessions(listed).find((r) => r.id === sessionId)
            if (row !== undefined) {
              running = row.running === true
              context = row.context ?? deps.deepContext(sessionId)
              projectedPlan = row.plan
            }
          } catch {
            // keep defaults
          }
        }

        const plan = await readPlanState(sessionId, projectedPlan, false)
        const queue = await hostQueueView(ctl, sessionId)
        const questions = deps.askBridge.pendingAsks(listed, sessionId)
        const tailMsg = all.length > 0 ? all[all.length - 1] : undefined
        const tailSnap = serializeTailMsg(tailMsg)
        const fp = JSON.stringify({
          byteOffset,
          total,
          tailSnap,
          running,
          lastTurn,
          lastErr,
          context,
          plan,
          queue,
          questions: questions.active,
          tasks: taskStepsFingerprint(tasks),
        })

        if (!forceFirst && fp === lastFingerprint) return
        lastFingerprint = fp

        let delta: ChatMessage[]
        if (forceFirst) {
          delta = lastSentSeq > 0
            ? all.filter((m) => m.seq > lastSentSeq).slice(-80)
            : all.slice(-30)
        } else {
          delta = all.filter((m) => m.seq > lastSentSeq)
          // 若末尾回复的 tools 状态或 turn 结算刚发生变更，补推末尾这一条以便前端原地刷新。
          if (
            tailMsg !== undefined
            && tailMsg.seq === lastTailSeq
            && tailSnap !== lastTailSnap
            && !delta.some((m) => m.seq === tailMsg.seq)
          ) {
            delta = [...delta, tailMsg]
          }
        }

        if (all.length > 0) {
          const newestSeq = all[all.length - 1]?.seq ?? lastSentSeq
          if (newestSeq > lastSentSeq) lastSentSeq = newestSeq
          lastTailSeq = tailMsg?.seq ?? 0
          lastTailSnap = tailSnap
        }

        const outMessages = compact ? applyCompactMode(all, delta) : delta
        const payload = {
          ok: true,
          sessionId,
          total,
          firstSeq,
          messages: outMessages,
          lastTurn,
          lastErr,
          running,
          context,
          plan,
          queue,
          questions,
          tasks,
        }
        writeSse(`event: update\ndata: ${JSON.stringify(payload)}\n\n`)
      } finally {
        ticking = false
      }
    }

    const pollTimer = setInterval(() => {
      void pushIfChanged(false)
    }, 450)

    const pingTimer = setInterval(() => {
      writeSse(': ping\n\n')
    }, 15_000)

    const cleanup = (): void => {
      if (closed) return
      closed = true
      clearInterval(pollTimer)
      clearInterval(pingTimer)
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

    await pushIfChanged(true)
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    if (path === '/api/debug/raw' && method === 'GET') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.list !== 'function') {
        send(res, 503, { error: 'sessionController unavailable' })
        return true
      }
      const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(15000)))
      const rows = rowsOf(listed)
      const first = rows[0]
      send(res, 200, {
        ok: true,
        container: Array.isArray(listed) ? 'array' : typeof listed,
        containerKeys:
          listed !== null && typeof listed === 'object' && !Array.isArray(listed) ? Object.keys(listed) : [],
        count: rows.length,
        firstRowKeys: first !== null && typeof first === 'object' ? Object.keys(first) : [],
        firstRow: first ?? null,
      })
      return true
    }

    if (path === '/api/sessions/previews' && method === 'GET') {
      const ids = (url.searchParams.get('ids') ?? '')
        .split(',')
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
        .slice(0, 60)
      const previews: { id: string; preview: string; count: number }[] = []
      for (const id of ids) {
        const file = findSessionFile(id)
        if (file === null) continue
        try {
          const one = previewOf(file)
          if (one.preview !== '') previews.push({ id, preview: one.preview, count: one.count })
        } catch {
          // 跳过不可读的会话日志。
        }
      }
      send(res, 200, { ok: true, previews })
      return true
    }

    if (path === '/api/sessions' && method === 'GET') {
      const wantBackendRaw = (url.searchParams.get('backend') ?? 'all').trim().toLowerCase()
      const wantBackend: BackendId | 'all' =
        wantBackendRaw === 'dsh' ||
        wantBackendRaw === 'codex' ||
        wantBackendRaw === 'claude' ||
        wantBackendRaw === 'opencode' ||
        wantBackendRaw === 'antigravity'
          ? wantBackendRaw
          : 'all'

      let dshSessions: Array<SessionRow & { backend?: string }> = []
      if (wantBackend === 'all' || wantBackend === 'dsh') {
        const ctl = deps.controller()
        if (!ctl || typeof ctl.list !== 'function') {
          if (wantBackend === 'dsh') {
            send(res, 503, { error: 'sessionController unavailable', hint: 'is the DSH host fully started?' })
            return true
          }
        } else {
          const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(15000)))
          dshSessions = deps
            .markPinned(deps.markArchived(projectSessions(listed, deps.askBridge.liveAsking())))
            .map((row) => ({ ...row, backend: 'dsh' }))
        }
      }

      const extSessions = deps.backendRegistry
        ? await deps.backendRegistry.listExternalSessions(wantBackend, 30)
        : []

      const rawSessions = [...dshSessions, ...extSessions].sort(
        (a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0),
      )
      const sessions = deps.onSessionsListed ? deps.onSessionsListed(rawSessions) : rawSessions
      send(res, 200, { ok: true, sessions })
      return true
    }

    if (path === '/api/sessions' && method === 'POST') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.create !== 'function') {
        send(res, 503, { error: 'sessionController.create unavailable' })
        return true
      }
      const preParsed = (req as unknown as { __parsedBody?: Record<string, unknown> }).__parsedBody
      const body = preParsed ?? (await readJson(req))
      const cwd = String(body.cwd ?? '').trim()
      const args: Record<string, unknown> = {}
      if (cwd !== '') args.cwd = cwd
      const created: unknown = await Promise.resolve(ctl.create(args))
      let raw: unknown = created
      if (typeof raw === 'string') {
        try {
          raw = JSON.parse(raw) as unknown
        } catch {
          raw = null
        }
      }
      let sessionId = ''
      if (raw !== null && typeof raw === 'object') {
        const row = raw as Record<string, unknown>
        sessionId = String(row.sessionId ?? row.id ?? '')
      }
      await record(deps.logFile, `200 POST create session=${sessionId}`)
      send(res, 200, { ok: true, sessionId, result: created ?? null })
      return true
    }

    const renameMatch = /^\/api\/sessions\/([^/]+)$/.exec(path)
    if (renameMatch !== null && method === 'PATCH') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.rename !== 'function') {
        send(res, 503, { error: 'sessionController.rename unavailable' })
        return true
      }
      const body = await readJson(req)
      const title = String(body.title ?? '').trim()
      if (title === '') {
        send(res, 400, { error: 'title is empty' })
        return true
      }
      const sessionId = decodeURIComponent(renameMatch[1] as string)
      await Promise.resolve(ctl.rename({ sessionId, title }))
      await record(deps.logFile, `200 PATCH rename session=${sessionId} title=${title}`)
      send(res, 200, { ok: true, sessionId, title })
      return true
    }

    const streamSignMatch = /^\/api\/sessions\/([^/]+)\/stream\/sign$/.exec(path)
    if (streamSignMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(streamSignMatch[1] as string)
      const exp = String(Math.floor(Date.now() / 1000) + deps.sigTtlSec)
      send(res, 200, { ok: true, sessionId: sid, e: exp, sig: deps.sigOf('stream', sid, exp) })
      return true
    }

    const streamMatch = /^\/api\/sessions\/([^/]+)\/stream$/.exec(path)
    if (streamMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(streamMatch[1] as string)
      await serveSessionStream(req, res, url, sid)
      return true
    }

    const questionsMatch = /^\/api\/sessions\/([^/]+)\/questions$/.exec(path)
    if (questionsMatch !== null && method === 'GET') {
      const sessionId = decodeURIComponent(questionsMatch[1] as string)
      const ctl = deps.controller()
      let listed: unknown = []
      if (ctl && typeof ctl.list === 'function') {
        try {
          listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
        } catch {
          // 即使列表暂不可用，仍可返回 liveAsks。
        }
      }
      send(res, 200, { ok: true, sessionId, ...deps.askBridge.pendingAsks(listed, sessionId) })
      return true
    }

    const answerMatch = /^\/api\/sessions\/([^/]+)\/questions\/answer$/.exec(path)
    if (answerMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(answerMatch[1] as string)
      const body = await readJson(req, 64 * 1024)
      const callId = String(body.callId ?? '')
      const answers = normalizeAskAnswers(body.answers)
      if (callId === '' || answers.length === 0) {
        send(res, 400, { error: 'callId and answers are required' })
        return true
      }
      const resolved = deps.askBridge.answer(sessionId, callId, { answers })
      if (!resolved.ok) {
        send(res, 409, { error: 'this question is no longer waiting', callId })
        return true
      }
      send(res, 200, { ok: true, callId, synthetic: resolved.synthetic, answered: answers.length })
      return true
    }

    const historyMatch = /^\/api\/sessions\/([^/]+)\/messages$/.exec(path)
    if (historyMatch !== null && method === 'GET') {
      const sessionId = decodeURIComponent(historyMatch[1] as string)
      if (zstdDecompressSync === undefined) {
        send(res, 501, { error: 'this Node build has no zstd support' })
        return true
      }
      const file = findSessionFile(sessionId)
      if (file === null) {
        send(res, 404, { error: 'session log not found', sessionId })
        return true
      }
      const raw = Number(url.searchParams.get('limit') ?? '30')
      const limit = Number.isFinite(raw) ? Math.min(Math.max(Math.trunc(raw), 1), 200) : 30
      const sinceRaw = Number(url.searchParams.get('since') ?? '0')
      const since = Number.isFinite(sinceRaw) ? Math.max(Math.trunc(sinceRaw), 0) : 0
      const beforeRaw = Number(url.searchParams.get('before') ?? '0')
      const before = Number.isFinite(beforeRaw) ? Math.max(Math.trunc(beforeRaw), 0) : 0
      const compact = url.searchParams.get('compact') === '1' || url.searchParams.get('compact') === 'true'

      const { messages: all, stats, lastTurn, lastErr, tasks } = historyOf(file)
      let tokens = stats.tokens
      let running = false
      let context: ContextUsage | null = null
      let projectedPlan: PlanState | undefined
      const ctl = deps.controller()
      let listed: unknown = []
      if (ctl && typeof ctl.list === 'function') {
        try {
          listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
          const row = projectSessions(listed).find((r) => r.id === sessionId)
          if (row !== undefined) {
            tokens = row.tokens
            running = row.running === true
            context = row.context
            projectedPlan = row.plan
            if (context === null) context = deps.deepContext(sessionId)
          }
        } catch {
          // keep event-derived fallback
        }
      }
      const plan = await readPlanState(sessionId, projectedPlan, false)
      const rawPage = since > 0
        ? all.filter((m) => m.seq > since).slice(0, 200)
        : before > 0
          ? all.filter((m) => m.seq < before).slice(-limit)
          : all.slice(-limit)
      const page = compact ? applyCompactMode(all, rawPage) : rawPage

      send(res, 200, {
        ok: true,
        sessionId,
        total: all.length,
        firstSeq: all.length > 0 ? (all[0]?.seq ?? 0) : 0,
        messages: page,
        stats: { ...stats, tokens },
        lastTurn,
        lastErr,
        context,
        plan,
        running,
        queue: await hostQueueView(ctl, sessionId),
        questions: deps.askBridge.pendingAsks(listed, sessionId),
        tasks,
      })
      return true
    }

    if (path === '/api/models' && method === 'GET') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.modelCatalog !== 'function') {
        send(res, 503, { error: 'sessionController.modelCatalog unavailable' })
        return true
      }
      const sessionId = url.searchParams.get('sessionId') ?? ''
      if (sessionId === '') {
        send(res, 400, { error: 'sessionId is required' })
        return true
      }
      const catalog = await Promise.resolve(ctl.modelCatalog({ sessionId }, AbortSignal.timeout(15000)))
      send(res, 200, { ok: true, sessionId, catalog: normalizeCatalog(catalog) })
      return true
    }

    const modelMatch = /^\/api\/sessions\/([^/]+)\/model$/.exec(path)
    if (modelMatch !== null && method === 'POST') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.selectModel !== 'function') {
        send(res, 503, { error: 'sessionController.selectModel unavailable' })
        return true
      }
      const body = await readJson(req)
      const provider = String(body.provider ?? '').trim()
      const model = String(body.model ?? '').trim()
      if (provider === '' || model === '') {
        send(res, 400, { error: 'provider and model are required' })
        return true
      }
      const args: Record<string, unknown> = {
        sessionId: decodeURIComponent(modelMatch[1] as string),
        provider,
        model,
      }
      const effort = String(body.reasoningEffort ?? '').trim()
      if (effort !== '') args.reasoningEffort = effort
      const result = await Promise.resolve(ctl.selectModel(args, AbortSignal.timeout(20000)))
      await record(deps.logFile, `200 POST model provider=${provider} model=${model} effort=${effort}`)
      send(res, 200, { ok: true, result: result ?? null })
      return true
    }

    const stopMatch = /^\/api\/sessions\/([^/]+)\/stop$/.exec(path)
    if (stopMatch !== null && method === 'POST') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.cancel !== 'function') {
        send(res, 503, { error: 'sessionController.cancel unavailable' })
        return true
      }
      const sessionId = decodeURIComponent(stopMatch[1] as string)
      const result: unknown = await Promise.resolve(ctl.cancel({ sessionId }))
      let raw: unknown = result
      if (typeof raw === 'string') {
        try {
          raw = JSON.parse(raw) as unknown
        } catch {
          raw = null
        }
      }
      let accepted = false
      if (raw !== null && typeof raw === 'object') {
        accepted = (raw as Record<string, unknown>).accepted === true
      }
      await record(deps.logFile, `200 POST stop session=${sessionId} accepted=${String(accepted)}`)
      send(res, 200, { ok: true, accepted, result: result ?? null })
      return true
    }

    const archiveMatch = /^\/api\/sessions\/([^/]+)\/archive$/.exec(path)
    if (archiveMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(archiveMatch[1] as string)
      const ctl = deps.controller()
      const reg = deps.service('workspaceRegistry')
      if (!(ctl && typeof ctl.archive === 'function') && !(reg && typeof reg.archiveSession === 'function')) {
        send(res, 503, { error: 'archiving is unavailable on this host' })
        return true
      }
      const archiveCall = async (stopActivity: boolean): Promise<void> => {
        if (ctl && typeof ctl.archive === 'function') {
          await Promise.resolve(ctl.archive({ sessionId, stopActivity }))
          return
        }
        await Promise.resolve(reg.archiveSession(sessionId, { stopActivity }))
      }
      let cancelledFirst = false
      let stoppedFirst = false
      try {
        await archiveCall(false)
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        if (/session-active|active|running|busy/i.test(message)) {
          try {
            await archiveCall(true)
            stoppedFirst = true
          } catch (err2) {
            if (ctl && typeof ctl.cancel === 'function') {
              await Promise.resolve(ctl.cancel({ sessionId }))
              cancelledFirst = true
              await archiveCall(false)
            } else {
              throw err2
            }
          }
        } else {
          throw err
        }
      }
      await record(deps.logFile, `200 POST archive session=${sessionId} stoppedFirst=${String(stoppedFirst)} cancelledFirst=${String(cancelledFirst)}`)
      send(res, 200, { ok: true, sessionId, archived: true, stoppedFirst, cancelledFirst })
      return true
    }

    const forkMatch = /^\/api\/sessions\/([^/]+)\/fork$/.exec(path)
    if (forkMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(forkMatch[1] as string)
      const ctl = deps.controller()
      if (!(ctl && typeof ctl.fork === 'function')) {
        send(res, 503, { error: 'forking is unavailable on this host' })
        return true
      }
      const body = await readJson(req)
      const raw = body.atSeq
      const atSeq = typeof raw === 'number' && Number.isFinite(raw) && raw >= 0 ? raw : undefined
      try {
        const out = await Promise.resolve(ctl.fork(atSeq === undefined ? { sessionId } : { sessionId, atSeq }))
        const child = typeof out === 'string' ? out : String((out as Record<string, unknown> | null)?.sessionId ?? '')
        if (child === '') {
          send(res, 500, { error: 'host returned no session for the fork' })
          return true
        }
        await record(deps.logFile, `200 POST fork session=${sessionId} at=${String(atSeq ?? 'latest')} child=${child}`)
        send(res, 200, { ok: true, sessionId: child, atSeq: atSeq ?? null })
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err)
        await record(deps.logFile, `500 POST fork session=${sessionId} at=${String(atSeq ?? 'latest')} err=${message}`)
        send(res, 500, { error: message })
      }
      return true
    }

    const unarchiveMatch = /^\/api\/sessions\/([^/]+)\/unarchive$/.exec(path)
    if (unarchiveMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(unarchiveMatch[1] as string)
      const ctl = deps.controller()
      const reg = deps.service('workspaceRegistry')
      const wc = deps.service('workspaceController')
      const attempts: Array<{ who: string; run: () => Promise<unknown> }> = []
      if (ctl && typeof ctl.unarchive === 'function') {
        attempts.push({ who: 'sessionController.unarchive', run: () => Promise.resolve(ctl.unarchive({ sessionId })) })
      }
      if (reg && typeof reg.unarchiveSession === 'function') {
        attempts.push({ who: 'workspaceRegistry.unarchiveSession', run: () => Promise.resolve(reg.unarchiveSession(sessionId)) })
      }
      if (wc && typeof wc.unarchiveSession === 'function') {
        attempts.push({ who: 'workspaceController.unarchiveSession', run: () => Promise.resolve(wc.unarchiveSession(sessionId)) })
      }
      if (attempts.length === 0) {
        send(res, 503, { error: 'unarchiving is unavailable on this host' })
        return true
      }
      let lastError = ''
      for (const attempt of attempts) {
        try {
          await attempt.run()
          await record(deps.logFile, `200 POST unarchive session=${sessionId} via=${attempt.who}`)
          send(res, 200, { ok: true, sessionId, archived: false, via: attempt.who })
          return true
        } catch (err) {
          lastError = err instanceof Error ? err.message : String(err)
        }
      }
      send(res, 500, { error: `unarchive failed: ${lastError}` })
      return true
    }

    const pinMatch = /^\/api\/sessions\/([^/]+)\/pin$/.exec(path)
    if (pinMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(pinMatch[1] as string)
      const body = await readJson(req)
      const want = body.pinned === undefined ? true : body.pinned === true
      const ctl = deps.controller()
      const reg = deps.service('workspaceRegistry')
      const anyCtl = ctl as unknown as Record<string, ((arg: unknown) => unknown) | undefined> | null
      const anyReg = reg as unknown as Record<string, ((arg: unknown) => unknown) | undefined> | null
      const attempts: Array<{ who: string; run: () => Promise<unknown> }> = []
      const ctlFn = anyCtl === null ? undefined : anyCtl[want ? 'pin' : 'unpin']
      if (typeof ctlFn === 'function') {
        attempts.push({
          who: `sessionController.${want ? 'pin' : 'unpin'}`,
          run: () => Promise.resolve(ctlFn.call(ctl, { sessionId })),
        })
      }
      const regFn = anyReg === null ? undefined : anyReg[want ? 'pinSession' : 'unpinSession']
      if (typeof regFn === 'function') {
        attempts.push({
          who: `workspaceRegistry.${want ? 'pinSession' : 'unpinSession'}`,
          run: () => Promise.resolve(regFn.call(reg, sessionId)),
        })
      }
      if (attempts.length === 0) {
        send(res, 503, { error: 'pinning is unavailable on this host' })
        return true
      }
      let lastError = ''
      for (const attempt of attempts) {
        try {
          await attempt.run()
          await record(deps.logFile, `200 POST pin session=${sessionId} pinned=${String(want)} via=${attempt.who}`)
          send(res, 200, { ok: true, sessionId, pinned: want, via: attempt.who, ids: deps.pinnedIds() ?? [] })
          return true
        } catch (err) {
          lastError = err instanceof Error ? err.message : String(err)
        }
      }
      send(res, 500, { error: `pin failed: ${lastError}` })
      return true
    }

    const imagesMatch = /^\/api\/sessions\/([^/]+)\/images$/.exec(path)
    if (imagesMatch !== null && method === 'POST') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.prompt !== 'function') {
        send(res, 503, { error: 'sessionController.prompt unavailable' })
        return true
      }
      const body = await readJson(req, MAX_UPLOAD_BYTES)
      const raw = Array.isArray(body.images) ? body.images : []
      const { parts, bytes } = parseImageParts(raw, true)
      const sessionId = decodeURIComponent(imagesMatch[1] as string)
      const text = String(body.text ?? '').trim() || '（来自手机）'
      const requested = body.mode === 'steer' ? 'steer' : 'queue'
      const outcome = await dispatchSessionMessage(
        ctl,
        sessionId,
        [{ type: 'text', text }, ...parts],
        requested,
        60000,
        deps.logFile,
        'images',
      )
      if (outcome.queued) {
        send(res, 200, {
          ok: true,
          sessionId,
          mode: 'queue',
          queued: true,
          item: outcome.item,
          count: parts.length,
          queue: outcome.queue,
        })
      } else {
        send(res, 200, {
          ok: true,
          sessionId,
          count: parts.length,
          bytes,
          mode: outcome.mode,
          running: outcome.running,
          result: outcome.result,
        })
      }
      return true
    }

    const queueImgMatch = /^\/api\/sessions\/([^/]+)\/queue-image$/.exec(path)
    if (queueImgMatch !== null && method === 'GET') {
      const sessionId = decodeURIComponent(queueImgMatch[1] as string)
      const itemId = String(url.searchParams.get('item') ?? '')
      const index = Number.parseInt(String(url.searchParams.get('i') ?? '0'), 10)
      const ctl = deps.controller()
      const list = ctl === null ? [] : await hostQueued(ctl, sessionId)
      const item = list.find((x: any) => String(x.id) === itemId)
      const parts = item && Array.isArray(item.content) ? item.content : []
      const images = parts.filter((p: any) => p !== null && typeof p === 'object' && p.type === 'image')
      const pick = images[Number.isFinite(index) ? index : 0]
      if (pick === undefined) {
        send(res, 404, { error: 'queued image not found' })
        return true
      }
      const mediaType = String(pick.mediaType ?? 'image/png').toLowerCase()
      const buf = Buffer.from(String(pick.data ?? ''), 'base64')
      res.writeHead(200, {
        'Content-Type': IMAGE_TYPES.has(mediaType) ? mediaType : 'image/png',
        'Content-Length': String(buf.length),
        'Cache-Control': 'no-store',
      })
      res.end(buf)
      return true
    }

    const filesMatch = /^\/api\/sessions\/([^/]+)\/files$/.exec(path)
    if (filesMatch !== null && method === 'POST') {
      const ctl = deps.controller()
      if (!ctl || typeof ctl.prompt !== 'function') {
        send(res, 503, { error: 'sessionController.prompt unavailable' })
        return true
      }
      const body = await readJson(req, MAX_UPLOAD_BYTES)
      const raw = Array.isArray(body.files) ? body.files : []
      const { saved, bytes, text: savedNotice } = await saveMobileFiles(raw, true)
      const sessionId = decodeURIComponent(filesMatch[1] as string)
      const head = String(body.text ?? '').trim() || '（来自手机）'
      const text = `${head}\n\n${savedNotice}`
      const requested = body.mode === 'steer' ? 'steer' : 'queue'
      const outcome = await dispatchSessionMessage(
        ctl,
        sessionId,
        [{ type: 'text', text }],
        requested,
        60000,
        deps.logFile,
        'files',
      )
      if (outcome.queued) {
        send(res, 200, {
          ok: true,
          sessionId,
          mode: 'queue',
          queued: true,
          item: outcome.item,
          count: saved.length,
          files: saved,
          queue: outcome.queue,
        })
      } else {
        send(res, 200, {
          ok: true,
          sessionId,
          count: saved.length,
          bytes,
          files: saved,
          mode: outcome.mode,
          running: outcome.running,
          result: outcome.result,
        })
      }
      return true
    }

    const queueMatch = /^\/api\/sessions\/([^/]+)\/queue$/.exec(path)
    if (queueMatch !== null) {
      const sessionId = decodeURIComponent(queueMatch[1] as string)
      if (method === 'GET') {
        const ctl = deps.controller()
        send(res, 200, { ok: true, sessionId, queue: await hostQueueView(ctl, sessionId) })
        return true
      }
      if (method === 'POST') {
        const ctl = deps.controller()
        if (!ctl || typeof ctl.prompt !== 'function') {
          send(res, 503, { error: 'sessionController.prompt unavailable' })
          return true
        }
        const body = await readJson(req)
        const text = String(body.text ?? '').trim()
        if (text.length === 0) {
          send(res, 400, { error: 'text is empty' })
          return true
        }
        const resultPayload = await withSessionLock(sessionId, async () => {
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          const queue = await hostQueueView(ctl, sessionId)
          return { itemId, queue }
        })
        await record(deps.logFile, `200 QUEUE push session=${sessionId} host=${resultPayload.itemId}`)
        send(res, 200, {
          ok: true,
          sessionId,
          item: resultPayload.itemId,
          queue: resultPayload.queue,
        })
        return true
      }
    }

    const queueOrderMatch = /^\/api\/sessions\/([^/]+)\/queue\/reorder$/.exec(path)
    if (queueOrderMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(queueOrderMatch[1] as string)
      const ctl = deps.controller()
      if (!ctl || typeof ctl.prompt !== 'function' || typeof ctl.updateQueue !== 'function') {
        send(res, 503, { error: 'sessionController queue API unavailable' })
        return true
      }
      const body = await readJson(req)
      const wanted = Array.isArray(body.ids) ? body.ids.map((x: unknown) => String(x)) : []
      await withSessionLock(sessionId, async () => {
        const listed = await hostQueued(ctl, sessionId)
        const byId = new Map<string, any>()
        for (const it of listed) {
          byId.set(String((it as any).id), it)
        }
        const unique = new Set<string>(wanted)
        if (
          wanted.length !== listed.length
          || unique.size !== wanted.length
          || wanted.some((id: string) => !byId.has(id))
        ) {
          send(res, 400, {
            error: 'ids must cover every queued item exactly once',
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        for (const it of listed) {
          await hostMutate(ctl, sessionId, String((it as any).id), { kind: 'remove' })
        }
        let moved = 0
        for (const id of wanted) {
          const it = byId.get(id)
          const content = it && Array.isArray(it.content) ? it.content : []
          if (content.length === 0) continue
          await hostEnqueue(ctl, sessionId, content as Record<string, unknown>[])
          moved++
        }
        await record(deps.logFile, `200 QUEUE reorder session=${sessionId} n=${String(moved)}`)
        send(res, 200, { ok: true, sessionId, moved, queue: await hostQueueView(ctl, sessionId) })
      })
      return true
    }

    const queueItemMatch = /^\/api\/sessions\/([^/]+)\/queue\/([^/]+)\/(drop|fire|edit)$/.exec(path)
    if (queueItemMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(queueItemMatch[1] as string)
      const itemId = decodeURIComponent(queueItemMatch[2] as string)
      const action = queueItemMatch[3] as 'drop' | 'fire' | 'edit'
      const ctl = deps.controller()
      if (!ctl || typeof ctl.updateQueue !== 'function') {
        send(res, 503, {
          error: 'sessionController.updateQueue unavailable',
          hint: 'restart the DSH host so the queue API is loaded',
        })
        return true
      }
      let editText = ''
      if (action === 'edit') {
        const body = await readJson(req)
        editText = String(body.text ?? '').trim()
        if (editText.length === 0) {
          send(res, 400, { error: 'text is empty' })
          return true
        }
      }
      await withSessionLock(sessionId, async () => {
        let mutation: Record<string, unknown>
        if (action === 'edit') {
          const content = await buildEditedQueueContent(ctl, sessionId, itemId, editText)
          mutation = { kind: 'edit', content }
        } else if (action === 'drop') {
          mutation = { kind: 'remove' }
        } else {
          mutation = { kind: 'steer' }
        }
        const mutated = await hostMutate(ctl, sessionId, itemId, mutation)
        await record(deps.logFile, `QUEUE ${action} session=${sessionId} id=${itemId} ok=${String(mutated)}`)
        if (!mutated) {
          send(res, 409, {
            error: 'queue item is no longer pending',
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        send(res, 200, {
          ok: true,
          sessionId,
          item: itemId,
          dropped: action === 'drop',
          fired: action === 'fire',
          queue: await hostQueueView(ctl, sessionId),
        })
      })
      return true
    }

    const outboxMatch = /^\/api\/sessions\/([^/]+)\/outbox$/.exec(path)
    if (outboxMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(outboxMatch[1] as string)
      const body = await readJson(req, MAX_UPLOAD_BYTES)
      const route = `outbox:${sessionId}`
      const reqHash = hashText(JSON.stringify(body))
      if (idem.replayHit(req, res, route, reqHash)) return true
      const idemKey = String(req.headers['idempotency-key'] ?? '')
      if (idemKey !== '') {
        if (idem.inflightBusy(idemKey)) {
          send(res, 409, { error: 'the same idempotency key is in flight' })
          return true
        }
        idem.inflightHold(res, idemKey)
      }
      const reply = (status: number, payload: unknown): void => {
        idem.replayPut(idemKey, status, payload, route, reqHash)
        send(res, status, payload)
      }
      const ctl = deps.controller()
      if (!ctl || typeof ctl.prompt !== 'function') {
        reply(503, { error: 'sessionController.prompt unavailable' })
        return true
      }
      const rawImgs = Array.isArray(body.images) ? body.images : []
      const rawFiles = Array.isArray(body.files) ? body.files : []
      const { parts: imgParts } = parseImageParts(rawImgs, false)
      const savedFiles = await saveMobileFiles(rawFiles, false)
      const text = String(body.text ?? '').trim()
      const content: Record<string, unknown>[] = []
      if (text !== '') content.push({ type: 'text', text })
      content.push(...imgParts)
      if (savedFiles.text !== '') content.push({ type: 'text', text: savedFiles.text })
      if (content.length === 0) {
        reply(400, { error: 'nothing to send' })
        return true
      }
      const requested = body.mode === 'steer' ? 'steer' : 'queue'
      const outcome = await dispatchSessionMessage(
        ctl,
        sessionId,
        content,
        requested,
        120000,
        deps.logFile,
        'outbox',
      )
      if (outcome.queued) {
        reply(200, {
          ok: true,
          sessionId,
          mode: 'queue',
          queued: true,
          item: outcome.item,
          parts: content.length,
          queue: outcome.queue,
        })
      } else {
        reply(200, {
          ok: true,
          sessionId,
          mode: outcome.mode,
          running: outcome.running,
          parts: content.length,
          result: outcome.result,
        })
      }
      return true
    }

    const sendMatch = /^\/api\/sessions\/([^/]+)\/send$/.exec(path)
    if (sendMatch !== null && method === 'POST') {
      const sessionId = decodeURIComponent(sendMatch[1] as string)
      const body = await readJson(req)
      const route = `send:${sessionId}`
      const reqHash = hashText(JSON.stringify(body))
      if (idem.replayHit(req, res, route, reqHash)) return true
      const idemKey = String(req.headers['idempotency-key'] ?? '')
      if (idemKey !== '') {
        if (idem.inflightBusy(idemKey)) {
          send(res, 409, { error: 'the same idempotency key is in flight' })
          return true
        }
        idem.inflightHold(res, idemKey)
      }
      const reply = (status: number, payload: unknown): void => {
        idem.replayPut(idemKey, status, payload, route, reqHash)
        send(res, status, payload)
      }
      const ctl = deps.controller()
      if (!ctl || typeof ctl.prompt !== 'function') {
        reply(503, { error: 'sessionController.prompt unavailable', hint: 'is the DSH host fully started?' })
        return true
      }
      const text = String(body.text ?? '').trim()
      if (text.length === 0) {
        reply(400, { error: 'text is empty' })
        return true
      }
      const requested = body.mode === 'steer' ? 'steer' : 'queue'
      const outcome = await dispatchSessionMessage(
        ctl,
        sessionId,
        [{ type: 'text', text }],
        requested,
        20000,
        deps.logFile,
        'send',
      )
      if (outcome.queued) {
        reply(200, {
          ok: true,
          sessionId,
          mode: 'queue',
          queued: true,
          item: outcome.item,
          queue: outcome.queue,
        })
      } else {
        reply(200, {
          ok: true,
          sessionId,
          mode: outcome.mode,
          running: outcome.running,
          result: outcome.result,
        })
      }
      return true
    }

    if (path === '/api/presets' && method === 'GET') {
      const svc = deps.service('agentPresets') ?? deps.service('agent-preset-registry')
      if (svc === null) {
        send(res, 200, { ok: true, presets: [], current: '', unavailable: true })
        return true
      }
      const raw = typeof svc.remoteExportList === 'function'
        ? await Promise.resolve(svc.remoteExportList())
        : typeof svc.list === 'function'
          ? await Promise.resolve(svc.list())
          : null
      const current = presetCurrent(svc)
      send(res, 200, { ok: true, presets: presetRows(raw, current), current, unavailable: false })
      return true
    }

    const presetMatch = /^\/api\/sessions\/([^/]+)\/preset$/.exec(path)
    if (presetMatch !== null && method === 'POST') {
      const body = await readJson(req)
      const presetId = String(body.presetId ?? '').trim()
      if (presetId === '') {
        send(res, 400, { error: 'presetId is required' })
        return true
      }
      const svc = deps.service('agentPresets') ?? deps.service('agent-preset-registry')
      if (svc === null) {
        send(res, 503, { error: 'agentPresets service unavailable' })
        return true
      }
      const sessionId = decodeURIComponent(presetMatch[1] as string)
      const agent: unknown = await resolveLiveAgent(sessionId)
      if (agent !== null && agent !== undefined && typeof svc.select === 'function') {
        try {
          await Promise.resolve(svc.select(agent, presetId))
          await record(deps.logFile, `200 POST preset session=${sessionId} preset=${presetId} scope=session`)
          send(res, 200, { ok: true, selected: presetId, scope: 'session' })
          return true
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error)
          if (!/already started|locked/.test(message)) throw error
        }
      }
      const settings = deps.service('settings')
      if (settings !== null && typeof settings.update === 'function') {
        await Promise.resolve(settings.update('agent-preset-registry', { selectedDefault: presetId }, undefined))
        await record(deps.logFile, `200 POST preset session=${sessionId} preset=${presetId} scope=global`)
        send(res, 200, { ok: true, selected: presetId, scope: 'global' })
        return true
      }
      send(res, 409, { error: 'this session already started a turn and no global default is available' })
      return true
    }

    if (path === '/api/permissions' && method === 'GET') {
      const svc = deps.service('permissionPresets')
      if (svc === null || typeof svc.catalog !== 'function') {
        send(res, 200, { ok: true, presets: [], current: '', defaultPreset: '', unavailable: true })
        return true
      }
      const cat = svc.catalog() as Record<string, unknown> | null
      const opts = cat !== null && Array.isArray(cat.options) ? (cat.options as unknown[]) : []
      const presets: Record<string, unknown>[] = []
      for (const item of opts) {
        if (item === null || typeof item !== 'object') continue
        const o = item as Record<string, unknown>
        const value = String(o.value ?? '')
        if (value === '') continue
        presets.push({ value, name: String(o.name ?? value), description: String(o.description ?? '') })
      }
      let current = ''
      const sessionId = url.searchParams.get('sessionId') ?? ''
      if (sessionId !== '') {
        const agent: unknown = await resolveLiveAgent(sessionId)
        if (agent !== null && agent !== undefined) {
          const session = (agent as Record<string, unknown>).session
          if (session !== undefined && typeof svc.current === 'function') {
            try {
              current = String(svc.current(session) ?? '')
            } catch {
              current = ''
            }
          }
        }
      }
      send(res, 200, {
        ok: true,
        presets,
        current,
        defaultPreset: String(cat?.defaultPreset ?? ''),
        unavailable: false,
      })
      return true
    }

    const permMatch = /^\/api\/sessions\/([^/]+)\/permission$/.exec(path)
    if (permMatch !== null && method === 'POST') {
      const body = await readJson(req)
      const preset = String(body.permission ?? '').trim()
      if (preset === '') {
        send(res, 400, { error: 'permission is required' })
        return true
      }
      const svc = deps.service('permissionPresets')
      if (svc === null || typeof svc.set !== 'function') {
        send(res, 503, { error: 'permissionPresets service unavailable' })
        return true
      }
      const sessionId = decodeURIComponent(permMatch[1] as string)
      const agent: unknown = await resolveLiveAgent(sessionId)
      if (agent === null || agent === undefined) {
        send(res, 404, { error: `no agent for session ${sessionId}` })
        return true
      }
      const session = (agent as Record<string, unknown>).session
      if (session === undefined) {
        send(res, 404, { error: `session ${sessionId} has no session object` })
        return true
      }
      svc.set(session, preset)
      let current = preset
      if (typeof svc.current === 'function') {
        try {
          current = String(svc.current(session) ?? preset)
        } catch {
          current = preset
        }
      }
      await record(deps.logFile, `200 POST permission session=${sessionId} preset=${preset} current=${current}`)
      send(res, 200, { ok: true, preset, current })
      return true
    }

    const teamMatch = /^\/api\/sessions\/([^/]+)\/team$/.exec(path)
    if (teamMatch !== null && method === 'GET') {
      const sessionId = decodeURIComponent(teamMatch[1] as string)
      const file = findSessionFile(sessionId)
      if (file === null) {
        send(res, 404, { error: 'session log not found' })
        return true
      }
      try {
        const snap = teamOf(file)
        send(res, 200, { ok: true, sessionId, ...snap })
      } catch (error) {
        send(res, 500, { error: `cannot read session log: ${String(error)}` })
      }
      return true
    }

    const teamModeMatch = /^\/api\/sessions\/([^/]+)\/team\/mode$/.exec(path)
    if (teamModeMatch !== null && method === 'POST') {
      const body = await readJson(req)
      if (typeof body.enabled !== 'boolean') {
        send(res, 400, { error: 'enabled 必须是布尔值' })
        return true
      }
      const enabled = body.enabled
      const sessionId = decodeURIComponent(teamModeMatch[1] as string)
      const svc = deps.service('agentTeams')
      if (svc === null || typeof svc.setEnabled !== 'function') {
        send(res, 503, { error: '这台电脑没有挂载智能体团队（agentTeams 服务不可用）' })
        return true
      }
      const agent: unknown = await resolveLiveAgent(sessionId)
      if (agent === null || agent === undefined) {
        send(res, 404, { error: `找不到目标会话 ${sessionId}` })
        return true
      }
      try {
        const change = svc.setEnabled as (a: unknown, v: boolean) => unknown
        await Promise.resolve(change.call(svc, agent, enabled))
      } catch (error) {
        const code = typeof (error as { code?: unknown }).code === 'string' ? String((error as { code: string }).code) : ''
        const message = error instanceof Error ? error.message : String(error)
        const status = code === 'TEAM_LEAD_REQUIRED' ? 409 : 500
        const readable = code === 'TEAM_LEAD_REQUIRED'
          ? '这个会话是子智能体，请到它的根会话里切换智能体协作'
          : `电脑端拒绝了这个切换：${message}`
        await record(deps.logFile, `${String(status)} POST team-mode session=${sessionId} enabled=${String(enabled)} code=${code} err=${message}`)
        send(res, status, { error: readable })
        return true
      }
      await record(deps.logFile, `200 POST team-mode session=${sessionId} enabled=${String(enabled)}`)
      send(res, 200, { ok: true, enabled })
      return true
    }

    const goalMatch = /^\/api\/sessions\/([^/]+)\/goal(?:\/(action))?$/.exec(path)
    if (goalMatch !== null) {
      const isAction = goalMatch[2] === 'action'
      if (isAction && method !== 'POST') {
        send(res, 405, { error: 'method must be POST' })
        return true
      }
      if (!isAction && method !== 'GET') {
        send(res, 405, { error: 'method must be GET' })
        return true
      }
      const sid = decodeURIComponent(goalMatch[1] as string)
      const goalSvc = deps.service('goals') as unknown as {
        get(agent: unknown): unknown
        create?(agent: unknown, input: { objective: string; maxGoalRounds?: number }): unknown
        pause(agent: unknown, ref: unknown): unknown
        resume(agent: unknown, ref: unknown): unknown
        complete(agent: unknown, ref: unknown): unknown
        clear(agent: unknown, ref: unknown): unknown
        edit(agent: unknown, ref: unknown, patch: unknown): unknown
      } | null
      if (goalSvc === null) {
        send(res, 503, { error: 'goals are unavailable on this host' })
        return true
      }
      const agent = await resolveLiveAgent(sid)
      if (agent === undefined || agent === null) {
        send(res, 404, { error: `找不到目标会话 ${sid}` })
        return true
      }
      const viewOf = (v: unknown): Record<string, unknown> | null => {
        if (v === undefined || v === null || typeof v !== 'object') return null
        const o = v as Record<string, unknown>
        return {
          id: o.id,
          objective: o.objective,
          phase: o.phase,
          revision: o.revision,
          roundsStarted: o.roundsStarted,
          maxGoalRounds: o.maxGoalRounds,
          activation: o.activation,
          updatedAt: o.updatedAt,
        }
      }
      if (!isAction) {
        try {
          send(res, 200, { ok: true, sessionId: sid, goal: viewOf(goalSvc.get(agent)) })
        } catch (ex) {
          send(res, 500, { error: String(ex) })
        }
        return true
      }
      const body = await readJson(req)
      const action = typeof body.action === 'string' ? body.action : ''
      if (action === 'create') {
        if (typeof goalSvc.create !== 'function') {
          send(res, 503, { error: 'goals.create is unavailable on this host' })
          return true
        }
        const objective = typeof body.objective === 'string' ? body.objective.trim() : ''
        if (objective === '') {
          send(res, 400, { error: 'objective 不能为空' })
          return true
        }
        const rawRounds = body.maxGoalRounds
        const maxGoalRounds = typeof rawRounds === 'number' && Number.isFinite(rawRounds) && rawRounds > 0
          ? Math.trunc(rawRounds)
          : undefined
        try {
          const created = await Promise.resolve(
            goalSvc.create(agent, { objective, ...(maxGoalRounds !== undefined ? { maxGoalRounds } : {}) }),
          )
          const goalView = viewOf(created) ?? viewOf(goalSvc.get(agent))
          await record(deps.logFile, `200 POST goal create session=${sid}`)
          send(res, 200, { ok: true, sessionId: sid, action: 'create', goal: goalView })
        } catch (ex) {
          const err = ex as { code?: string; message?: string }
          send(res, 409, { error: err.message ?? String(ex), code: err.code ?? '' })
        }
        return true
      }
      let current: Record<string, unknown> | null = null
      try {
        current = viewOf(goalSvc.get(agent))
      } catch (ex) {
        send(res, 500, { error: String(ex) })
        return true
      }
      if (current === null) {
        send(res, 404, { error: '这个会话现在没有目标' })
        return true
      }
      const ref = { id: current.id, revision: current.revision }
      try {
        if (action === 'pause') {
          await Promise.resolve(goalSvc.pause(agent, ref))
        } else if (action === 'resume') {
          await Promise.resolve(goalSvc.resume(agent, ref))
        } else if (action === 'complete') {
          await Promise.resolve(goalSvc.complete(agent, ref))
        } else if (action === 'clear') {
          await Promise.resolve(goalSvc.clear(agent, ref))
        } else if (action === 'edit') {
          const patch: Record<string, unknown> = {}
          if (typeof body.objective === 'string' && body.objective !== '') {
            patch.objective = body.objective
          }
          if (typeof body.maxGoalRounds === 'number' && body.maxGoalRounds > 0) {
            patch.maxGoalRounds = body.maxGoalRounds
          }
          await Promise.resolve(goalSvc.edit(agent, ref, patch))
        } else {
          send(res, 400, { error: 'action must be create, pause, resume, complete, clear or edit' })
          return true
        }
        const after = action === 'clear' ? null : viewOf(goalSvc.get(agent))
        send(res, 200, { ok: true, sessionId: sid, action, goal: after })
      } catch (ex) {
        const err = ex as { code?: string; message?: string }
        send(res, 409, { error: err.message ?? String(ex), code: err.code ?? '' })
      }
      return true
    }

    // --- F09: 计划模式 -------------------------------------------------------
    const planMatch = /^\/api\/sessions\/([^/]+)\/plan$/.exec(path)
    if (planMatch !== null) {
      const sid = decodeURIComponent(planMatch[1] as string)
      if (method === 'GET') {
        let projectedPlan: PlanState | undefined
        const ctl = deps.controller()
        if (ctl && typeof ctl.list === 'function') {
          try {
            const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(5000)))
            const row = projectSessions(listed).find((r) => r.id === sid)
            if (row?.plan !== undefined) projectedPlan = row.plan
          } catch {
            // fallback to planMode service
          }
        }
        const plan = await readPlanState(sid, projectedPlan, true)
        send(res, 200, { ok: true, active: plan.active, pending: plan.pending })
        return true
      }
      if (method === 'POST') {
        const body = await readJson(req)
        if (typeof body.active !== 'boolean') {
          send(res, 400, { error: 'active 必须是布尔值' })
          return true
        }
        const planSvc = deps.service('planMode')
        if (planSvc === null || typeof planSvc.set !== 'function') {
          send(res, 503, { error: 'planMode 服务不可用' })
          return true
        }
        const agent = await resolveLiveAgent(sid)
        if (agent === null || agent === undefined) {
          send(res, 404, { error: `找不到目标会话 ${sid}` })
          return true
        }
        const rawRes: unknown = await Promise.resolve(planSvc.set(agent, body.active))
        let state: PlanState = { active: body.active, pending: false }
        if (typeof planSvc.get === 'function') {
          try {
            const got = await Promise.resolve(planSvc.get(agent))
            if (got !== null && got !== undefined) state = normalizePlanValue(got)
          } catch {
            // keep fallback
          }
        } else if (rawRes !== null && typeof rawRes === 'object') {
          state = normalizePlanValue(rawRes)
        }
        const status = typeof rawRes === 'string'
          ? rawRes
          : (rawRes !== null && typeof rawRes === 'object' && typeof (rawRes as Record<string, unknown>).status === 'string')
            ? String((rawRes as Record<string, unknown>).status)
            : (state.active ? 'active' : 'inactive')
        await record(deps.logFile, `200 POST plan session=${sid} active=${String(state.active)}`)
        send(res, 200, { ok: true, active: state.active, pending: state.pending, status })
        return true
      }
      send(res, 405, { error: 'method must be GET or POST' })
      return true
    }

    // --- F09: 通用斜杠指令列表与执行 ------------------------------------------
    const cmdsMatch = /^\/api\/sessions\/([^/]+)\/commands$/.exec(path)
    if (cmdsMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(cmdsMatch[1] as string)
      const commandsSvc = deps.service('commands')
      let commands: Array<{ name: string; description: string; hint?: string; section: 'add' | 'commands' }> = []
      if (commandsSvc !== null && typeof commandsSvc.list === 'function') {
        const agent = await resolveLiveAgent(sid)
        if (agent !== null && agent !== undefined) {
          try {
            const raw: unknown = await Promise.resolve(commandsSvc.list(agent))
            const list = Array.isArray(raw)
              ? raw
              : (raw !== null && typeof raw === 'object' && Array.isArray((raw as { commands?: unknown }).commands))
                ? ((raw as { commands: unknown[] }).commands)
                : (raw !== null && typeof raw === 'object' && Array.isArray((raw as { items?: unknown }).items))
                  ? ((raw as { items: unknown[] }).items)
                  : []
            for (const item of list) {
              if (item === null || typeof item !== 'object') continue
              const c = item as Record<string, unknown>
              const rawName = String(c.name ?? c.id ?? '').trim().replace(/^\/+/, '')
              if (rawName === '') continue
              const hintRaw = typeof c.hint === 'string'
                ? c.hint.trim()
                : typeof c.usage === 'string'
                  ? c.usage.trim()
                  : ''
              const section: 'add' | 'commands' = ADD_SECTION_COMMANDS.has(rawName.toLowerCase()) ? 'add' : 'commands'
              const entry: { name: string; description: string; hint?: string; section: 'add' | 'commands' } = {
                name: rawName,
                description: String(c.description ?? ''),
                section,
              }
              if (hintRaw !== '') entry.hint = hintRaw
              commands.push(entry)
            }
          } catch {
            commands = []
          }
        }
      }
      if (commands.length === 0) {
        commands = FALLBACK_COMMANDS.map((c) => ({ ...c }))
      }
      send(res, 200, { ok: true, commands })
      return true
    }

    const cmdExecMatch = /^\/api\/sessions\/([^/]+)\/commands\/execute$/.exec(path)
    if (cmdExecMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(cmdExecMatch[1] as string)
      const body = await readJson(req)
      const line = typeof body.line === 'string' ? body.line.trim() : ''
      if (!line.startsWith('/') || line.length < 2) {
        send(res, 400, { error: '指令 line 必须以 / 开头且不能为空' })
        return true
      }
      const spaceIdx = line.search(/\s/)
      const cmdName = (spaceIdx >= 0 ? line.slice(1, spaceIdx) : line.slice(1)).toLowerCase()
      const argText = spaceIdx >= 0 ? line.slice(spaceIdx + 1).trim() : ''
      const agent = await resolveLiveAgent(sid)
      if (agent === null || agent === undefined) {
        send(res, 404, { error: `找不到目标会话 ${sid}` })
        return true
      }

      const trySessionFeedbackFallback = async (): Promise<boolean> => {
        if (cmdName !== 'feedback' || argText === '') return false
        const fbSvc = deps.service('sessionFeedback')
        if (fbSvc === null) return false
        try {
          if (typeof fbSvc.submit === 'function') {
            await Promise.resolve(fbSvc.submit(agent, argText))
          } else if (typeof fbSvc.record === 'function') {
            await Promise.resolve(fbSvc.record(agent, argText))
          } else if (typeof fbSvc.create === 'function') {
            await Promise.resolve(fbSvc.create({ sessionId: sid, text: argText, agent }))
          } else if (typeof fbSvc.add === 'function') {
            await Promise.resolve(fbSvc.add(agent, argText))
          } else {
            return false
          }
          await record(deps.logFile, `200 POST commands/execute session=${sid} cmd=feedback via=sessionFeedback`)
          send(res, 200, { ok: true, commandId: 'feedback', kind: 'info', text: '已记录反馈' })
          return true
        } catch {
          return false
        }
      }

      const commandsSvc = deps.service('commands')
      if (commandsSvc === null || typeof commandsSvc.execute !== 'function') {
        if (await trySessionFeedbackFallback()) return true
        send(res, 503, { error: 'commands 服务不可用' })
        return true
      }

      try {
        const execRes = await Promise.resolve(
          commandsSvc.execute(agent, line, [], AbortSignal.timeout(120000)),
        ) as Record<string, unknown> | null | undefined
        const inner = (execRes?.result !== null && typeof execRes?.result === 'object'
          ? execRes.result
          : execRes ?? {}) as Record<string, unknown>
        const commandId = String(execRes?.commandId ?? execRes?.id ?? cmdName)
        const kind = String(inner.kind ?? 'info')
        const text = typeof inner.text === 'string'
          ? inner.text
          : typeof inner.message === 'string'
            ? inner.message
            : ''
        if (cmdName === 'feedback' && argText !== '' && kind === 'error') {
          if (await trySessionFeedbackFallback()) return true
        }
        await record(deps.logFile, `200 POST commands/execute session=${sid} cmd=${commandId} kind=${kind}`)
        send(res, 200, { ok: true, commandId, kind, text })
        return true
      } catch (ex) {
        if (await trySessionFeedbackFallback()) return true
        const message = ex instanceof Error ? ex.message : String(ex)
        await record(deps.logFile, `500 POST commands/execute session=${sid} cmd=${cmdName} err=${message}`)
        send(res, 500, { error: `指令执行失败：${message}` })
        return true
      }
    }

    // --- F09: 会话日志导出（Markdown / 标准 ZIP） ----------------------------
    const exportSignMatch = /^\/api\/sessions\/([^/]+)\/export\/sign$/.exec(path)
    if (exportSignMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(exportSignMatch[1] as string)
      const body = await readJson(req)
      const formatRaw = typeof body.format === 'string' ? body.format.trim().toLowerCase() : 'markdown'
      if (formatRaw !== 'markdown' && formatRaw !== 'zip') {
        send(res, 400, { error: 'format 只能是 markdown 或 zip' })
        return true
      }
      const exp = String(Math.floor(Date.now() / 1000) + deps.sigTtlSec)
      const sig = deps.sigOf('export', `${sid}|${formatRaw}`, exp)
      const safeId = sid.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 64) || 'session'
      const filename = `dsh-${safeId}.${formatRaw === 'zip' ? 'zip' : 'md'}`
      send(res, 200, { ok: true, e: exp, sig, filename })
      return true
    }

    const exportMatch = /^\/api\/sessions\/([^/]+)\/export$/.exec(path)
    if (exportMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(exportMatch[1] as string)
      const format = (url.searchParams.get('format') ?? 'markdown').trim().toLowerCase()
      if (format !== 'markdown' && format !== 'zip') {
        send(res, 400, { error: 'format 只能是 markdown 或 zip' })
        return true
      }

      const sessionsSvc = deps.service('sessions')
      const liveSession = sessionsSvc !== null && typeof sessionsSvc.get === 'function'
        ? sessionsSvc.get(sid)
        : undefined
      if (liveSession !== undefined && liveSession !== null && typeof sessionsSvc?.flush === 'function') {
        await Promise.resolve(sessionsSvc.flush(liveSession)).catch(() => undefined)
      }

      const file = findSessionFile(sid)
      if (file === null) {
        send(res, 404, { error: 'session log not found', sessionId: sid })
        return true
      }

      let title = sid
      let cwd = ''
      const ctl = deps.controller()
      if (ctl && typeof ctl.list === 'function') {
        try {
          const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(5000)))
          const row = projectSessions(listed).find((r) => r.id === sid)
          if (row !== undefined) {
            title = row.title
            cwd = row.cwd
          }
        } catch {
          // keep fallback title
        }
      }

      const exportedAt = new Date().toISOString()
      const hist = historyOf(file)

      // 优先尝试宿主可选导出包 `@deepseek-ai/dsh-session-log-export`，否则回退到内置渲染器。
      let markdown = ''
      try {
        const exportPkg = '@deepseek-ai/dsh-session-log-export'
        const mod: any = await import(/* @vite-ignore */ exportPkg)
        const fn = mod?.exportSessionMarkdown ?? mod?.renderMarkdown ?? mod?.default
        if (typeof fn === 'function') {
          const out: unknown = await Promise.resolve(fn({ sessionId: sid, file, session: liveSession }))
          if (typeof out === 'string' && out.trim().length > 0) {
            markdown = out
          }
        }
      } catch {
        // 可选包未安装时直接走内置 Markdown 渲染。
      }
      if (markdown === '') {
        markdown = renderSessionMarkdown({
          sessionId: sid,
          title,
          cwd,
          messages: hist.messages,
          stats: hist.stats,
          exportedAt,
        })
      }

      const safeId = sid.replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 64) || 'session'
      if (format === 'markdown') {
        const filename = `dsh-${safeId}.md`
        const bodyBuf = Buffer.from(markdown, 'utf8')
        res.writeHead(200, {
          'content-type': 'text/markdown; charset=utf-8',
          'content-length': String(bodyBuf.length),
          'content-disposition': `attachment; filename="${filename}"; filename*=UTF-8''${encodeURIComponent(filename)}`,
          'cache-control': 'no-store',
        })
        res.end(bodyBuf)
        return true
      }

      const jsonl = rawSessionJsonl(file)
      const metaJson = buildExportMetaJson({
        sessionId: sid,
        title,
        cwd,
        stats: hist.stats,
        messageCount: hist.messages.length,
        exportedAt,
      })
      const zipBuf = buildZipBuffer([
        { name: 'session.md', data: markdown },
        { name: 'session.jsonl', data: jsonl },
        { name: 'meta.json', data: metaJson },
      ])
      const filename = `dsh-${safeId}.zip`
      res.writeHead(200, {
        'content-type': 'application/zip',
        'content-length': String(zipBuf.length),
        'content-disposition': `attachment; filename="${filename}"; filename*=UTF-8''${encodeURIComponent(filename)}`,
        'cache-control': 'no-store',
      })
      res.end(zipBuf)
      return true
    }

    return false
  }

  return { tryHandle, disposeStreams }
}
