/**
 * 宿主 `user-questions/request` 拦截桥接：
 * 在 `phone` 模式下挂起提问交由手机作答；切回 `desktop` 或插件卸载时同步将所有挂起提问交还桌面。
 */
import {
  asksOf,
  normalizeQuestions,
  rowsOf,
  type AskQuestion,
  type AskState,
} from './projections.ts'
import { answerMode, record } from './state.ts'

export interface LiveAsk {
  sessionId: string
  callId: string
  questions: AskQuestion[]
  createdAt: number
  synthetic: boolean
  resolve: (answer: unknown) => void
  delegate: (reason?: string) => void
}

export interface LiveAskSummary {
  callId: string
  sessionId: string
  questionCount: number
  firstHeader: string
  firstPrompt: string
  createdAt: number
}

export interface AskBridge {
  liveAsks: ReadonlyMap<string, LiveAsk>
  liveAsking: () => Set<string>
  listLive: () => LiveAskSummary[]
  pendingAsks: (listed: unknown, sessionId: string) => AskState
  answer: (sessionId: string, callId: string, payload: unknown) => { ok: true; synthetic: boolean } | { ok: false }
  delegateOne: (callId: string, reason?: string) => boolean
  delegateAll: (reason?: string) => number
}

export function createAskBridge(
  ctx: any,
  logFile: string,
  onNewAsk?: (sessionId: string, callId: string) => void,
): AskBridge {
  const liveAsks = new Map<string, LiveAsk>()
  let syntheticSeq = 0

  try {
    ctx.on?.(
      'user-questions/request',
      (request: any, next: () => Promise<unknown>) => {
        const questions = normalizeQuestions(request?.questions)
        if (questions.length === 0) return next()
        if (answerMode() === 'desktop') {
          void record(logFile, 'ask desktop-only, delegate')
          return next()
        }
        const agent = request?.agent
        const sessionId = String(request?.sessionId ?? agent?.session?.id ?? '')
        const hostCallId = request?.wait?.callId === undefined ? '' : String(request.wait.callId)
        const synthetic = hostCallId === ''
        let callId = hostCallId
        if (synthetic) {
          syntheticSeq += 1
          const tag = sessionId.replace(/[^0-9A-Za-z]/g, '').slice(0, 8) || 'anon'
          callId = `q-${tag}-${Date.now().toString(36)}-${String(syntheticSeq)}`
        }
        if (!synthetic && request?.wait?.timed === true) {
          void record(logFile, `ask timed, delegate session=${sessionId} call=${callId}`)
          return next()
        }
        const askSessionId = sessionId === '' ? '*' : sessionId
        const signal: AbortSignal | undefined =
          request?.signal !== undefined && typeof request.signal.addEventListener === 'function'
            ? (request.signal as AbortSignal)
            : undefined
        void record(
          logFile,
          `ask pending session=${sessionId} call=${callId} synthetic=${String(synthetic)} q=${String(questions.length)}`,
        )
        return new Promise<unknown>((resolve, reject) => {
          let done = false
          const cleanup = (): void => {
            if (liveAsks.get(callId) === entry) liveAsks.delete(callId)
            if (signal !== undefined) signal.removeEventListener('abort', onAbort)
          }
          const handOver = (reason: string): void => {
            if (done) return
            done = true
            cleanup()
            void record(logFile, `${reason} session=${sessionId} call=${callId}`)
            void Promise.resolve()
              .then(() => next())
              .then(resolve, reject)
          }
          const onAbort = (): void => handOver('ask aborted')
          if (signal !== undefined) {
            if (signal.aborted) {
              void record(logFile, `ask already aborted session=${sessionId} call=${callId}`)
              void Promise.resolve()
                .then(() => next())
                .then(resolve, reject)
              return
            }
            signal.addEventListener('abort', onAbort, { once: true })
          }
          const entry: LiveAsk = {
            sessionId: askSessionId,
            callId,
            questions,
            createdAt: Date.now(),
            synthetic,
            resolve: (answer: unknown) => {
              if (done) return
              done = true
              cleanup()
              void record(logFile, `ask answered session=${sessionId} call=${callId}`)
              resolve(answer)
            },
            delegate: (reason = 'ask delegate') => handOver(reason),
          }
          liveAsks.set(callId, entry)
          if (onNewAsk !== undefined && askSessionId !== '*') {
            try {
              onNewAsk(askSessionId, callId)
            } catch {
              // ignore ask listener failure
            }
          }
        })
      },
      { prepend: true },
    )
    void record(logFile, 'ask hook registered (prepend)')
  } catch (error) {
    void record(logFile, `ask hook skipped: ${String(error)}`)
  }

  const liveAsking = (): Set<string> => {
    const out = new Set<string>()
    for (const ask of liveAsks.values()) {
      if (ask.sessionId !== '*') out.add(ask.sessionId)
    }
    return out
  }

  const listLive = (): LiveAskSummary[] => {
    const out: LiveAskSummary[] = []
    for (const ask of liveAsks.values()) {
      const first = ask.questions[0]
      out.push({
        callId: ask.callId,
        sessionId: ask.sessionId,
        questionCount: ask.questions.length,
        firstHeader: first?.header ?? '',
        firstPrompt: first?.prompt ?? '',
        createdAt: ask.createdAt,
      })
    }
    out.sort((a, b) => a.createdAt - b.createdAt)
    return out
  }

  const pendingAsks = (listed: unknown, sessionId: string): AskState => {
    const raw = rowsOf(listed).find((item) => {
      const r = item as Record<string, unknown>
      return String(r.sessionId ?? r.id ?? '') === sessionId
    }) as Record<string, unknown> | undefined
    const proj = raw?.projections as { values?: Record<string, unknown> } | undefined
    const fromProjection = asksOf(proj?.values as Record<string, unknown> | undefined)
    const seen = new Set(fromProjection.active.map((a) => a.callId))
    for (const ask of liveAsks.values()) {
      if (ask.sessionId !== sessionId && ask.sessionId !== '*') continue
      if (seen.has(ask.callId)) continue
      fromProjection.active.push({
        callId: ask.callId,
        questions: ask.questions,
        state: 'open',
        synthetic: ask.synthetic,
      })
    }
    return fromProjection
  }

  const answer = (
    sessionId: string,
    callId: string,
    payload: unknown,
  ): { ok: true; synthetic: boolean } | { ok: false } => {
    const live = liveAsks.get(callId)
    if (live === undefined || (live.sessionId !== sessionId && live.sessionId !== '*')) {
      return { ok: false }
    }
    const synthetic = live.synthetic
    live.resolve(payload)
    return { ok: true, synthetic }
  }

  const delegateOne = (callId: string, reason = 'desktop-takeover'): boolean => {
    const live = liveAsks.get(callId)
    if (live === undefined) return false
    live.delegate(reason)
    return true
  }

  const delegateAll = (reason = 'delegate-all'): number => {
    const items = [...liveAsks.values()]
    if (items.length > 0) {
      void record(logFile, `ask releasing ${String(items.length)} pending questions (${reason})`)
    }
    for (const item of items) {
      try {
        item.delegate(reason)
      } catch {
        // ignore individual delegate error
      }
    }
    return items.length
  }

  return { liveAsks, liveAsking, listLive, pendingAsks, answer, delegateOne, delegateAll }
}
