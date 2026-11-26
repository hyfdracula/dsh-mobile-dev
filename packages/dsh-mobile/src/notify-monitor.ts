/**
 * 桌面端通知监控与 Push Kit 中继分发器：
 * - 统一监听 DSH 会话巡检与外部 Agent 后端事件，仅在真实回合结束（running -> false）或新增挂起提问时触发；
 * - 避免会话重命名、置顶、元数据同步等仅修改 `updatedAt` 的假阳性通知；
 * - 为 `/api/sessions` 补充 `lastTurnId` / `lastTurnStatus` / `lastDoneAt` 供客户端精准去重；
 * - 当手机端切后台或离线且已注册 Push Token 时，通过云端中继发送 Huawei Push Kit 后台系统通知。
 */
import type { AskBridge } from './ask-bridge.ts'
import type { BackendRegistry } from './backends/registry.ts'
import type { BackendNotifyEvent } from './backends/types.ts'
import { projectSessions, type SessionRow } from './projections.ts'
import { PRESENCE_TTL_MS, pushTargets, record, removePushTarget } from './state.ts'
import { findSessionFile, historyOf } from './transcript.ts'

export const DEFAULT_PUSH_RELAY = 'https://feedback.juo.de5.net'
const POLL_MS = 3500
const MAX_DEDUPE = 512
const MAX_TRACKED = 1024

export interface ObservableSessionRow {
  id: string
  title: string
  updatedAt: number
  running: boolean
  asking?: boolean
  backend?: string
  lastTurnId?: string
  lastTurnStatus?: string
  lastDoneAt?: number
}

interface TrackedSession {
  running: boolean
  asking: boolean
  updatedAt: number
  title: string
  lastTurnId: string
  lastTurnStatus: string
  lastDoneAt: number
}

export interface NotifyMonitorDeps {
  controller: () => any
  askBridge: AskBridge
  backendRegistry: BackendRegistry
  markArchived: (rows: SessionRow[]) => SessionRow[]
  markPinned: (rows: SessionRow[]) => SessionRow[]
  logFile: string
}

export interface PushRelayResult {
  ok: boolean
  code?: string
  hwCode?: string
  requestId?: string
  message: string
}

/** 计算与客户端 `Notifier.noteId` 一致的单会话稳定通知 ID。 */
export function notifyIdOf(sessionId: string): number {
  if (sessionId === '') return 1000
  let h = 0
  for (let i = 0; i < sessionId.length; i++) {
    h = (h * 31 + sessionId.charCodeAt(i)) % 100000
  }
  return 1000 + h
}

export function sanitizeRelayUrl(raw?: string): string {
  const s = (raw ?? '').trim()
  if (s === '') return DEFAULT_PUSH_RELAY
  try {
    const u = new URL(s)
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return DEFAULT_PUSH_RELAY
    return u.toString().replace(/\/+$/, '')
  } catch {
    return DEFAULT_PUSH_RELAY
  }
}

export class NotifyMonitor {
  private readonly deps: NotifyMonitorDeps
  private readonly tracked = new Map<string, TrackedSession>()
  private readonly dedupe = new Map<string, number>()
  private readonly gatewayStartedAt = Date.now()
  private baselined = false
  private polling = false
  private timer: ReturnType<typeof setInterval> | null = null
  private initTimer: ReturnType<typeof setTimeout> | null = null
  private presence = { online: false, activeSessionId: '', updatedAt: 0 }

  constructor(deps: NotifyMonitorDeps) {
    this.deps = deps
  }

  start(): void {
    this.deps.backendRegistry.setNotifyListener((ev) => this.onExternalEvent(ev))
    this.initTimer = setTimeout(() => {
      this.initTimer = null
      void this.pollOnce(true)
    }, 1500)
    this.timer = setInterval(() => {
      void this.pollOnce(false)
    }, POLL_MS)
  }

  dispose(): void {
    if (this.initTimer !== null) {
      clearTimeout(this.initTimer)
      this.initTimer = null
    }
    if (this.timer !== null) {
      clearInterval(this.timer)
      this.timer = null
    }
    this.deps.backendRegistry.setNotifyListener(null)
    this.tracked.clear()
    this.dedupe.clear()
  }

