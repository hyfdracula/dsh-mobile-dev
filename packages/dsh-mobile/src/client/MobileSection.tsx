/**
 * Agent Mobile 桌面设置面板：
 * 首屏聚焦配对工作区（左侧扫码二维码 + 右侧一键复制连接令牌，与手机端「扫一扫 / 粘贴连接令牌」1:1 对齐），
 * 下方分栏承接连接通道设置、已连接手机与协作权限管理。
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

/** 适配深浅双色的宿主题回退变量，强调色对齐 #2F6BFF。 */
const C = {
  card: 'var(--dsw-alias-surface-card, var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.08)))',
  cardSoft: 'var(--dsw-alias-bg-layer-2, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.06)))',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,0.22))',
  fg: 'var(--dsw-alias-label-primary, currentColor)',
  fgDim: 'var(--dsw-alias-label-secondary, rgba(127,127,127,0.85))',
  fgFaint: 'var(--dsw-alias-label-tertiary, rgba(127,127,127,0.68))',
  accent: 'var(--dsw-alias-state-business-primary, #2F6BFF)',
  accentSoft: 'rgba(47,107,255,0.12)',
  accentBorder: 'rgba(47,107,255,0.32)',
  onAccent: 'var(--dsw-alias-label-on-color, #FFFFFF)',
  ok: 'var(--dsw-alias-state-success-primary, #0F9D63)',
  okBg: 'rgba(15,157,99,0.12)',
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
  if (/\s/.test(trimmed)) return { ok: false, error: '公网地址不能包含空格' }
  if (!/^https?:\/\//i.test(trimmed)) {
    return { ok: false, error: '公网地址必须以 http:// 或 https:// 开头' }
  }
  try {
    const u = new URL(trimmed)
    if ((u.protocol !== 'http:' && u.protocol !== 'https:') || !u.hostname) {
      return { ok: false, error: '公网地址格式不合法，请填写完整的 http:// 或 https:// 地址' }
    }
    const cleanPath = u.pathname === '/' ? '' : u.pathname.replace(/\/+$/, '')
    return { ok: true, url: `${u.origin}${cleanPath}` }
  } catch {
    return { ok: false, error: '公网地址格式不合法，请填写完整的 http:// 或 https:// 地址' }
  }
}

function parsePortsInput(raw: string): { ok: true; ports: number[] } | { ok: false; error: string } {
  const parts = raw.split(/[,，\s]+/).map((s) => s.trim()).filter((s) => s.length > 0)
  const seen = new Set<number>()
  const ports: number[] = []
  for (const part of parts) {
    if (!/^\d+$/.test(part)) {
      return { ok: false, error: `端口号「${part}」不合法，请填写 1 到 65535 之间的整数` }
    }
    const n = Number.parseInt(part, 10)
    if (!Number.isInteger(n) || n < 1 || n > 65535) {
      return { ok: false, error: `端口号 ${String(n)} 超出范围（允许 1..65535）` }
    }
    if (!seen.has(n)) {
      seen.add(n)
      ports.push(n)
    }
    if (ports.length > 64) {
      return { ok: false, error: '最多允许配置 64 个预览端口' }
    }
  }
  return { ok: true, ports }
}

function Card(props: { children: ReactNode; hero?: boolean }): ReactNode {
  const hero = props.hero === true
  return (
    <div style={{
      border: `1px solid ${hero ? C.accentBorder : C.border}`,
      background: C.card,
      borderRadius: 16,
      padding: hero ? '16px 18px' : '14px 16px',
      minWidth: 0,
    }}
    >
      {props.children}
    </div>
  )
}

function SectionHead(props: { title: string; subtitle?: string; right?: ReactNode }): ReactNode {
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
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 14, fontWeight: 600, color: C.fg, whiteSpace: 'nowrap' }}>{props.title}</div>
        {props.subtitle
          ? (
            <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, overflowWrap: 'anywhere' }}>
              {props.subtitle}
            </div>
          )
          : null}
      </div>
      {props.right}
    </div>
  )
}

function Chip(props: { text: string; tone: 'ok' | 'idle' | 'bad' | 'accent' }): ReactNode {
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
      gap: 5,
      fontSize: 12,
      fontWeight: 500,
      color,
      background: bg,
      borderRadius: 999,
      padding: '3px 10px',
      flexShrink: 0,
      whiteSpace: 'nowrap',
    }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 3, background: color, flexShrink: 0 }} />
      {props.text}
    </span>
  )
}

