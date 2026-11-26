/**
 * Agent Mobile 桌面设置面板：
 * 首屏聚焦配对工作区（二维码 + 6 位一次性配对码 + 入口复制），
 * 下方分栏承接网络接入策略、端到端加密设备授权、协作权限与网关概览。
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

interface PanelState {
  ok: boolean
  host: string
  hostId?: string
  e2ee?: boolean
  e2eePub?: string
  devices?: PairedDevice[]
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
  const codeChars = (state?.code && state.code.length === 6 ? state.code : '------').split('')
  const primaryAddress = state?.base && state.base.length > 0
    ? state.base
    : (state?.lan && state.lan.length > 0 ? String(state.lan[0]) : '')

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
                {state?.e2ee ? <Chip text="Noise_IK 加密" tone="accent" /> : null}
              </div>
              <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 2, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                本机：{state?.host ?? '-'} · 端口 {state ? String(state.port) : '-'}
              </div>
            </div>
          </div>
          <Chip text={online ? '手机在线' : '等待配对'} tone={online ? 'ok' : 'idle'} />
        </div>
      </Card>

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

      {/* 首屏焦点：扫码 + 6 位数字配对 Hero 区 */}
      <Card hero>
        <SectionHead
          title="连接手机 App"
          subtitle="打开 Agent Mobile 扫码，或填入电脑地址与下方 6 位一次性配对码"
          right={<Btn text={busy === 'code' ? '更新中...' : '换一个新码'} primary disabled={busy === 'code'} onClick={() => { void rotate() }} />}
        />

        <div style={{ display: 'flex', gap: 18, alignItems: 'center', flexWrap: 'wrap', minWidth: 0 }}>
          {/* 左：二维码展示框 */}
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
            flexShrink: 0,
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
                    ? '请先在下方开启「局域网直连」或填写公网地址以生成二维码'
                    : '二维码生成失败，请使用右侧 6 位数字配对码'}
                </div>
              )}
          </div>

          {/* 右：6 位配对码格 + 倒计时 + 入口复制 */}
          <div style={{ flex: '1 1 220px', minWidth: 0, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
              <span style={{ fontSize: 12.5, fontWeight: 500, color: C.fgDim }}>6 位一次性配对码</span>
              <span style={{
                fontSize: 12,
                fontWeight: 500,
                color: copied === 'code' ? C.ok : secondsLeft > 60 ? C.fgFaint : C.bad,
              }}
              >
                {copied === 'code' ? '已复制配对码' : `有效期 ${countdown(secondsLeft)}`}
              </span>
            </div>

            <button
              type="button"
              disabled={!state?.code}
              onClick={() => { if (state?.code) void copy(state.code, 'code') }}
              title="点击复制 6 位配对码"
              style={{
                border: `1px solid ${C.border}`,
                background: C.cardSoft,
                borderRadius: 12,
                padding: '10px 8px',
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                gap: 6,
                cursor: state?.code ? 'pointer' : 'default',
                opacity: state?.code ? 1 : 0.5,
              }}
            >
              {codeChars.map((ch, idx) => (
                <span
                  key={idx}
                  style={{
                    width: 28,
                    height: 36,
                    borderRadius: 8,
                    background: C.card,
                    border: `1px solid ${C.border}`,
                    display: 'inline-flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    fontFamily: C.mono,
                    fontSize: 20,
                    fontWeight: 700,
                    color: C.fg,
                  }}
                >
                  {ch}
                </span>
              ))}
            </button>

            {primaryAddress.length > 0
              ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div style={{ fontSize: 11.5, color: C.fgFaint }}>当前配对入口（点击复制）</div>
                  <button
                    type="button"
                    onClick={() => { void copy(primaryAddress, 'addr') }}
                    style={{
                      border: `1px solid ${C.border}`,
                      background: C.cardSoft,
                      color: C.fg,
                      borderRadius: 9,
                      padding: '6px 10px',
                      fontSize: 12,
                      fontFamily: C.mono,
                      textAlign: 'left',
                      cursor: 'pointer',
                      overflowWrap: 'anywhere',
                      wordBreak: 'break-word',
                    }}
                  >
                    {copied === 'addr' ? '已复制：' : ''}{primaryAddress}
                  </button>
                </div>
              )
              : null}

            <div style={{ fontSize: 11.5, color: C.fgFaint, lineHeight: 1.45 }}>
              配对成功或连续输错 8 次将自动更换新码；多台手机可分别扫码各自持独立密钥对。
            </div>
          </div>
        </div>
      </Card>

      {/* 分组 1：网络与可达性 */}
      <Card>
        <SectionHead title="网络与接入策略" subtitle="控制同 Wi-Fi 直连与公网隧道回连入口" />

        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0', minWidth: 0 }}>
          <div style={{ minWidth: 0 }}>
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>局域网直连</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              同一 Wi-Fi 下手机低延迟直连本机，自动附带全部本机局域网候选地址
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
            <div style={{ fontSize: 13, fontWeight: 500, color: C.fg }}>公网访问</div>
            <div style={{ fontSize: 12, color: C.fgFaint, overflowWrap: 'anywhere' }}>
              外出切换蜂窝网络时经你的反向代理或隧道地址访问（建议 HTTPS + 端到端加密）
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
            <div style={{ marginTop: 8, display: 'flex', flexWrap: 'wrap', gap: 6 }}>
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
                <span style={{ fontSize: 12, color: C.fgFaint }}>公网隧道地址（需含 https:// 或 http://）</span>
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

      {/* 分组 2：已配对设备与端到端加密 */}
      <Card>
        <SectionHead
          title="已配对设备与密钥指纹"
          subtitle="基于 Noise_IK_25519_ChaChaPoly_SHA256 验证对端身份"
          right={<Chip text={state?.e2ee ? 'E2EE 已就绪' : '标准鉴权'} tone={state?.e2ee ? 'ok' : 'idle'} />}
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
              暂无已配对手机。完成首次扫码与加密握手后，设备名称与公钥指纹会自动登记于此。
            </div>
          )}
      </Card>

      {/* 分组 3：协作与安全权限 */}
      <Card>
        <SectionHead title="协作与远程控制边界" subtitle="统一调度提问答题归属、远程终端和本地预览代理" />

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