  updatePresence(online: boolean, activeSessionId: string): void {
    this.presence = {
      online,
      activeSessionId: online ? activeSessionId.trim() : '',
      updatedAt: online ? Date.now() : 0,
    }
  }

  private hasAnyRunning(): boolean {
    for (const s of this.tracked.values()) {
      if (s.running) return true
    }
    return false
  }

  private setTracked(id: string, entry: TrackedSession): void {
    this.tracked.delete(id)
    this.tracked.set(id, entry)
    while (this.tracked.size > MAX_TRACKED) {
      const oldest = this.tracked.keys().next().value
      if (oldest === undefined) break
      this.tracked.delete(oldest)
    }
  }

  private markDedupe(key: string): boolean {
    const now = Date.now()
    const prev = this.dedupe.get(key)
    if (prev !== undefined && now - prev < 60_000) {
      return false
    }
    this.dedupe.delete(key)
    this.dedupe.set(key, now)
    while (this.dedupe.size > MAX_DEDUPE) {
      const oldest = this.dedupe.keys().next().value
      if (oldest === undefined) break
      this.dedupe.delete(oldest)
    }
    return true
  }

  private inspectDshTurn(sessionId: string): { turnKey: string; status: string; finishedAt: number } | null {
    const file = findSessionFile(sessionId)
    if (file === null) return null
    try {
      const hist = historyOf(file)
      const tail = hist.messages.length > 0 ? hist.messages[hist.messages.length - 1] : undefined
      const status = hist.lastTurn || tail?.turn?.status || ''
      const finishedAt = tail?.turn?.finishedAt || tail?.time || 0
      const seq = tail?.seq ?? 0
      if (status === '' && seq === 0) return null
      const turnKey = `${status || 'done'}:${String(seq)}:${String(finishedAt)}`
      return { turnKey, status: status || 'completed', finishedAt }
    } catch {
      return null
    }
  }

  observeRows(rows: readonly ObservableSessionRow[], allowDispatch: boolean): void {
    if (!this.baselined) {
      this.baselined = true
      for (const row of rows) {
        this.setTracked(row.id, {
          running: row.running === true,
          asking: row.asking === true,
          updatedAt: row.updatedAt,
          title: row.title,
          lastTurnId: row.lastTurnId ?? '',
          lastTurnStatus: row.lastTurnStatus ?? '',
          lastDoneAt: row.lastDoneAt ?? 0,
        })
      }
      return
    }

    for (const row of rows) {
      const prev = this.tracked.get(row.id)
      const isExternal = row.backend !== undefined && row.backend !== '' && row.backend !== 'dsh'
      const nowRunning = row.running === true
      const nowAsking = row.asking === true
      let lastTurnId = prev?.lastTurnId ?? ''
      let lastTurnStatus = prev?.lastTurnStatus ?? ''
      let lastDoneAt = prev?.lastDoneAt ?? 0

      if (!isExternal) {
        const stoppedRunning = prev !== undefined && prev.running && !nowRunning
        const fastTurnUpdated = prev !== undefined && !prev.running && !nowRunning && row.updatedAt > prev.updatedAt
        if (stoppedRunning || fastTurnUpdated) {
          const info = this.inspectDshTurn(row.id)
          if (info !== null) {
            const genuinelyNew = stoppedRunning || (
              info.turnKey !== lastTurnId &&
              info.finishedAt >= this.gatewayStartedAt
            )
            if (genuinelyNew) {
              lastTurnId = info.turnKey
              lastTurnStatus = info.status
              lastDoneAt = Date.now()
              if (allowDispatch) {
                void this.dispatchPush('done', row.id, row.title, info.turnKey, info.status)
              }
            } else if (lastTurnId === '') {
              lastTurnId = info.turnKey
              lastTurnStatus = info.status
            }
          } else if (stoppedRunning) {
            const fallbackKey = `idle:${String(row.updatedAt || Date.now())}`
            lastTurnId = fallbackKey
            lastTurnStatus = 'completed'
            lastDoneAt = Date.now()
            if (allowDispatch) {
              void this.dispatchPush('done', row.id, row.title, fallbackKey, 'completed')
            }
          }
        }
      }

      if (nowAsking && !(prev?.asking)) {
        if (allowDispatch) {
          void this.dispatchPush('asking', row.id, row.title, `ask:${String(Math.floor(Date.now() / 15000))}`)
        }
      }

      this.setTracked(row.id, {
        running: nowRunning,
        asking: nowAsking,
        updatedAt: row.updatedAt,
        title: row.title,
        lastTurnId,
        lastTurnStatus,
        lastDoneAt,
      })
    }
  }