function Toggle(props: { on: boolean; onChange: (next: boolean) => void; disabled?: boolean }): ReactNode {
  const width = 42
  const height = 24
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
        top: 3,
        left: props.on ? width - height + 3 : 3,
        width: height - 6,
        height: height - 6,
        borderRadius: '50%',
        background: C.onAccent,
        boxShadow: '0 1px 2px rgba(0,0,0,0.22)',
        transition: 'left .18s cubic-bezier(.34,1.4,.64,1)',
      }}
      />
    </button>
  )
}

function Btn(props: { text: string; onClick: () => void; primary?: boolean; disabled?: boolean }): ReactNode {
  const primary = props.primary === true
  const disabled = props.disabled === true
  return (
    <button
      type="button"
      disabled={disabled}
      onClick={props.onClick}
      style={{
        border: primary ? 'none' : `1px solid ${C.border}`,
        background: primary ? C.accent : C.cardSoft,
        color: primary ? C.onAccent : C.fg,
        borderRadius: 10,
        padding: '6px 13px',
        fontSize: 13,
        fontWeight: primary ? 500 : 400,
        fontFamily: 'inherit',
        lineHeight: 1.45,
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

function MetaPill(props: { label: string; value: string }): ReactNode {
  return (
    <div style={{
      border: `1px solid ${C.border}`,
      background: C.cardSoft,
      borderRadius: 10,
      padding: '7px 10px',
      minWidth: 0,
      flex: '1 1 130px',
    }}
    >
      <div style={{ fontSize: 11, color: C.fgFaint, marginBottom: 2 }}>{props.label}</div>
      <div style={{
        fontSize: 12.5,
        color: C.fg,
        fontWeight: 500,
        fontFamily: C.mono,
        overflowWrap: 'anywhere',
        wordBreak: 'break-word',
      }}
      >
        {props.value}
      </div>
    </div>
  )
}

function countdown(secondsLeft: number): string {
  const safe = Math.max(0, secondsLeft)
  const mm = Math.floor(safe / 60)
  const ss = safe % 60
  return `${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
}

function formatLastSeen(ts: number): string {
  if (!Number.isFinite(ts) || ts <= 0) return '刚刚'
  const d = new Date(ts)
  const pad = (n: number): string => String(n).padStart(2, '0')
  return `${String(d.getFullYear())}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
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

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, minWidth: 0 }}>
      {/* 顶部品牌身份栏 */}
      <Card>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
            <svg
              viewBox="0 0 64 64"
              width="40"
              height="40"
              fill="none"
              aria-hidden="true"
              style={{ flexShrink: 0, display: 'block', borderRadius: 11 }}
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
              <path
                d="M12.5 22.5 L20.5 30 L12.5 37.5"
                stroke="#FFFFFF"
                strokeWidth="5.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
              <path
                d="M26 40 H38"
                stroke="#FFFFFF"
                strokeWidth="5.2"
                strokeLinecap="round"
              />
              <path
                d="M51.5 22.5 L43.5 30 L51.5 37.5"
                stroke="#FFFFFF"
                strokeWidth="5.2"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
            <div style={{ minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 15, fontWeight: 700, color: C.fg }}>Agent Mobile</span>
                {state?.e2ee ? <Chip text="端到端加密" tone="accent" /> : null}
              </div>
              <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                电脑：{state?.host ?? '-'} · 服务端口 {state ? String(state.port) : '-'}
              </div>
            </div>
          </div>
          <Chip text={online ? '手机在线' : '等待连接'} tone={online ? 'ok' : 'idle'} />
        </div>
      </Card>

      {Array.isArray(state?.pendingPairRequests) && state.pendingPairRequests.length > 0
        ? (
          <Card hero>
            <SectionHead
              title={`收到 ${String(state.pendingPairRequests.length)} 条远程配对申请`}
              subtitle="请核对新手机屏幕上显示的 4 位核对码，确认是本人设备后再点击批准"
            />
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
                    border: `1px solid ${C.accentBorder}`,
                    background: C.cardSoft,
                  }}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 12, minWidth: 0 }}>
                    <span
                      style={{
                        fontFamily: C.mono,
                        fontSize: 20,
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
                        {req.source === 'remote' ? '公网远程申请' : '局域网申请'} · 剩余 {countdown(Math.floor((req.expiresAt - now) / 1000))}
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
                      text={busy === `pair:${req.id}` ? '处理中...' : '批准配对'}
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
          <Card hero>
            <SectionHead
              title={`当前有 ${String(state.pendingAsks.length)} 组提问等待手机回答`}
              subtitle={state.pendingAsks[0]?.firstPrompt || state.pendingAsks[0]?.firstHeader || '可立即交还桌面会话框回答，无需切换到手机'}
              right={<Btn text={busy === 'takeover' ? '交还中...' : '立即在电脑上接管'} primary disabled={busy === 'takeover'} onClick={() => { void takeoverOnDesktop() }} />}
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
              alignItems: 'flex-start',
              justifyContent: 'space-between',
              gap: 10,
              border: `1px solid ${C.bad}`,
              background: C.badBg,
              color: C.bad,
              borderRadius: 12,
              padding: '10px 12px',
              fontSize: 12.5,
              lineHeight: 1.45,
              minWidth: 0,
              overflowWrap: 'anywhere',
            }}
          >
            <span style={{ minWidth: 0, overflowWrap: 'anywhere' }}>操作提示：{error}</span>
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
              aria-label="关闭错误提示"
            >
              ×
            </button>
          </div>
        )
        : null}

      {/* 首屏焦点：方式一（扫一扫二维码）+ 方式二（一键复制连接令牌），与手机端 1:1 对齐 */}
      <Card hero>
        <SectionHead
          title="连接手机 App"
          subtitle="在手机打开 Agent Mobile，扫码或粘贴右侧连接令牌即可连通，不区分局域网与外网"
          right={<Btn text={busy === 'code' ? '刷新中...' : '刷新二维码和令牌'} disabled={busy === 'code'} onClick={() => { void rotate() }} />}
        />

        <div style={{ display: 'flex', gap: 20, alignItems: 'stretch', flexWrap: 'wrap', minWidth: 0 }}>
          {/* 左：方式一 扫一扫二维码 */}
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, flexShrink: 0 }}>
            <div style={{
              width: 196,
              minHeight: 196,
              borderRadius: 14,
              border: `1px solid ${C.border}`,
              background: qrSrc.length > 0 && !qrFailed ? C.qrPlate : C.cardSoft,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              padding: 10,
              boxSizing: 'border-box',
            }}
            >
              {qrSrc.length > 0 && !qrFailed
                ? (
                  <img
                    alt="Agent Mobile 配对二维码"
                    src={qrSrc}
                    width={176}
                    height={176}
                    onError={() => { setQrFailed(true) }}
                    style={{ display: 'block', width: 176, height: 176 }}
                  />
                )
                : (
                  <div style={{ fontSize: 12, color: C.fgFaint, textAlign: 'center', lineHeight: 1.5, padding: 8 }}>
                    {qrSrc.length === 0
                      ? '请先在下方开启「同 Wi-Fi 局域网直连」或填写外网访问地址'
                      : '二维码加载失败，请使用右侧「复制连接令牌」连接'}
                  </div>
                )}
            </div>
            <span style={{ fontSize: 12, color: C.fgDim, fontWeight: 500 }}>
              方式一：手机扫一扫二维码
            </span>
          </div>

          {/* 右：方式二 一键复制连接令牌 */}
          <div style={{ flex: '1 1 240px', minWidth: 0, display: 'flex', flexDirection: 'column', justifyContent: 'space-between', gap: 12 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 13.5, fontWeight: 600, color: C.fg }}>方式二：复制连接令牌</span>
                <span style={{
                  fontSize: 12,
                  fontWeight: 500,
                  color: copied === 'invite' ? C.ok : secondsLeft > 60 ? C.fgFaint : C.bad,
                }}
                >
                  {copied === 'invite' ? '已复制到剪贴板' : `有效期 ${countdown(secondsLeft)}`}
                </span>
              </div>

              <div style={{ fontSize: 12.5, color: C.fgDim, lineHeight: 1.55 }}>
                不方便扫码时（例如人不在电脑旁），复制下方连接令牌发给手机，在手机 App 里粘贴即可自动连上。
              </div>

              <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                {hasLanReady ? <Chip text="局域网通道已就绪" tone="ok" /> : null}
                {hasWanReady ? <Chip text="外网通道已就绪" tone="accent" /> : null}
                {!hasLanReady && !hasWanReady ? <Chip text="未启用可用通道" tone="bad" /> : null}
              </div>

              {connectToken.length > 0
                ? (
                  <button
                    type="button"
                    onClick={() => { void copy(connectToken, 'invite') }}
                    title="点击复制完整连接令牌"
                    style={{
                      border: `1px solid ${C.border}`,
                      background: C.cardSoft,
                      color: C.fgDim,
                      borderRadius: 10,
                      padding: '9px 12px',
                      fontSize: 12,
                      fontFamily: C.mono,
                      textAlign: 'left',
                      cursor: 'pointer',
                      whiteSpace: 'nowrap',
                      overflow: 'hidden',
                      textOverflow: 'ellipsis',
                      width: '100%',
                      boxSizing: 'border-box',
                    }}
                  >
                    {connectToken}
                  </button>
                )
                : null}

              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                <Btn
                  text={copied === 'invite' ? '已复制连接令牌' : '复制连接令牌'}
                  primary
                  disabled={connectToken.length === 0}
                  onClick={() => {
                    if (connectToken.length > 0) void copy(connectToken, 'invite')
                  }}
                />
                <span style={{ fontSize: 11.5, color: C.fgFaint }}>
                  不含长期密钥 · 单次有效
                </span>
              </div>
            </div>

            <div style={{ fontSize: 11.5, color: C.fgFaint, lineHeight: 1.5 }}>
              配对成功后会自动刷新令牌，保障连接安全；多台手机可分别扫码或复制令牌独立连接。
            </div>
          </div>
        </div>
      </Card>

      {/* 分组 1：连接通道设置 */}
      <Card>
        <SectionHead
          title="连接通道设置"
          subtitle="二维码和连接令牌会自动附带以下已开启的通道，手机端无需区分局域网或外网"
        />

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0', minWidth: 0 }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>同 Wi-Fi 局域网直连</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              手机和电脑连在同一 Wi-Fi 时自动走局域网高速直连（需系统防火墙放行 {state ? String(state.port) : '8901'} 端口）
            </div>
          </div>
          <Toggle
            on={state?.allowLan === true}
            disabled={busy === 'lan'}
            onChange={(next) => { void patch('lan', { allowLan: next }) }}
          />
        </div>

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0', minWidth: 0 }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>外网访问通道</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              外出用 4G/5G 流量或异地使用时，通过下方公网隧道地址自动连回电脑（建议使用 HTTPS）
            </div>
          </div>
          <Toggle
            on={state?.allowRemote === true}
            disabled={busy === 'remote'}
            onChange={(next) => { void patch('remote', { allowRemote: next }) }}
          />
        </div>

        {state !== null && state.allowLan && state.lan.length > 0
          ? (
            <div style={{ marginTop: 8, display: 'flex', flexWrap: 'wrap', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11.5, color: C.fgFaint, marginRight: 2 }}>本机局域网地址：</span>
              {state.lan.slice(0, 4).map((addr) => (
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
          )
          : null}

        {state !== null && state.allowRemote
          ? (
            <div style={{ marginTop: 10, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 4 }}>
                <span style={{ fontSize: 12, color: C.fgFaint }}>外网访问地址（例如 Cloudflare 隧道域名，需含 https://）</span>
                {urlDirty ? <span style={{ fontSize: 11, color: C.accent }}>有未保存修改</span> : null}
              </div>
              <div style={{ display: 'flex', gap: 8, minWidth: 0 }}>
                <input
                  value={draftUrl}
                  placeholder="https://agent.example.com"
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
                    border: `1px solid ${C.border}`,
                    borderRadius: 9,
                    background: C.cardSoft,
                    color: C.fg,
                    padding: '6px 10px',
                    fontSize: 13,
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

      {/* 分组 2：已连接的手机 */}
      <Card>
        <SectionHead
          title="已连接的手机"
          subtitle="所有对话与文件传输均默认启用端到端加密，可随时撤销不再使用的设备"
          right={<Chip text={state?.e2ee ? '端到端加密已开启' : '标准鉴权'} tone={state?.e2ee ? 'ok' : 'idle'} />}
        />

        {state?.e2eePub
          ? (
            <div style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              gap: 10,
              padding: '7px 10px',
              borderRadius: 10,
              background: C.cardSoft,
              border: `1px solid ${C.border}`,
              marginBottom: 8,
            }}
            >
              <span style={{ fontSize: 12, color: C.fgDim }}>电脑公钥指纹</span>
              <span style={{ fontSize: 12, fontFamily: C.mono, color: C.fg, fontWeight: 600 }}>
                {state.e2eePub.slice(0, 12)}
              </span>
            </div>
          )
          : null}

        {Array.isArray(state?.devices) && state.devices.length > 0
          ? (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {state.devices.map((dev) => {
                const revoked = dev.revoked === true
                const itemBusy = busy === `dev:${dev.deviceId}`
                return (
                  <div
                    key={dev.deviceId}
                    style={{
                      border: `1px solid ${C.border}`,
                      background: C.cardSoft,
                      borderRadius: 10,
                      padding: '8px 10px',
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      gap: 10,
                      minWidth: 0,
                    }}
                  >
                    <div style={{ minWidth: 0, flex: 1 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                        <span style={{ fontSize: 13, fontWeight: 600, color: C.fg, overflowWrap: 'anywhere' }}>
                          {dev.name || '未命名设备'}
                        </span>
                        <Chip text={revoked ? '已撤销' : '已授权'} tone={revoked ? 'bad' : 'ok'} />
                      </div>
                      <div style={{
                        fontSize: 11.5,
                        color: C.fgFaint,
                        marginTop: 3,
                        fontFamily: C.mono,
                        overflowWrap: 'anywhere',
                      }}
                      >
                        指纹：{dev.pubKey.slice(0, 12)} · 最近活跃：{formatLastSeen(dev.lastSeenAt)}
                      </div>
                    </div>
                    <Btn
                      text={itemBusy ? '处理中' : revoked ? '恢复' : '撤销'}
                      disabled={itemBusy}
                      onClick={() => { void toggleDeviceRevoke(dev.deviceId, !revoked) }}
                    />
                  </div>
                )
              })}
            </div>
          )
          : (
            <div style={{ fontSize: 12, color: C.fgFaint, lineHeight: 1.5 }}>
              还没有已连接的手机。用上方二维码或「复制连接令牌」完成首次配对后，设备会自动登记在这里。
            </div>
          )}
      </Card>

      {/* 分组 3：协作与权限管理 */}
      <Card>
        <SectionHead title="协作与权限管理" subtitle="设置提问由哪一端回答，以及手机可使用的电脑权限" />

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0', flexWrap: 'wrap' }}>
          <div style={{ minWidth: 0, flex: '1 1 200px' }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>谁来回答提问</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              切回「电脑为主」时，等待手机审批的问题卡将立即交还桌面端
            </div>
          </div>
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
              { id: 'phone' as const, label: '手机为主' },
              { id: 'desktop' as const, label: '电脑为主' },
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
                    padding: '4px 12px',
                    fontSize: 12,
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
        </div>

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0' }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>允许远程终端</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              允许已授权手机在会话工作目录打开交互终端
            </div>
          </div>
          <Toggle
            on={state?.allowTerminal !== false}
            disabled={busy === 'allowTerminal'}
            onChange={(next) => { void patch('allowTerminal', { allowTerminal: next }) }}
          />
        </div>

        <div style={{ marginTop: 8 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, marginBottom: 4 }}>
            <span style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>允许预览的本机开发端口</span>
            {portsDirty ? <span style={{ fontSize: 11, color: C.accent }}>有未保存修改</span> : null}
          </div>
          <div style={{ fontSize: 12, color: C.fgFaint, marginBottom: 6 }}>
            逗号分隔填写 1..65535 端口；留空则关闭本机开发服预览代理
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
                border: `1px solid ${C.border}`,
                borderRadius: 9,
                background: C.cardSoft,
                color: C.fg,
                padding: '6px 10px',
                fontSize: 13,
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
      </Card>

      {state !== null
        ? (
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
            <MetaPill label="网关版本" value={`v${state.version}`} />
            <MetaPill label="监听端口" value={String(state.port)} />
            {state.hostId ? <MetaPill label="主机标识" value={state.hostId} /> : null}
          </div>
        )
        : null}
    </div>
  )
}
