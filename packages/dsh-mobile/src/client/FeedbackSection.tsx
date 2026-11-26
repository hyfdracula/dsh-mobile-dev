/**
 * DSH 设置对话框中的「用户反馈」管理面板（仅本机持有管理员密钥时注册显示）。
 * @module @deepseek-ai/dsh-mobile/client/FeedbackSection
 */
import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactElement } from 'react'

interface TicketFile {
  name: string
  kind: string
  size: number
}

interface Ticket {
  id: string
  kind: string
  title: string
  body: string
  status: string
  env: string
  contact: string
  created_at: number
  updated_at: number
  files: TicketFile[]
  replies: { author: string; text: string; at: number }[]
}

interface State {
  configured: boolean
  tickets?: Ticket[]
  summary?: { counts?: { status: string; n: number }[] }
  error?: string
}

const C = {
  card: 'var(--dsw-alias-surface-card, var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.08)))',
  cardSoft: 'var(--dsw-alias-bg-layer-2, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.06)))',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,0.24))',
  fg: 'var(--dsw-alias-label-primary, currentColor)',
  fgDim: 'var(--dsw-alias-label-secondary, rgba(127,127,127,0.85))',
  fgFaint: 'var(--dsw-alias-label-tertiary, rgba(127,127,127,0.68))',
  accent: 'var(--dsw-alias-state-business-primary, #1a6ef0)',
  onAccent: 'var(--dsw-alias-label-on-color, #f8fafc)',
  ok: 'var(--dsw-alias-state-success-primary, #1a9a5e)',
  bad: 'var(--dsw-alias-state-error-primary, #d4380d)',
  badBg: 'rgba(212,56,13,0.10)',
}

const ROUTE = '/api/dsh-mobile/panel/feedback'

const STATUS: Record<string, { label: string; color: string }> = {
  open: { label: '待处理', color: C.accent },
  doing: { label: '处理中', color: C.accent },
  done: { label: '已完成', color: C.ok },
  wontfix: { label: '不处理', color: C.fgFaint },
}

const KIND: Record<string, string> = {
  bug: '问题反馈',
  feature: '功能建议',
  ux: '体验问题',
  other: '其他',
}

const stamp = (ms: number): string => {
  const d = new Date(ms)
  const two = (n: number): string => (n < 10 ? `0${String(n)}` : String(n))
  return `${String(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`
}

const formatIso = (ms: number): string => {
  if (!Number.isFinite(ms) || ms <= 0) return '未知'
  try {
    return `${stamp(ms)} (${new Date(ms).toISOString()})`
  } catch {
    return stamp(ms)
  }
}

const formatSize = (n: number): string => (
  n >= 1024 * 1024
    ? `${(n / 1024 / 1024).toFixed(1)} MB`
    : `${String(Math.max(1, Math.round(n / 1024)))} KB`
)

const isInlineTextFile = (f: TicketFile): boolean => (
  f.size <= 65536 && (f.kind === 'log' || /\.(?:txt|log|json|md|csv|yml|yaml)$/i.test(f.name))
)

async function writeClipboard(text: string): Promise<boolean> {
  if (typeof navigator !== 'undefined' && navigator.clipboard !== undefined) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // 回退到 DOM execCommand，兼容非 HTTPS 内嵌宿主面板
    }
  }
  if (typeof document === 'undefined') return false
  const ta = document.createElement('textarea')
  ta.value = text
  ta.setAttribute('readonly', 'true')
  ta.style.position = 'fixed'
  ta.style.left = '-9999px'
  ta.style.opacity = '0'
  document.body.appendChild(ta)
  ta.select()
  let copied = false
  try {
    copied = document.execCommand('copy')
  } catch {
    copied = false
  }
  document.body.removeChild(ta)
  return copied
}

async function fetchInlineTextAttachment(ticketId: string, fileName: string): Promise<string> {
  try {
    const res = await fetch(
      `${ROUTE}/file?id=${encodeURIComponent(ticketId)}&name=${encodeURIComponent(fileName)}`,
      { credentials: 'same-origin', cache: 'no-store' },
    )
    if (!res.ok) return `[读取失败 HTTP ${String(res.status)}]`
    const text = await res.text()
    if (text.length > 16000) {
      return `${text.slice(0, 16000)}\n... [已截断，总长度 ${String(text.length)} 字符]`
    }
    return text
  } catch (e) {
    return `[读取失败: ${e instanceof Error ? e.message : String(e)}]`
  }
}

