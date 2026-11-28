/**
 * Agent Mobile 桌面设置面板：
 * 简洁优雅的分层设计——首屏聚焦扫码连接，下方精炼呈现连接方式、已连接设备与使用偏好，
 * 本机地址、预览端口、安全指纹等技术细节统一收纳至可折叠「高级设置」。
 * @module agent-mobile-gateway/client/MobileSection
 */
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'

type AnswerMode = 'phone' | 'desktop'

interface PairedDevice {
  deviceId: string
  pubKey: string
  name: string
  createdAt: number
  lastSeenAt: number
  revoked?: boolean
}

interface PendingAskItem {
  callId: string
  sessionId: string
  questionCount: number
  firstHeader: string
  firstPrompt: string
  createdAt: number
}

interface PendingPairRequestItem {
  id: string
  verifyCode: string
  deviceName: string
  source: 'lan' | 'remote'
  createdAt: number
  expiresAt: number
}

interface PanelState {
  ok: boolean
  host: string
  hostId?: string
  e2ee?: boolean
  e2eePub?: string
  devices?: PairedDevice[]
  pendingAsks?: PendingAskItem[]
  pendingPairRequests?: PendingPairRequestItem[]
  remotePayload?: string
  version: string
  port: number
  code: string
  expiresAt: number
  allowLan: boolean
  allowRemote: boolean
  publicUrl: string
  answerMode: AnswerMode
  allowTerminal: boolean
  previewPorts: number[]
  lan: string[]
  alts?: string[]
  base: string
  payload: string
  phoneSeenAt: number
  phoneOnline: boolean
}

/** 适配深浅双色的宿主题变量，强调色对齐 #2F6BFF。 */
const C = {
  card: 'var(--dsw-alias-surface-card, var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.07)))',
  cardSoft: 'var(--dsw-alias-bg-layer-2, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.06)))',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,0.18))',
  divider: 'var(--dsw-alias-border-l1, rgba(127,127,127,0.12))',
  fg: 'var(--dsw-alias-label-primary, currentColor)',
  fgDim: 'var(--dsw-alias-label-secondary, rgba(127,127,127,0.84))',
  fgFaint: 'var(--dsw-alias-label-tertiary, rgba(127,127,127,0.64))',
  accent: 'var(--dsw-alias-state-business-primary, #2F6BFF)',
  accentSoft: 'rgba(47,107,255,0.12)',
  accentBorder: 'rgba(47,107,255,0.28)',
  onAccent: 'var(--dsw-alias-label-on-color, #FFFFFF)',
  ok: 'var(--dsw-alias-state-success-primary, #10A366)',
  okBg: 'rgba(16,163,102,0.12)',
  bad: 'var(--dsw-alias-state-error-primary, #DC3545)',
  badBg: 'rgba(220,53,69,0.10)',
  qrPlate: '#FFFFFF',
  mono: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
}

const ROUTE = '/api/dsh-mobile/panel'

async function extractHttpError(res: Response): Promise<Error> {
  const text = await res.text()
  if (text.length > 0) {
    try {
      const parsed: unknown = JSON.parse(text)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const msg = (parsed as Record<string, unknown>).error
        if (typeof msg === 'string' && msg.trim().length > 0) {
          return new Error(msg.trim())
        }
      }
    } catch {
      // 非 JSON 错误体直接截断展示
    }
    return new Error(text.slice(0, 200))
  }
  return new Error(`HTTP ${String(res.status)}`)
}

async function getJson(path: string): Promise<PanelState> {
  const res = await fetch(path, { credentials: 'same-origin', cache: 'no-store' })
  if (!res.ok) throw await extractHttpError(res)
  return (await res.json()) as PanelState
}

async function postJson(path: string, body: unknown): Promise<PanelState> {
  const res = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw await extractHttpError(res)
  return (await res.json()) as PanelState
}

function validatePublicUrlInput(raw: string): { ok: true; url: string } | { ok: false; error: string } {
  const trimmed = raw.trim()
  if (trimmed === '') return { ok: true, url: '' }
  if (/\s/.test(trimmed)) return { ok: false, error: '外网地址不能包含空格' }
  if (!/^https?:\/\//i.test(trimmed)) {
    return { ok: false, error: '外网地址需以 https:// 或 http:// 开头' }
  }
  try {
    const u = new URL(trimmed)
    if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !u.hostname) {
      return { ok: false, error: '外网地址格式不正确，请填写完整网址' }
    }
    const cleanPath = u.pathname === '/' ? '' : u.pathname.replace(/\/+$/, '')
    return { ok: true, url: `${u.origin}${cleanPath}` }
  } catch {
    return { ok: false, error: '外网地址格式不正确，请填写完整网址' }
  }
}

