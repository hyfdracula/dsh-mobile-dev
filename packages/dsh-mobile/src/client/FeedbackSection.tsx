/**
 * DSH 设置对话框中的「用户反馈」管理面板（仅本机持有管理员密钥时注册显示）。
 * 简洁优雅的分层设计：顶部筛选与统计一目了然，列表采用轻分割线排布，
 * 展开后分区呈现工单正文、环境信息、历史回复、状态切换与快捷回复。
 * @module @deepseek-ai/dsh-mobile/client/FeedbackSection
 */
import { useCallback, useEffect, useRef, useState, type ReactElement } from 'react'

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
  warn: '#D97706',
  warnBg: 'rgba(217,119,6,0.12)',
  bad: 'var(--dsw-alias-state-error-primary, #DC3545)',
  badBg: 'rgba(220,53,69,0.10)',
  mono: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace',
}

const ROUTE = '/api/dsh-mobile/panel/feedback'

const STATUS_ORDER = ['open', 'doing', 'done', 'wontfix'] as const

const STATUS: Record<string, { label: string; color: string; bg: string }> = {
  open: { label: '待处理', color: C.accent, bg: C.accentSoft },
  doing: { label: '处理中', color: C.warn, bg: C.warnBg },
  done: { label: '已完成', color: C.ok, bg: C.okBg },
  wontfix: { label: '不处理', color: C.fgFaint, bg: 'rgba(127,127,127,0.12)' },
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

/** 清理历史工单环境字符串中可能残留的编码替换符，统一为干净的间隔点。 */
const sanitizeEnv = (raw: string): string => (
  raw.replace(/\s*\uFFFD+\s*/g, ' · ').replace(/\s{2,}/g, ' ').trim()
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
  const envClean = sanitizeEnv(t.env)
  const lines: string[] = [
    `# Agent Mobile 用户反馈工单 (${t.id})`,
    '',
    '## 工单元数据',
    `- 工单编号: ${t.id}`,
    `- 反馈分类: ${kindLabel} (${t.kind})`,
    `- 当前状态: ${statusLabel} (${t.status})`,
    `- 提交时间: ${formatIso(t.created_at)}`,
    `- 最后更新: ${formatIso(t.updated_at)}`,
    `- 运行环境: ${envClean !== '' ? envClean : '（未采集）'}`,
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

export function FeedbackSection(): ReactElement | null {
  const [state, setState] = useState<State | null>(null)
  const [seen, setSeen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [reply, setReply] = useState<Record<string, string>>({})
  const [open, setOpen] = useState('')
  const [filter, setFilter] = useState<string>('all')
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
        setError('复制到剪贴板失败，请检查系统剪贴板权限。')
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
  const countMap: Record<string, number> = {}
  for (const t of tickets) {
    countMap[t.status] = (countMap[t.status] ?? 0) + 1
  }
  const filteredTickets = filter === 'all' ? tickets : tickets.filter((t) => t.status === filter)

  const filterTabs: { id: string; label: string; count: number }[] = [
    { id: 'all', label: '全部', count: tickets.length },
    ...STATUS_ORDER
      .filter((st) => (countMap[st] ?? 0) > 0 || filter === st)
      .map((st) => ({ id: st, label: STATUS[st]?.label ?? st, count: countMap[st] ?? 0 })),
  ]

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14, minWidth: 0 }}>
      {/* 顶部简洁筛选栏 */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap', minWidth: 0 }}>
        <div style={{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 4,
          padding: 3,
          borderRadius: 999,
          border: `1px solid ${C.border}`,
          background: C.cardSoft,
          flexWrap: 'wrap',
        }}
        >
          {filterTabs.map((tab) => {
            const active = filter === tab.id
            return (
              <button
                key={tab.id}
                type="button"
                onClick={() => { setFilter(tab.id) }}
                style={{
                  border: 'none',
                  borderRadius: 999,
                  padding: '4px 12px',
                  fontSize: 12,
                  fontWeight: active ? 500 : 400,
                  fontFamily: 'inherit',
                  background: active ? C.accent : 'transparent',
                  color: active ? C.onAccent : C.fgDim,
                  cursor: 'pointer',
                  whiteSpace: 'nowrap',
                }}
              >
                {tab.label} {String(tab.count)}
              </button>
            )
          })}
        </div>

        <button
          type="button"
          disabled={loading}
          onClick={() => { void load() }}
          style={{
            fontSize: 12.5,
            fontFamily: 'inherit',
            lineHeight: 1.4,
            padding: '6px 13px',
            borderRadius: 10,
            border: `1px solid ${C.border}`,
            background: C.cardSoft,
            color: C.fg,
            cursor: loading ? 'default' : 'pointer',
            opacity: loading ? 0.5 : 1,
            flexShrink: 0,
            whiteSpace: 'nowrap',
          }}
        >
          {loading ? '刷新中...' : '刷新'}
        </button>
      </div>

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

      {/* 反馈列表统一容器：轻分割线排布，点击任意一行展开详情 */}
      <div style={{
        border: `1px solid ${C.border}`,
        background: C.card,
        borderRadius: 16,
        overflow: 'hidden',
        minWidth: 0,
      }}
      >
        {filteredTickets.length === 0
          ? (
            <div style={{ padding: '28px 18px', textAlign: 'center', fontSize: 12.5, color: C.fgFaint }}>
              {tickets.length === 0 ? '暂时还没有收到用户反馈。' : '当前筛选下没有反馈记录。'}
            </div>
          )
          : filteredTickets.map((t, index) => {
            const st = STATUS[t.status] ?? { label: t.status, color: C.fgFaint, bg: 'rgba(127,127,127,0.12)' }
            const expanded = open === t.id
            const replyText = (reply[t.id] ?? '').trim()
            const replyDisabled = busy === t.id || replyText === ''
            const isCopying = copyingId === t.id
            const isCopied = copiedId === t.id
            const copyLabel = isCopying ? '整理中...' : (isCopied ? '已复制' : '复制给 AI')
            const envClean = sanitizeEnv(t.env)

            return (
              <div
                key={t.id}
                style={{
                  borderTop: index > 0 ? `1px solid ${C.divider}` : 'none',
                  padding: '13px 18px',
                  minWidth: 0,
                }}
              >
                {/* 折叠态摘要行：标题居主位，状态与时间轻柔呈现 */}
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
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    gap: 12,
                    cursor: 'pointer',
                    minWidth: 0,
                  }}
                >
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, minWidth: 0 }}>
                      <span style={{
                        width: 7,
                        height: 7,
                        borderRadius: 4,
                        background: st.color,
                        flexShrink: 0,
                      }}
                      />
                      <span style={{
                        fontSize: 13.5,
                        fontWeight: 500,
                        color: C.fg,
                        overflow: 'hidden',
                        textOverflow: 'ellipsis',
                        whiteSpace: expanded ? 'normal' : 'nowrap',
                        overflowWrap: 'anywhere',
                      }}
                      >
                        {t.title}
                      </span>
                    </div>
                    <div style={{
                      display: 'flex',
                      alignItems: 'center',
                      gap: 8,
                      flexWrap: 'wrap',
                      marginTop: 3,
                      paddingLeft: 15,
                      fontSize: 11.5,
                      color: C.fgFaint,
                    }}
                    >
                      <span>{KIND[t.kind] ?? t.kind}</span>
                      <span>·</span>
                      <span>{stamp(t.created_at)}</span>
                      {t.files.length > 0 ? <span>· {String(t.files.length)} 个附件</span> : null}
                      {t.replies.length > 0 ? <span>· {String(t.replies.length)} 条回复</span> : null}
                    </div>
                  </div>

                  <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexShrink: 0 }}>
                    <span style={{
                      fontSize: 11.5,
                      fontWeight: 500,
                      color: st.color,
                      background: st.bg,
                      borderRadius: 999,
                      padding: '2px 9px',
                      whiteSpace: 'nowrap',
                    }}
                    >
                      {st.label}
                    </span>
                    <svg
                      width="14"
                      height="14"
                      viewBox="0 0 16 16"
                      fill="none"
                      aria-hidden="true"
                      style={{
                        color: C.fgFaint,
                        transform: expanded ? 'rotate(90deg)' : 'rotate(0deg)',
                        transition: 'transform .18s ease',
                        flexShrink: 0,
                      }}
                    >
                      <path d="M6 3.5 L10.5 8 L6 12.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
                    </svg>
                  </div>
                </div>

                {/* 展开态详情区 */}
                {expanded
                  ? (
                    <div style={{
                      marginTop: 12,
                      padding: '14px 16px',
                      borderRadius: 12,
                      background: C.cardSoft,
                      display: 'flex',
                      flexDirection: 'column',
                      gap: 12,
                      minWidth: 0,
                    }}
                    >
                      {t.body.trim() !== '' && t.body.trim() !== t.title.trim()
                        ? (
                          <div style={{
                            fontSize: 13,
                            color: C.fg,
                            whiteSpace: 'pre-wrap',
                            lineHeight: 1.65,
                            overflowWrap: 'anywhere',
                            wordBreak: 'break-word',
                          }}
                          >
                            {t.body}
                          </div>
                        )
                        : null}

                      {/* 环境、联系方式与编号信息条 */}
                      <div style={{
                        display: 'flex',
                        flexDirection: 'column',
                        gap: 4,
                        fontSize: 11.5,
                        color: C.fgFaint,
                        lineHeight: 1.5,
                      }}
                      >
                        <div>编号：<span style={{ fontFamily: C.mono }}>{t.id}</span></div>
                        {envClean !== '' ? <div style={{ overflowWrap: 'anywhere' }}>环境：{envClean}</div> : null}
                        {t.contact !== '' ? <div style={{ overflowWrap: 'anywhere' }}>联系：{t.contact}</div> : null}
                      </div>

                      {t.files.length > 0
                        ? (
                          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, minWidth: 0 }}>
                            {t.files.map((f) => (
                              <a
                                key={f.name}
                                href={`${ROUTE}/file?id=${encodeURIComponent(t.id)}&name=${encodeURIComponent(f.name)}`}
                                style={{
                                  fontSize: 11.5,
                                  color: C.accent,
                                  border: `1px solid ${C.border}`,
                                  background: C.card,
                                  borderRadius: 8,
                                  padding: '3px 9px',
                                  textDecoration: 'none',
                                  maxWidth: '100%',
                                  overflowWrap: 'anywhere',
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
                          <div style={{
                            display: 'flex',
                            flexDirection: 'column',
                            gap: 6,
                            borderLeft: `2px solid ${C.border}`,
                            paddingLeft: 10,
                          }}
                          >
                            {t.replies.map((r, i) => (
                              <div
                                key={`${t.id}-${String(i)}`}
                                style={{
                                  fontSize: 12,
                                  color: C.fgDim,
                                  lineHeight: 1.5,
                                  overflowWrap: 'anywhere',
                                }}
                              >
                                <span style={{ color: r.author === 'admin' ? C.accent : C.fgFaint, fontWeight: 500 }}>
                                  {r.author === 'admin' ? '我' : '用户'} · {stamp(r.at)}：
                                </span>
                                {r.text}
                              </div>
                            ))}
                          </div>
                        )
                        : null}

                      <div style={{ height: 1, background: C.divider }} />

                      {/* 状态分段选择 */}
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
                        <span style={{ fontSize: 12, color: C.fgDim }}>工单状态</span>
                        <div style={{
                          display: 'inline-flex',
                          border: `1px solid ${C.border}`,
                          background: C.card,
                          borderRadius: 999,
                          padding: 2,
                          gap: 2,
                          flexWrap: 'wrap',
                        }}
                        >
                          {STATUS_ORDER.map((next) => {
                            const active = t.status === next
                            const stDisabled = busy === t.id || active
                            return (
                              <button
                                key={next}
                                type="button"
                                disabled={stDisabled}
                                onClick={() => {
                                  if (stDisabled) return
                                  void act(t.id, async () => { await post('status', { id: t.id, status: next }) })
                                }}
                                style={{
                                  border: 'none',
                                  borderRadius: 999,
                                  padding: '3px 11px',
                                  fontSize: 11.5,
                                  fontWeight: active ? 500 : 400,
                                  fontFamily: 'inherit',
                                  background: active ? C.accent : 'transparent',
                                  color: active ? C.onAccent : C.fgDim,
                                  cursor: stDisabled ? 'default' : 'pointer',
                                  opacity: busy === t.id && !active ? 0.5 : 1,
                                  whiteSpace: 'nowrap',
                                }}
                              >
                                {STATUS[next]?.label ?? next}
                              </button>
                            )
                          })}
                        </div>
                      </div>

                      {/* 回复输入与底部操作栏 */}
                      <textarea
                        value={reply[t.id] ?? ''}
                        onChange={(e) => { setReply({ ...reply, [t.id]: e.target.value }) }}
                        placeholder="写一条回复给用户..."
                        rows={2}
                        style={{
                          width: '100%',
                          minWidth: 0,
                          boxSizing: 'border-box',
                          fontSize: 12.5,
                          fontFamily: 'inherit',
                          lineHeight: 1.5,
                          padding: '8px 11px',
                          borderRadius: 10,
                          border: `1px solid ${C.border}`,
                          background: C.card,
                          color: C.fg,
                          resize: 'vertical',
                        }}
                      />

                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
                        <button
                          type="button"
                          disabled={isCopying}
                          onClick={() => { void handleCopyForAi(t) }}
                          style={{
                            fontSize: 12,
                            fontFamily: 'inherit',
                            lineHeight: 1.4,
                            padding: '6px 12px',
                            borderRadius: 10,
                            border: `1px solid ${isCopied ? C.ok : C.border}`,
                            background: isCopied ? C.okBg : C.card,
                            color: isCopied ? C.ok : C.fgDim,
                            cursor: isCopying ? 'default' : 'pointer',
                            opacity: isCopying ? 0.6 : 1,
                            whiteSpace: 'nowrap',
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
                          style={{
                            fontSize: 12.5,
                            fontWeight: 500,
                            fontFamily: 'inherit',
                            lineHeight: 1.4,
                            padding: '6px 16px',
                            borderRadius: 10,
                            border: 'none',
                            background: C.accent,
                            color: C.onAccent,
                            cursor: replyDisabled ? 'default' : 'pointer',
                            opacity: replyDisabled ? 0.45 : 1,
                            whiteSpace: 'nowrap',
                          }}
                        >
                          {busy === t.id ? '发送中...' : '发送回复'}
                        </button>
                      </div>
                    </div>
                  )
                  : null}
              </div>
            )
          })}
      </div>
    </div>
  )
}