  onExternalEvent(ev: BackendNotifyEvent): void {
    const prev = this.tracked.get(ev.sessionId)
    const title = ev.title || prev?.title || '会话'
    if (ev.kind === 'done') {
      const status = ev.status || 'completed'
      const turnKey = `ext:${status}:${String(Date.now())}`
      this.setTracked(ev.sessionId, {
        running: false,
        asking: prev?.asking ?? false,
        updatedAt: Date.now(),
        title,
        lastTurnId: turnKey,
        lastTurnStatus: status,
        lastDoneAt: Date.now(),
      })
      void this.dispatchPush('done', ev.sessionId, title, turnKey, status)
      return
    }
    this.setTracked(ev.sessionId, {
      running: prev?.running ?? true,
      asking: true,
      updatedAt: Date.now(),
      title,
      lastTurnId: prev?.lastTurnId ?? '',
      lastTurnStatus: prev?.lastTurnStatus ?? '',
      lastDoneAt: prev?.lastDoneAt ?? 0,
    })
    void this.dispatchPush('asking', ev.sessionId, title, `ask:${String(Math.floor(Date.now() / 15000))}`)
  }

  onDshAsk(sessionId: string, callId: string): void {
    const tracked = this.tracked.get(sessionId)
    const title = tracked?.title || '会话'
    if (tracked !== undefined) {
      tracked.asking = true
    }
    void this.dispatchPush('asking', sessionId, title, callId)
  }

  enrichRows<T extends ObservableSessionRow>(rows: T[]): T[] {
    return rows.map((row) => {
      const s = this.tracked.get(row.id)
      if (s === undefined || s.lastTurnId === '') return row
      return {
        ...row,
        lastTurnId: s.lastTurnId,
        lastTurnStatus: s.lastTurnStatus || undefined,
        lastDoneAt: s.lastDoneAt > 0 ? s.lastDoneAt : undefined,
      }
    })
  }

  private async pollOnce(initial: boolean): Promise<void> {
    if (this.polling) return
    const targets = pushTargets().filter((t) => t.enabled)
    if (!initial && targets.length === 0 && !this.hasAnyRunning()) {
      return
    }
    const ctl = this.deps.controller()
    if (!ctl || typeof ctl.list !== 'function') return
    this.polling = true
    try {
      const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
      const rows = this.deps
        .markPinned(this.deps.markArchived(projectSessions(listed, this.deps.askBridge.liveAsking())))
        .map((row) => ({ ...row, backend: 'dsh' }))
      this.observeRows(rows, !initial)
    } catch {
      // 忽略后台单次轮询失败，等待下次重试。
    } finally {
      this.polling = false
    }
  }

  private async dispatchPush(
    event: 'done' | 'asking',
    sessionId: string,
    title: string,
    dedupeKey: string,
    status?: string,
  ): Promise<void> {
    if (!this.markDedupe(`${event}:${sessionId}:${dedupeKey}`)) {
      return
    }
    const targets = pushTargets().filter((t) => t.enabled)
    if (targets.length === 0) return

    const phoneOnline = this.presence.online && (Date.now() - this.presence.updatedAt < PRESENCE_TTL_MS)
    if (phoneOnline && this.presence.activeSessionId === sessionId) {
      return
    }

    const safeTitle = (title.trim() || '会话').slice(0, 32)
    for (const target of targets) {
      if (phoneOnline && target.bgOnly) {
        continue
      }
      const isErr = status === 'error' || status === 'interrupted'
      const pushTitle = event === 'asking'
        ? '等你回答'
        : (isErr ? '回合已结束' : '任务完成')
      const pushBody = event === 'asking'
        ? (target.showTitle ? `「${safeTitle}」有一个问题需要你确认` : '智能体有一个问题需要你确认，点开查看')
        : (target.showTitle ? `「${safeTitle}」已经回复，点开看看` : '有一条智能体回复已完成，点开查看')

      await this.postToRelay(target.relayUrl, target.relaySecret, {
        pushToken: target.pushToken,
        event,
        sessionId,
        notifyId: notifyIdOf(sessionId),
        title: pushTitle,
        body: pushBody,
        foregroundShow: false,
        badgeAdd: 1,
      })
    }
  }