function parsePortsInput(raw: string): { ok: true; ports: number[] } | { ok: false; error: string } {
  const parts = raw.split(/[,，\s]+/).map((s) => s.trim()).filter((s) => s.length > 0)
  const seen = new Set<number>()
  const ports: number[] = []
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      return { ok: false, error: `端口号「${part}」不合法，请填写 1 到 65535 之间的数字` }
    }
    const n = Number.parseInt(part, 10)
    if (!Number.isInteger(n) || n < 1 || n > 65535) {
      return { ok: false, error: `端口号 ${String(n)} 超出范围（1-65535）` }
    }
    if (!seen.has(n)) {
      seen.add(n)
      ports.push(n)
    }
    if (ports.length > 64) {
      return { ok: false, error: '最多支持配置 64 个预览端口' }
    }
  }
  return { ok: true, ports }
}

function Card(props: { children: ReactNode; accent?: boolean; padding?: string }): ReactNode {
  return (
    <div style={{
      border: `1px solid ${props.accent ? C.accentBorder : C.border}`,
      background: C.card,
      borderRadius: 16,
      padding: props.padding ?? '16px 18px',
      minWidth: 0,
    }}
    >
      {props.children}
    </div>
  )
}

function Hairline(): ReactNode {
  return <div style={{ height: 1, background: C.divider, margin: '10px 0' }} />
}

function SectionTitle(props: { title: string; right?: ReactNode }): ReactNode {
  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: 10,
      marginBottom: 10,
      minWidth: 0,
    }}
    >
      <span style={{ fontSize: 13.5, fontWeight: 600, color: C.fg, letterSpacing: '0.01em' }}>
        {props.title}
      </span>
      {props.right}
    </div>
  )
}

function StatusBadge(props: { text: string; tone: 'ok' | 'idle' | 'bad' | 'accent' }): ReactNode {
  const color = props.tone === 'ok'
    ? C.ok
    : props.tone === 'bad'
      ? C.bad
      : props.tone === 'accent'
        ? C.accent
        : C.fgFaint
  const bg = props.tone === 'ok'
    ? C.okBg
    : props.tone === 'bad'
      ? C.badBg
      : props.tone === 'accent'
        ? C.accentSoft
        : 'rgba(127,127,127,0.12)'
  return (
    <span style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 6,
      fontSize: 12,
      fontWeight: 500,
      color,
      background: bg,
      borderRadius: 999,
      padding: '4px 10px',
      flexShrink: 0,
      whiteSpace: 'nowrap',
    }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 3, background: color, flexShrink: 0 }} />
      {props.text}
    </span>
  )
}

function QuietDot(props: { text: string; color: string }): ReactNode {
  return (
    <span style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 5,
      fontSize: 12,
      color: C.fgDim,
      whiteSpace: 'nowrap',
    }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 3, background: props.color, flexShrink: 0 }} />
      {props.text}
    </span>
  )
}

function Toggle(props: { on: boolean; onChange: (next: boolean) => void; disabled?: boolean }): ReactNode {
  const width = 40
  const height = 22
  const disabled = props.disabled === true
  return (
    <button
      type="button"
      role="switch"
      aria-checked={props.on}
      disabled={disabled}
      onClick={() => { if (!disabled) props.onChange(!props.on) }}
      style={{
        width,
        height,
        borderRadius: height / 2,
        border: 'none',
        padding: 0,
        fontFamily: 'inherit',
        cursor: disabled ? 'default' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        background: props.on ? C.accent : 'rgba(127,127,127,0.32)',
        position: 'relative',
        transition: 'background .18s ease',
        flexShrink: 0,
      }}
    >
      <span style={{
        position: 'absolute',
        top: 2.5,
        left: props.on ? width - height + 2.5 : 2.5,
        width: height - 5,
        height: height - 5,
        borderRadius: '50%',
        background: C.onAccent,
        boxShadow: '0 1px 2px rgba(0,0,0,0.22)',
        transition: 'left .18s cubic-bezier(.34,1.4,.64,1)',
      }}
      />
    </button>
  )
}