async function buildAiTriageText(t: Ticket): Promise<string> {
  const origin = typeof window !== 'undefined' ? window.location.origin : ''
  const kindLabel = KIND[t.kind] ?? t.kind
  const statusLabel = STATUS[t.status]?.label ?? t.status
  const lines: string[] = [
    `# Agent Mobile 用户反馈工单 (${t.id})`,
    '',
    '## 工单元数据',
    `- 工单编号: ${t.id}`,
    `- 反馈分类: ${kindLabel} (${t.kind})`,
    `- 当前状态: ${statusLabel} (${t.status})`,
    `- 提交时间: ${formatIso(t.created_at)}`,
    `- 最后更新: ${formatIso(t.updated_at)}`,
    `- 运行环境: ${t.env !== '' ? t.env : '（未采集）'}`,
    `- 联系方式: ${t.contact !== '' ? t.contact : '（未填写）'}`,
    '',
    '## 问题标题',
    t.title,
    '',
    '## 详细描述',
    t.body !== '' ? t.body : '（无正文）',
    '',
    '## 附件清单与内容',
  ]

  if (t.files.length === 0) {
    lines.push('无附件')
  } else {
    for (const f of t.files) {
      const fileUrl = `${origin}${ROUTE}/file?id=${encodeURIComponent(t.id)}&name=${encodeURIComponent(f.name)}`
      lines.push(`- ${f.name} [类型: ${f.kind} | 大小: ${formatSize(f.size)}] -> ${fileUrl}`)
      if (isInlineTextFile(f)) {
        const inlineContent = await fetchInlineTextAttachment(t.id, f.name)
        lines.push('```text')
        lines.push(inlineContent)
        lines.push('```')
      }
    }
  }

  lines.push('')
  lines.push('## 处理与回复记录')
  if (t.replies.length === 0) {
    lines.push('暂无历史回复')
  } else {
    for (const r of t.replies) {
      const role = r.author === 'admin' ? '开发者' : '用户'
      lines.push(`- [${stamp(r.at)}] ${role}: ${r.text}`)
    }
  }

  lines.push('')
  lines.push('## 工程上下文与排查要求')
  lines.push('- 项目仓库: Agent Mobile（app-shell/ 鸿蒙客户端 + gateway/ DSH 桌面端网关插件）')
  lines.push('- 请结合上述工单描述、运行环境、日志/附件与历史回复定位根因，列出涉及的文件路径与修改方案。')
  lines.push('- 如需补充给用户的中文回复或状态变更建议，请一并给出。')
  return lines.join('\n')
}

async function readErrorMessage(res: Response): Promise<string> {
  const text = await res.text()
  if (text.length > 0) {
    try {
      const parsed: unknown = JSON.parse(text)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const err = (parsed as Record<string, unknown>).error
        if (typeof err === 'string' && err.trim().length > 0) return err.trim()
      }
    } catch {
      // fallback to plain slice
    }
    return text.slice(0, 200)
  }
  return `HTTP ${String(res.status)}`
}

async function post(path: string, body: unknown): Promise<void> {
  const res = await fetch(`${ROUTE}/${path}`, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    throw new Error(await readErrorMessage(res))
  }
}

function btn(primary: boolean, disabled: boolean): CSSProperties {
  return {
    fontSize: 12,
    fontFamily: 'inherit',
    lineHeight: 1.45,
    padding: '5px 12px',
    borderRadius: 8,
    border: `1px solid ${primary ? C.accent : C.border}`,
    background: primary ? C.accent : 'transparent',
    color: primary ? C.onAccent : C.fgDim,
    cursor: disabled ? 'default' : 'pointer',
    opacity: disabled ? 0.5 : 1,
    flexShrink: 0,
    whiteSpace: 'nowrap',
  }
}