  private async postToRelay(
    relayUrl: string,
    relaySecret: string,
    payload: Record<string, unknown>,
  ): Promise<PushRelayResult> {
    const cleanSecret = relaySecret.trim()
    if (cleanSecret.length < 32) {
      return {
        ok: false,
        code: 'missing_relay_secret',
        message: '尚未同步推送凭据，请在手机「通知」页点击刷新状态',
      }
    }
    const base = sanitizeRelayUrl(relayUrl)
    try {
      const res = await fetch(`${base}/v1/push/send`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          authorization: `Bearer ${cleanSecret}`,
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(8000),
      })
      const data = (await res.json().catch(() => null)) as {
        ok?: unknown
        code?: unknown
        hwCode?: unknown
        requestId?: unknown
        message?: unknown
      } | null
      const code = String(data?.code ?? '')
      const hwCode = data?.hwCode !== undefined ? String(data.hwCode) : undefined
      const msg = String(data?.message ?? (res.ok ? 'ok' : `HTTP ${String(res.status)}`))
      if (res.ok && data?.ok === true) {
        void record(this.deps.logFile, `push sent event=${String(payload.event)} id=${String(payload.notifyId)}`)
        return { ok: true, code, hwCode, requestId: data.requestId ? String(data.requestId) : undefined, message: '已发送后台测试推送' }
      }
      if (code === 'invalid_token' && typeof payload.pushToken === 'string') {
        removePushTarget(payload.pushToken)
        void record(this.deps.logFile, 'push removed invalid_token')
      } else {
        void record(this.deps.logFile, `push relay failed code=${code} hw=${hwCode ?? '-'} msg=${msg}`)
      }
      return { ok: false, code, hwCode, message: msg }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      void record(this.deps.logFile, `push relay error: ${msg}`)
      return { ok: false, code: 'network_error', message: msg }
    }
  }

  async relayStatus(relayUrl?: string): Promise<{ ok: boolean; configured: boolean; category?: string; testMode?: boolean; error?: string }> {
    const base = sanitizeRelayUrl(relayUrl ?? pushTargets()[0]?.relayUrl)
    try {
      const res = await fetch(`${base}/v1/push/status`, {
        method: 'GET',
        signal: AbortSignal.timeout(5000),
      })
      const data = (await res.json().catch(() => null)) as {
        ok?: unknown
        configured?: unknown
        category?: unknown
        testMode?: unknown
      } | null
      if (!res.ok || data === null) {
        return { ok: false, configured: false, error: `HTTP ${String(res.status)}` }
      }
      return {
        ok: data.ok === true,
        configured: data.configured === true,
        category: typeof data.category === 'string' ? data.category : 'WORK',
        testMode: data.testMode === true,
      }
    } catch (err) {
      return { ok: false, configured: false, error: err instanceof Error ? err.message : String(err) }
    }
  }

  async sendTestPush(deviceIdOrToken?: string, relayUrl?: string): Promise<PushRelayResult> {
    const all = pushTargets()
    const key = (deviceIdOrToken ?? '').trim()
    const target = key !== ''
      ? (all.find((t) => t.deviceId === key || t.pushToken === key) ?? all[0])
      : all[0]
    if (target === undefined) {
      return { ok: false, code: 'no_push_token', message: '尚未收到手机上传的 Push Token' }
    }
    return await this.postToRelay(relayUrl || target.relayUrl, target.relaySecret, {
      pushToken: target.pushToken,
      event: 'test',
      notifyId: 990002,
      title: 'Agent Mobile 后台推送测试',
      body: target.showTitle ? '若能收到此通知，说明 Push Kit 与云端中继通道已打通' : '收到一条后台推送测试消息',
      foregroundShow: true,
      badgeAdd: 0,
    })
  }
}