function Btn(props: { text: string; onClick: () => void; primary?: boolean; ghost?: boolean; disabled?: boolean }): ReactNode {
  const primary = props.primary === true
  const ghost = props.ghost === true
  const disabled = props.disabled === true
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={props.onClick}
      style={{
        border: primary ? 'none' : ghost ? 'none' : `1px solid ${C.border}`,
        background: primary ? C.accent : ghost ? 'transparent' : C.cardSoft,
        color: primary ? C.onAccent : ghost ? C.fgDim : C.fg,
        borderRadius: 10,
        padding: ghost ? '6px 10px' : '7px 14px',
        fontSize: 12.5,
        fontWeight: primary ? 500 : 400,
        fontFamily: 'inherit',
        lineHeight: 1.4,
        cursor: disabled ? 'default' : 'pointer',
        opacity: disabled ? 0.5 : 1,
        flexShrink: 0,
        whiteSpace: 'nowrap',
      }}
    >
      {props.text}
    </button>
  )
}

function SettingRow(props: { title: string; desc?: string; right: ReactNode }): ReactNode {
  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: 14,
      padding: '2px 0',
      minWidth: 0,
    }}
    >
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 13.5, fontWeight: 500, color: C.fg }}>{props.title}</div>
        {props.desc
          ? (
            <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, lineHeight: 1.45 }}>
              {props.desc}
            </div>
          )
          : null}
      </div>
      {props.right}
    </div>
  )
}

function InfoItem(props: { label: string; value: string }): ReactNode {
  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      gap: 12,
      padding: '5px 0',
      fontSize: 12,
      minWidth: 0,
    }}
    >
      <span style={{ color: C.fgFaint, flexShrink: 0 }}>{props.label}</span>
      <span style={{
        color: C.fgDim,
        fontFamily: C.mono,
        overflowWrap: 'anywhere',
        textAlign: 'right',
      }}
      >
        {props.value}
      </span>
    </div>
  )
}

function countdown(secondsLeft: number): string {
  const safe = Math.max(0, secondsLeft)
  const mm = Math.floor(safe / 60)
  const ss = safe % 60
  return `${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
}

function formatFriendlySeen(ts: number, now: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return '刚刚'
  const diffSec = Math.max(0, Math.floor((now - ts) / 1000))
  if (diffSec < 60) return '刚刚'
  if (diffSec < 3600) return `${String(Math.floor(diffSec / 60))} 分钟前`
  const d = new Date(ts)
  const cur = new Date(now)
  const pad = (n: number): string => String(n).padStart(2, '0')
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  if (d.getFullYear() === cur.getFullYear() && d.getMonth() === cur.getMonth() && d.getDate() === cur.getDate()) {
    return `今天 ${hm}`
  }
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hm}`
}

/** 局域网地址排序：IPv4 优先展示，IPv6 放后。 */
function sortLanAddresses(list: readonly string[]): string[] {
  const ipv4: string[] = []
  const ipv6: string[] = []
  for (const addr of list) {
    if (addr.includes('[')) ipv6.push(addr)
    else ipv4.push(addr)
  }
  return [...ipv4, ...ipv6]
}