export function FeedbackSection(): ReactElement | null {
  const [state, setState] = useState<State | null>(null)
  const [seen, setSeen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [reply, setReply] = useState<Record<string, string>>({})
  const [open, setOpen] = useState('')
  const [copyingId, setCopyingId] = useState('')
  const [copiedId, setCopiedId] = useState('')
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const load = useCallback(async (): Promise<void> => {
    setLoading(true)
    try {
      const res = await fetch(`${ROUTE}/state`, { credentials: 'same-origin', cache: 'no-store' })
      if (!res.ok) {
        const msg = await readErrorMessage(res)
        setError(msg)
        setState((prev) => prev ?? { configured: true, tickets: [] })
        return
      }
      const data = (await res.json()) as State
      setState(data)
      setError(data.error ?? '')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
      setSeen(true)
    }
  }, [])

  useEffect(() => {
    void load()
    const timer = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      void load()
    }, 30000)
    return () => {
      clearInterval(timer)
      if (copyTimerRef.current !== null) clearTimeout(copyTimerRef.current)
    }
  }, [load])

  if (!seen || state === null || state.configured !== true) {
    return null
  }

  const handleCopyForAi = async (t: Ticket): Promise<void> => {
    if (copyingId === t.id) return
    setCopyingId(t.id)
    setError('')
    try {
      const text = await buildAiTriageText(t)
      const ok = await writeClipboard(text)
      if (!ok) {
        setError('复制到剪贴板失败，请检查浏览器或系统剪贴板权限。')
        return
      }
      setCopiedId(t.id)
      if (copyTimerRef.current !== null) clearTimeout(copyTimerRef.current)
      copyTimerRef.current = setTimeout(() => {
        setCopiedId('')
        copyTimerRef.current = null
      }, 2000)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setCopyingId('')
    }
  }

  const act = async (id: string, work: () => Promise<void>): Promise<void> => {
    setBusy(id)
    setError('')
    try {
      await work()
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy('')
    }
  }

  const tickets = state.tickets ?? []
  const counts = state.summary?.counts ?? []

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', minWidth: 0 }}>
        <span style={{ fontSize: 13, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>
          共 {String(tickets.length)} 条
        </span>
        {counts.map((one) => (
          <span
            key={one.status}
            style={{
              fontSize: 12,
              color: STATUS[one.status]?.color ?? C.fgFaint,
              flexShrink: 0,
              whiteSpace: 'nowrap',
            }}
          >
            {STATUS[one.status]?.label ?? one.status} {String(one.n)}
          </span>
        ))}
        <span style={{ flex: 1 }} />
        <button
          type="button"
          disabled={loading}
          onClick={() => { void load() }}
          style={{
            fontSize: 12,
            fontFamily: 'inherit',
            lineHeight: 1.45,
            padding: '4px 10px',
            borderRadius: 8,
            border: `1px solid ${C.border}`,
            background: 'transparent',
            color: C.fgDim,
            cursor: loading ? 'default' : 'pointer',
            opacity: loading ? 0.5 : 1,
            flexShrink: 0,
            whiteSpace: 'nowrap',
          }}
        >
          刷新
        </button>
      </div>

      {error.length > 0
        ? (
          <div
            role="alert"
            style={{
              border: `1px solid ${C.bad}`,
              background: C.badBg,
              color: C.bad,
              borderRadius: 10,
              padding: '9px 12px',
              fontSize: 12.5,
              lineHeight: 1.45,
              minWidth: 0,
              overflowWrap: 'anywhere',
              wordBreak: 'break-word',
            }}
          >
            出错了：{error}
          </div>
        )
        : null}

      {tickets.length === 0
        ? <div style={{ fontSize: 12, color: C.fgFaint }}>还没有人反馈。</div>
        : null}

      {tickets.map((t) => {
        const st = STATUS[t.status] ?? { label: t.status, color: C.fgFaint }
        const expanded = open === t.id
        const replyText = (reply[t.id] ?? '').trim()
        const replyDisabled = busy === t.id || replyText === ''
        const isCopying = copyingId === t.id
        const isCopied = copiedId === t.id
        const copyLabel = isCopying ? '整理中...' : (isCopied ? '已复制给 AI' : '复制给 AI')
        return (
          <div
            key={t.id}
            style={{
              border: `1px solid ${C.border}`,
              background: C.card,
              borderRadius: 12,
              padding: '12px 14px',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
              minWidth: 0,
            }}
          >
            <div
              role="button"
              tabIndex={0}
              onClick={() => { setOpen(expanded ? '' : t.id) }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  setOpen(expanded ? '' : t.id)
                }
              }}
              style={{ display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', minWidth: 0 }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', minWidth: 0 }}>
                <span style={{ fontSize: 12, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>
                  {expanded ? '▾' : '▸'}
                </span>
                <span style={{ fontSize: 11, color: C.fgFaint, flexShrink: 0, whiteSpace: 'nowrap' }}>{t.id}</span>
                <span style={{ fontSize: 11, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>{KIND[t.kind] ?? t.kind}</span>
                <span style={{ fontSize: 11, color: C.fgFaint, flexShrink: 0, whiteSpace: 'nowrap' }}>{stamp(t.created_at)}</span>
                <span style={{ flex: 1 }} />
                <button
                  type="button"
                  disabled={isCopying}
                  onClick={(e) => {
                    e.stopPropagation()
                    void handleCopyForAi(t)
                  }}
                  style={{
                    fontSize: 11,
                    fontFamily: 'inherit',
                    lineHeight: 1.4,
                    padding: '2px 9px',
                    borderRadius: 999,
                    border: `1px solid ${isCopied ? C.ok : C.border}`,
                    background: isCopied ? 'rgba(26,154,94,0.12)' : C.cardSoft,
                    color: isCopied ? C.ok : C.accent,
                    cursor: isCopying ? 'default' : 'pointer',
                    opacity: isCopying ? 0.6 : 1,
                    flexShrink: 0,
                    whiteSpace: 'nowrap',
                  }}
                >
                  {copyLabel}
                </button>
                <span style={{
                  fontSize: 11,
                  color: st.color,
                  background: 'rgba(127,127,127,0.10)',
                  borderRadius: 999,
                  padding: '1px 8px',
                  flexShrink: 0,
                  whiteSpace: 'nowrap',
                }}
                >
                  {st.label}
                </span>
              </div>
              <div style={{
                fontSize: 13,
                color: C.fg,
                fontWeight: 500,
                minWidth: 0,
                overflowWrap: 'anywhere',
                wordBreak: 'break-word',
              }}
              >
                {t.title}
              </div>
            </div>

            {expanded
              ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8, minWidth: 0 }}>
                  <div style={{
                    fontSize: 12.5,
                    color: C.fg,
                    whiteSpace: 'pre-wrap',
                    lineHeight: 1.65,
                    minWidth: 0,
                    overflowWrap: 'anywhere',
                    wordBreak: 'break-word',
                  }}
                  >
                    {t.body}
                  </div>
                  <div style={{ fontSize: 11, color: C.fgFaint, minWidth: 0, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                    运行环境：{t.env === '' ? '（未采集）' : t.env}
                  </div>
                  {t.contact !== ''
                    ? (
                      <div style={{ fontSize: 11, color: C.fgFaint, minWidth: 0, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                        联系方式：{t.contact}
                      </div>
                    )
                    : null}
                  {t.files.length > 0
                    ? (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, minWidth: 0 }}>
                        {t.files.map((f) => (
                          <a
                            key={f.name}
                            href={`${ROUTE}/file?id=${encodeURIComponent(t.id)}&name=${encodeURIComponent(f.name)}`}
                            style={{
                              fontSize: 11,
                              color: C.accent,
                              border: `1px solid ${C.border}`,
                              background: C.cardSoft,
                              borderRadius: 8,
                              padding: '2px 8px',
                              textDecoration: 'none',
                              maxWidth: '100%',
                              minWidth: 0,
                              overflowWrap: 'anywhere',
                              wordBreak: 'break-word',
                            }}
                          >
                            {f.name} · {formatSize(f.size)}
                          </a>
                        ))}
                      </div>
                    )
                    : null}
                  {t.replies.length > 0
                    ? (
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
                        {t.replies.map((r, i) => (
                          <div
                            key={`${t.id}-${String(i)}`}
                            style={{
                              fontSize: 12,
                              color: C.fgDim,
                              minWidth: 0,
                              overflowWrap: 'anywhere',
                              wordBreak: 'break-word',
                            }}
                          >
                            <span style={{ color: r.author === 'admin' ? C.accent : C.fgFaint }}>
                              {r.author === 'admin' ? '我' : '用户'} · {stamp(r.at)}：
                            </span>
                            {r.text}
                          </div>
                        ))}
                      </div>
                    )
                    : null}
                  <textarea
                    value={reply[t.id] ?? ''}
                    onChange={(e) => { setReply({ ...reply, [t.id]: e.target.value }) }}
                    placeholder="回复内容（留空时仅可切换右侧状态）"
                    rows={2}
                    style={{
                      width: '100%',
                      minWidth: 0,
                      boxSizing: 'border-box',
                      fontSize: 12.5,
                      fontFamily: 'inherit',
                      lineHeight: 1.45,
                      padding: '8px 10px',
                      borderRadius: 9,
                      border: `1px solid ${C.border}`,
                      background: C.cardSoft,
                      color: C.fg,
                      resize: 'vertical',
                    }}
                  />
                  <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    <button
                      type="button"
                      disabled={isCopying}
                      onClick={() => { void handleCopyForAi(t) }}
                      style={{
                        ...btn(false, isCopying),
                        borderColor: isCopied ? C.ok : C.border,
                        color: isCopied ? C.ok : C.accent,
                      }}
                    >
                      {copyLabel}
                    </button>
                    <button
                      type="button"
                      disabled={replyDisabled}
                      onClick={() => {
                        if (replyDisabled) return
                        void act(t.id, async () => {
                          await post('reply', { id: t.id, text: replyText })
                          setReply({ ...reply, [t.id]: '' })
                        })
                      }}
                      style={btn(true, replyDisabled)}
                    >
                      回复
                    </button>
                    {['doing', 'done', 'wontfix', 'open'].map((next) => {
                      const stDisabled = busy === t.id || t.status === next
                      return (
                        <button
                          key={next}
                          type="button"
                          disabled={stDisabled}
                          onClick={() => {
                            if (stDisabled) return
                            void act(t.id, async () => { await post('status', { id: t.id, status: next }) })
                          }}
                          style={btn(false, stDisabled)}
                        >
                          {STATUS[next]?.label ?? next}
                        </button>
                      )
                    })}
                  </div>
                </div>
              )
              : null}
          </div>
        )
      })}
    </div>
  )
}