export function MobileSection(): ReactNode {
  const [state, setState] = useState<PanelState | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState('')
  const [draftUrl, setDraftUrl] = useState('')
  const [urlDirty, setUrlDirty] = useState(false)
  const urlDirtyRef = useRef(false)
  const [draftPorts, setDraftPorts] = useState('')
  const [portsDirty, setPortsDirty] = useState(false)
  const portsDirtyRef = useRef(false)
  const [qrFailed, setQrFailed] = useState(false)
  const [copied, setCopied] = useState('')
  const [now, setNow] = useState(Date.now())
  const [showAdvanced, setShowAdvanced] = useState(false)
  const refreshedExpiredCodeRef = useRef('')
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const syncDraftsFromState = useCallback((next: PanelState): void => {
    if (!urlDirtyRef.current) {
      setDraftUrl(next.publicUrl ?? '')
    }
    if (!portsDirtyRef.current) {
      const list = Array.isArray(next.previewPorts) ? next.previewPorts : []
      setDraftPorts(list.join(', '))
    }
  }, [])

  const load = useCallback(async (clearErr = false): Promise<void> => {
    try {
      const next = await getJson(`${ROUTE}/state`)
      setState(next)
      if (clearErr) setError('')
      syncDraftsFromState(next)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    }
  }, [syncDraftsFromState])

  useEffect(() => {
    void load(true)
    const poll = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      void load(false)
    }, 5000)
    const clock = setInterval(() => { setNow(Date.now()) }, 1000)
    return () => {
      clearInterval(poll)
      clearInterval(clock)
      if (copyTimerRef.current !== null) {
        clearTimeout(copyTimerRef.current)
        copyTimerRef.current = null
      }
    }
  }, [load])

  const patch = useCallback(async (key: string, body: unknown, onSuccess?: (next: PanelState) => void): Promise<void> => {
    setBusy(key)
    try {
      const next = await postJson(`${ROUTE}/config`, body)
      setState(next)
      setError('')
      onSuccess?.(next)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [])

  const savePublicUrl = useCallback(async (): Promise<void> => {
    const checked = validatePublicUrlInput(draftUrl)
    if (!checked.ok) {
      setError(checked.error)
      return
    }
    await patch('url', { publicUrl: checked.url }, (next) => {
      urlDirtyRef.current = false
      setUrlDirty(false)
      setDraftUrl(next.publicUrl ?? '')
    })
  }, [draftUrl, patch])

  const savePreviewPorts = useCallback(async (): Promise<void> => {
    const checked = parsePortsInput(draftPorts)
    if (!checked.ok) {
      setError(checked.error)
      return
    }
    await patch('ports', { previewPorts: checked.ports }, (next) => {
      portsDirtyRef.current = false
      setPortsDirty(false)
      const list = Array.isArray(next.previewPorts) ? next.previewPorts : []
      setDraftPorts(list.join(', '))
    })
  }, [draftPorts, patch])

  const rotate = useCallback(async (): Promise<void> => {
    setBusy('code')
    try {
      const next = await postJson(`${ROUTE}/newcode`, {})
      setState(next)
      setQrFailed(false)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [])

  const toggleDeviceRevoke = useCallback(async (deviceId: string, revoked: boolean): Promise<void> => {
    setBusy(`dev:${deviceId}`)
    try {
      const next = await postJson(`${ROUTE}/devices/revoke`, { deviceId, revoked })
      setState(next)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [])

  const takeoverOnDesktop = useCallback(async (): Promise<void> => {
    setBusy('takeover')
    try {
      const res = await fetch(`${ROUTE}/asks/takeover`, {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { 'content-type': 'application/json; charset=utf-8' },
        body: JSON.stringify({}),
      })
      if (!res.ok) throw await extractHttpError(res)
      const payload = (await res.json()) as { state?: PanelState }
      if (payload.state) setState(payload.state)
      else await load(false)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [load])

  const decidePairRequest = useCallback(async (id: string, approve: boolean): Promise<void> => {
    setBusy(`pair:${id}`)
    try {
      const res = await fetch(`${ROUTE}/pair-requests/decide`, {
        method: 'POST',
        credentials: 'same-origin',
        cache: 'no-store',
        headers: { 'content-type': 'application/json; charset=utf-8' },
        body: JSON.stringify({ id, approve }),
      })
      if (!res.ok) throw await extractHttpError(res)
      const payload = (await res.json()) as { state?: PanelState }
      if (payload.state) setState(payload.state)
      else await load(false)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [load])

  const copy = useCallback(async (text: string, label: string): Promise<void> => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(label)
      if (copyTimerRef.current !== null) clearTimeout(copyTimerRef.current)
      copyTimerRef.current = setTimeout(() => { setCopied('') }, 1800)
    } catch {
      setCopied('')
    }
  }, [])

  const online = state?.phoneOnline === true
  const secondsLeft = state === null ? 0 : Math.floor((state.expiresAt - now) / 1000)
  const qrSrc = state === null || state.payload.length === 0
    ? ''
    : `${ROUTE}/qr.svg?payload=${encodeURIComponent(state.payload)}`

  useEffect(() => {
    setQrFailed(false)
  }, [qrSrc])

  useEffect(() => {
    if (state === null) return
    if (secondsLeft <= 0 && refreshedExpiredCodeRef.current !== state.code) {
      refreshedExpiredCodeRef.current = state.code
      void load(false)
    }
  }, [state, secondsLeft, load])

  const currentAnswerMode: AnswerMode = state?.answerMode === 'desktop' ? 'desktop' : 'phone'
  const connectToken = (state?.remotePayload && state.remotePayload.length > 0)
    ? state.remotePayload
    : (state?.payload ?? '')
  const hasLanReady = state !== null && state.allowLan && state.lan.length > 0
  const hasWanReady = state !== null && state.allowRemote && state.publicUrl.trim().length > 0
  const devices = Array.isArray(state?.devices) ? state.devices : []
  const activeDeviceCount = devices.filter((d) => d.revoked !== true).length
  const sortedLan = state !== null && Array.isArray(state.lan) ? sortLanAddresses(state.lan) : []

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, minWidth: 0 }}>
      {/* 待处理提醒区：仅在有待确认事项时展示 */}
      {Array.isArray(state?.pendingPairRequests) && state.pendingPairRequests.length > 0
        ? (
          <Card accent>
            <SectionTitle title={`有 ${String(state.pendingPairRequests.length)} 台新手机请求连接`} />
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {state.pendingPairRequests.map((req) => (
                <div
                  key={req.id}
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    gap: 12,
                    flexWrap: 'wrap',
                    padding: '10px 12px',
                    borderRadius: 12,
                    background: C.cardSoft,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
                    <span style={{
                      fontFamily: C.mono,
                      fontSize: 18,
                      fontWeight: 700,
                      letterSpacing: 3,
                      color: C.accent,
                      background: C.accentSoft,
                      borderRadius: 10,
                      padding: '4px 10px',
                    }}
                    >
                      {req.verifyCode}
                    </span>
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontSize: 13, fontWeight: 600, color: C.fg, overflowWrap: 'anywhere' }}>
                        {req.deviceName}
                      </div>
                      <div style={{ fontSize: 11.5, color: C.fgFaint }}>
                        请核对手机上的 4 位数字 · 剩余 {countdown(Math.floor((req.expiresAt - now) / 1000))}
                      </div>
                    </div>
                  </div>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <Btn
                      text="拒绝"
                      disabled={busy === `pair:${req.id}`}
                      onClick={() => { void decidePairRequest(req.id, false) }}
                    />
                    <Btn
                      text={busy === `pair:${req.id}` ? '处理中...' : '批准连接'}
                      primary
                      disabled={busy === `pair:${req.id}`}
                      onClick={() => { void decidePairRequest(req.id, true) }}
                    />
                  </div>
                </div>
              ))}
            </div>
          </Card>
        )
        : null}

      {Array.isArray(state?.pendingAsks) && state.pendingAsks.length > 0
        ? (
          <Card accent>
            <SettingRow
              title={`有 ${String(state.pendingAsks.length)} 组提问正等待手机回答`}
              desc={state.pendingAsks[0]?.firstPrompt || state.pendingAsks[0]?.firstHeader || '可随时切回电脑直接作答'}
              right={(
                <Btn
                  text={busy === 'takeover' ? '切换中...' : '在电脑上回答'}
                  primary
                  disabled={busy === 'takeover'}
                  onClick={() => { void takeoverOnDesktop() }}
                />
              )}
            />
          </Card>
        )
        : null}

      {error.length > 0
        ? (
          <div
            role="alert"
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 10,
              border: `1px solid ${C.bad}`,
              background: C.badBg,
              color: C.bad,
              borderRadius: 12,
              padding: '9px 12px',
              fontSize: 12.5,
              lineHeight: 1.45,
              minWidth: 0,
              overflowWrap: 'anywhere',
            }}
          >
            <span style={{ minWidth: 0, overflowWrap: 'anywhere' }}>{error}</span>
            <button
              type="button"
              onClick={() => { setError('') }}
              style={{
                border: 'none',
                background: 'transparent',
                color: C.bad,
                fontSize: 15,
                fontFamily: 'inherit',
                padding: '0 4px',
                cursor: 'pointer',
                flexShrink: 0,
              }}
              aria-label="关闭提示"
            >
              ×
            </button>
          </div>
        )
        : null}

      {/* 首屏主角卡：品牌状态 + 扫码连手机，一卡搞定 */}
      <Card padding="18px 20px">
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 11, minWidth: 0 }}>
            <svg
              viewBox="0 0 64 64"
              width="34"
              height="34"
              fill="none"
              aria-hidden="true"
              style={{ flexShrink: 0, display: 'block', borderRadius: 9 }}
            >
              <defs>
                <radialGradient id="amGatewayIconBg" cx="50%" cy="28%" r="72%">
                  <stop offset="0%" stopColor="#2A2E39" />
                  <stop offset="55%" stopColor="#151821" />
                  <stop offset="100%" stopColor="#0B0C10" />
                </radialGradient>
              </defs>
              <rect
                x="1"
                y="1"
                width="62"
                height="62"
                rx="16"
                fill="url(#amGatewayIconBg)"
                stroke="#FFFFFF"
                strokeOpacity="0.16"
                strokeWidth="1.4"
              />
              <path d="M12.5 22.5 L20.5 30 L12.5 37.5" stroke="#FFFFFF" strokeWidth="5.2" strokeLinecap="round" strokeLinejoin="round" />
              <path d="M26 40 H38" stroke="#FFFFFF" strokeWidth="5.2" strokeLinecap="round" />
              <path d="M51.5 22.5 L43.5 30 L51.5 37.5" stroke="#FFFFFF" strokeWidth="5.2" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 600, color: C.fg, lineHeight: 1.25 }}>Agent Mobile</div>
              <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, overflowWrap: 'anywhere' }}>
                {state?.host ?? '本机电脑'}
              </div>
            </div>
          </div>
          <StatusBadge text={online ? '手机在线' : '等待连接'} tone={online ? 'ok' : 'idle'} />
        </div>

        <Hairline />

        <div style={{ display: 'flex', alignItems: 'center', gap: 22, flexWrap: 'wrap', paddingTop: 4, minWidth: 0 }}>
          {/* 左侧二维码 */}
          <div style={{
            width: 176,
            height: 176,
            borderRadius: 14,
            background: qrSrc.length > 0 && !qrFailed ? C.qrPlate : C.cardSoft,
            border: `1px solid ${C.border}`,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            padding: 10,
            boxSizing: 'border-box',
            flexShrink: 0,
            boxShadow: qrSrc.length > 0 && !qrFailed ? '0 2px 10px rgba(0,0,0,0.08)' : 'none',
          }}
          >
            {qrSrc.length > 0 && !qrFailed
              ? (
                <img
                  alt="Agent Mobile 连接二维码"
                  src={qrSrc}
                  width={156}
                  height={156}
                  onError={() => { setQrFailed(true) }}
                  style={{ display: 'block', width: 156, height: 156 }}
                />
              )
              : (
                <div style={{ fontSize: 12, color: C.fgFaint, textAlign: 'center', lineHeight: 1.5, padding: 6 }}>
                  {qrSrc.length === 0 ? '请先开启下方任意一种连接方式' : '二维码暂不可用，可点击右侧复制连接码'}
                </div>
              )}
          </div>

          {/* 右侧极简引导与操作 */}
          <div style={{ flex: '1 1 220px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 12 }}>
            <div>
              <div style={{ fontSize: 15, fontWeight: 600, color: C.fg }}>用手机 App 扫一扫连接</div>
              <div style={{ fontSize: 12.5, color: C.fgDim, marginTop: 4, lineHeight: 1.55 }}>
                同 Wi-Fi 或外出用流量均可自动连回电脑，全程端到端加密。
              </div>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
              {hasLanReady ? <QuietDot text="局域网已就绪" color={C.ok} /> : null}
              {hasWanReady ? <QuietDot text="外网已就绪" color={C.accent} /> : null}
              {!hasLanReady && !hasWanReady ? <QuietDot text="未开启连接通道" color={C.bad} /> : null}
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', paddingTop: 2 }}>
              <Btn
                text={copied === 'invite' ? '已复制连接码' : '复制连接码'}
                primary
                disabled={connectToken.length === 0}
                onClick={() => { if (connectToken.length > 0) void copy(connectToken, 'invite') }}
              />
              <Btn
                text={busy === 'code' ? '刷新中...' : '刷新'}
                disabled={busy === 'code'}
                onClick={() => { void rotate() }}
              />
              <span style={{
                fontSize: 12,
                color: secondsLeft > 60 ? C.fgFaint : C.bad,
                fontFamily: C.mono,
                marginLeft: 2,
              }}
              >
                {countdown(secondsLeft)}
              </span>
            </div>
          </div>
        </div>
      </Card>

      {/* 分组 1：连接方式 */}
      <Card>
        <SectionTitle title="连接方式" />

        <SettingRow
          title="局域网直连"
          desc="手机与电脑在同一 Wi-Fi 下高速直连"
          right={(
            <Toggle
              on={state?.allowLan === true}
              disabled={busy === 'lan'}
              onChange={(next) => { void patch('lan', { allowLan: next }) }}
            />
          )}
        />

        <Hairline />

        <SettingRow
          title="外网访问"
          desc="外出使用流量时通过公网地址连回电脑"
          right={(
            <Toggle
              on={state?.allowRemote === true}
              disabled={busy === 'remote'}
              onChange={(next) => { void patch('remote', { allowRemote: next }) }}
            />
          )}
        />

        {state !== null && state.allowRemote
          ? (
            <div style={{ marginTop: 12, minWidth: 0 }}>
              <div style={{ display: 'flex', gap: 8, minWidth: 0 }}>
                <input
                  value={draftUrl}
                  placeholder="填写外网地址，例如 https://your-domain.com"
                  onChange={(event) => {
                    urlDirtyRef.current = true
                    setUrlDirty(true)
                    setDraftUrl(event.target.value)
                  }}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                      event.preventDefault()
                      void savePublicUrl()
                    }
                  }}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    border: `1px solid ${urlDirty ? C.accentBorder : C.border}`,
                    borderRadius: 10,
                    background: C.cardSoft,
                    color: C.fg,
                    padding: '7px 11px',
                    fontSize: 12.5,
                    fontFamily: 'inherit',
                  }}
                />
                <Btn
                  text={busy === 'url' ? '保存中' : '保存'}
                  primary={urlDirty}
                  disabled={busy === 'url'}
                  onClick={() => { void savePublicUrl() }}
                />
              </div>
            </div>
          )
          : null}
      </Card>

      {/* 分组 2：已连接设备 */}
      <Card>
        <SectionTitle
          title="已连接设备"
          right={(
            <span style={{ fontSize: 12, color: C.fgFaint }}>
              {activeDeviceCount > 0 ? `${String(activeDeviceCount)} 台可用` : '暂无设备'}
            </span>
          )}
        />

        {devices.length > 0
          ? (
            <div style={{ display: 'flex', flexDirection: 'column' }}>
              {devices.map((dev, index) => {
                const revoked = dev.revoked === true
                const itemBusy = busy === `dev:${dev.deviceId}`
                return (
                  <div key={dev.deviceId}>
                    {index > 0 ? <Hairline /> : null}
                    <div style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      gap: 12,
                      padding: '2px 0',
                      minWidth: 0,
                    }}
                    >
                      <div style={{ minWidth: 0, flex: 1 }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
                          <span style={{
                            width: 7,
                            height: 7,
                            borderRadius: 4,
                            background: revoked ? C.bad : C.ok,
                            flexShrink: 0,
                          }}
                          />
                          <span style={{ fontSize: 13.5, fontWeight: 500, color: C.fg, overflowWrap: 'anywhere' }}>
                            {dev.name || '未命名手机'}
                          </span>
                          {revoked
                            ? <span style={{ fontSize: 11.5, color: C.bad }}>已暂停</span>
                            : null}
                        </div>
                        <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, paddingLeft: 14 }}>
                          最近活跃：{formatFriendlySeen(dev.lastSeenAt, now)}
                        </div>
                      </div>
                      <Btn
                        text={itemBusy ? '处理中' : revoked ? '恢复' : '移除权限'}
                        ghost={!revoked}
                        disabled={itemBusy}
                        onClick={() => { void toggleDeviceRevoke(dev.deviceId, !revoked) }}
                      />
                    </div>
                  </div>
                )
              })}
            </div>
          )
          : (
            <div style={{ fontSize: 12.5, color: C.fgFaint, padding: '2px 0' }}>
              扫码配对后，你的手机会显示在这里。
            </div>
          )}
      </Card>

      {/* 分组 3：使用偏好 */}
      <Card>
        <SectionTitle title="使用偏好" />

        <SettingRow
          title="提问优先端"
          desc="决定需要确认的提问优先发给手机还是电脑"
          right={(
            <div style={{
              display: 'inline-flex',
              border: `1px solid ${C.border}`,
              background: C.cardSoft,
              borderRadius: 999,
              padding: 2,
              gap: 2,
              flexShrink: 0,
            }}
            >
              {([
                { id: 'phone' as const, label: '手机' },
                { id: 'desktop' as const, label: '电脑' },
              ]).map((opt) => {
                const active = currentAnswerMode === opt.id
                const disabled = busy === 'answerMode'
                return (
                  <button
                    key={opt.id}
                    type="button"
                    disabled={disabled}
                    onClick={() => {
                      if (active) return
                      void patch('answerMode', { answerMode: opt.id })
                    }}
                    style={{
                      border: 'none',
                      borderRadius: 999,
                      padding: '4px 13px',
                      fontSize: 12,
                      fontWeight: active ? 500 : 400,
                      fontFamily: 'inherit',
                      background: active ? C.accent : 'transparent',
                      color: active ? C.onAccent : C.fgDim,
                      cursor: disabled ? 'default' : 'pointer',
                      opacity: disabled ? 0.5 : 1,
                      whiteSpace: 'nowrap',
                    }}
                  >
                    {opt.label}
                  </button>
                )
              })}
            </div>
          )}
        />

        <Hairline />

        <SettingRow
          title="允许远程终端"
          desc="允许已授权手机在会话目录打开命令行"
          right={(
            <Toggle
              on={state?.allowTerminal !== false}
              disabled={busy === 'allowTerminal'}
              onChange={(next) => { void patch('allowTerminal', { allowTerminal: next }) }}
            />
          )}
        />
      </Card>

      {/* 分组 4：折叠式高级设置（默认收起，保持主界面清爽） */}
      <Card padding="13px 18px">
        <button
          type="button"
          onClick={() => { setShowAdvanced((v) => !v) }}
          style={{
            width: '100%',
            border: 'none',
            background: 'transparent',
            padding: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            gap: 10,
            cursor: 'pointer',
            fontFamily: 'inherit',
            textAlign: 'left',
          }}
        >
          <span style={{ fontSize: 13.5, fontWeight: 500, color: C.fg }}>高级设置</span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, fontSize: 12, color: C.fgFaint }}>
            <span>{showAdvanced ? '收起' : '局域网地址、预览端口与安全信息'}</span>
            <svg
              width="14"
              height="14"
              viewBox="0 0 16 16"
              fill="none"
              aria-hidden="true"
              style={{
                transform: showAdvanced ? 'rotate(90deg)' : 'rotate(0deg)',
                transition: 'transform .18s ease',
                flexShrink: 0,
              }}
            >
              <path d="M6 3.5 L10.5 8 L6 12.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </span>
        </button>

        {showAdvanced
          ? (
            <div style={{ marginTop: 12, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ height: 1, background: C.divider }} />

              {sortedLan.length > 0
                ? (
                  <div>
                    <div style={{ fontSize: 12.5, fontWeight: 500, color: C.fg, marginBottom: 6 }}>本机局域网地址</div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {sortedLan.slice(0, 4).map((addr) => (
                        <button
                          key={addr}
                          type="button"
                          onClick={() => { void copy(addr, `lan:${addr}`) }}
                          style={{
                            border: `1px solid ${C.border}`,
                            background: C.cardSoft,
                            color: C.fgDim,
                            borderRadius: 8,
                            padding: '4px 9px',
                            fontSize: 11.5,
                            fontFamily: C.mono,
                            cursor: 'pointer',
                          }}
                        >
                          {copied === `lan:${addr}` ? '已复制' : addr}
                        </button>
                      ))}
                    </div>
                  </div>
                )
                : null}

              <div>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 4 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 500, color: C.fg }}>本机开发预览端口</span>
                  {portsDirty ? <span style={{ fontSize: 11, color: C.accent }}>未保存</span> : null}
                </div>
                <div style={{ fontSize: 11.5, color: C.fgFaint, marginBottom: 6 }}>
                  逗号分隔（如 3000, 5173），留空则关闭预览代理
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    value={draftPorts}
                    placeholder="例如 3000, 5173"
                    onChange={(event) => {
                      portsDirtyRef.current = true
                      setPortsDirty(true)
                      setDraftPorts(event.target.value)
                    }}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                        event.preventDefault()
                        void savePreviewPorts()
                      }
                    }}
                    style={{
                      flex: 1,
                      minWidth: 0,
                      border: `1px solid ${portsDirty ? C.accentBorder : C.border}`,
                      borderRadius: 10,
                      background: C.cardSoft,
                      color: C.fg,
                      padding: '6px 10px',
                      fontSize: 12.5,
                      fontFamily: 'inherit',
                    }}
                  />
                  <Btn
                    text={busy === 'ports' ? '保存中' : '保存'}
                    primary={portsDirty}
                    disabled={busy === 'ports'}
                    onClick={() => { void savePreviewPorts() }}
                  />
                </div>
              </div>

              {state !== null
                ? (
                  <div style={{
                    borderRadius: 10,
                    background: C.cardSoft,
                    padding: '8px 12px',
                  }}
                  >
                    <InfoItem label="网关版本" value={`v${state.version}`} />
                    <InfoItem label="服务端口" value={String(state.port)} />
                    {state.e2eePub ? <InfoItem label="电脑公钥指纹" value={state.e2eePub.slice(0, 12)} /> : null}
                    {state.hostId ? <InfoItem label="主机标识" value={state.hostId} /> : null}
                  </div>
                )
                : null}
            </div>
          )
          : null}
      </Card>
    </div>
  )
}
