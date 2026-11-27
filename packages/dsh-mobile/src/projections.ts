/**
 * 会话投影、模型目录、预设列表、定时任务归一与有界 deepContext 缓存。
 */
import { record } from './state.ts'

export interface ContextUsage {
  used: number
  window: number
}

export interface TokenUsage {
  uncachedInputTokens: number
  outputTokens: number
  cacheReadTokens: number
  cacheWriteTokens: number
}

export interface ModelRef {
  provider: string
  model: string
  reasoningEffort: string
}

export interface SessionStats {
  turns: number
  steps: number
  toolCalls: number
  tokens: TokenUsage
}

export interface AgentRef {
  id: string
  label: string
  mode: string
  createdAt: number
}

export interface TeamTask {
  id: string
  subject: string
  status: string
  owner: string
}

export interface AgentSummary {
  enabled: boolean
  tasks: TeamTask[]
  subagents: AgentRef[]
}

export interface PlanState {
  active: boolean
  pending: boolean
}

export interface SessionRow {
  id: string
  title: string
  updatedAt: number
  cwd: string
  running: boolean
  asking: boolean
  archived: boolean
  pinned: boolean
  tokens: TokenUsage
  context: ContextUsage | null
  model: ModelRef | null
  agents: AgentSummary
  plan?: PlanState
  backend?: string
  lastTurnId?: string
  lastTurnStatus?: string
  lastDoneAt?: number
}

export interface AskOption {
  label: string
  description?: string
}

export interface AskQuestion {
  id: string
  prompt?: string
  header?: string
  detail?: string
  options?: AskOption[]
  multiSelect?: boolean
}

export interface PendingAsk {
  callId: string
  questions: AskQuestion[]
  state: string
  synthetic?: boolean
}

export interface AskAnswerItem {
  id: string
  selected: string[]
  custom?: string
}

export interface AskState {
  active: PendingAsk[]
  settled: Array<Record<string, unknown>>
}

export interface CatalogModel {
  id: string
  name: string
  description: string
  efforts: Array<{ id: string; name: string }>
  defaultEffort: string
}

export interface CatalogGroup {
  id: string
  name: string
  models: CatalogModel[]
}

/** 提取子智能体列表与团队任务板快照。 */
export function agentsOf(values: Record<string, unknown> | undefined): AgentSummary {
  const catalog = (values?.subagentCatalog ?? []) as Array<Record<string, unknown>>
  const subagents: AgentRef[] = (Array.isArray(catalog) ? catalog : []).map((s) => ({
    id: String(s.id ?? ''),
    label: String(s.label ?? s.description ?? ''),
    mode: String(s.mode ?? ''),
    createdAt: Number(s.createdAt ?? 0) || 0,
  }))
  const team = (values?.agentTeam ?? {}) as Record<string, unknown>
  const rawTasks = (team.tasks ?? []) as Array<Record<string, unknown>>
  const tasks: TeamTask[] = (Array.isArray(rawTasks) ? rawTasks : []).map((t) => ({
    id: String(t.id ?? ''),
    subject: String(t.subject ?? t.title ?? ''),
    status: String(t.status ?? ''),
    owner: String(t.ownerName ?? t.ownerId ?? ''),
  }))
  return { enabled: team.enabled === true, tasks, subagents }
}

/** 归一化宿主提问列表。 */
export function normalizeQuestions(raw: unknown): AskQuestion[] {
  const list = Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
  return list.map((q, idx) => {
    const optsRaw = Array.isArray(q.options) ? (q.options as Array<Record<string, unknown>>) : []
    const options: AskOption[] = optsRaw
      .map((o) => ({
        label: String(o.label ?? ''),
        description: o.description === undefined ? '' : String(o.description),
      }))
      .filter((o) => o.label !== '')
    const rawId = String(q.id ?? '').trim()
    const id = rawId !== '' ? rawId : `q_${String(idx + 1)}`
    const one: AskQuestion = {
      id,
      prompt: String(q.question ?? q.prompt ?? ''),
      options,
      multiSelect: q.multiSelect === true,
    }
    if (typeof q.header === 'string' && q.header !== '') one.header = q.header
    if (typeof q.detail === 'string' && q.detail !== '') one.detail = q.detail
    return one
  })
}

/** 归一化手机端提交的回答列表。 */
export function normalizeAskAnswers(raw: unknown): AskAnswerItem[] {
  const list = Array.isArray(raw) ? (raw as Array<Record<string, unknown>>) : []
  const answers: AskAnswerItem[] = []
  for (const item of list) {
    const id = String(item?.id ?? '')
    if (id === '') continue
    const selectedRaw = Array.isArray(item?.selected) ? (item.selected as unknown[]) : []
    const selected = selectedRaw.map((value) => String(value)).filter((value) => value !== '')
    const one: AskAnswerItem = { id, selected }
    if (typeof item?.custom === 'string' && item.custom !== '') one.custom = item.custom
    answers.push(one)
  }
  return answers
}

/** 提取上下文窗口占用投影。 */
export function contextOf(values: Record<string, unknown> | undefined): ContextUsage | null {
  const raw = (values?.contextPressure ?? {}) as Record<string, unknown>
  const used = Number(raw.projectedTokens ?? raw.pressureTokens)
  const window = Number(raw.contextWindow)
  if (!Number.isFinite(used) || used <= 0) return null
  if (!Number.isFinite(window) || window <= 0) return null
  return { used: Math.trunc(used), window: Math.trunc(window) }
}

/** 提取投影中的挂起与已完成提问。 */
export function asksOf(values: Record<string, unknown> | undefined): AskState {
  const raw = (values?.userQuestions ?? {}) as Record<string, unknown>
  const activeRaw = Array.isArray(raw.active) ? (raw.active as Array<Record<string, unknown>>) : []
  const settledRaw = Array.isArray(raw.settled) ? (raw.settled as Array<Record<string, unknown>>) : []
  const active: PendingAsk[] = []
  for (const entry of activeRaw) {
    const callId = String(entry.callId ?? '')
    const list = Array.isArray(entry.questions) ? (entry.questions as Array<Record<string, unknown>>) : []
    if (callId === '' || list.length === 0) continue
    const questions = normalizeQuestions(list)
    active.push({ callId, questions, state: String(entry.state ?? 'open'), synthetic: false })
  }
  return { active, settled: settledRaw }
}

/** 提取累计 Token 统计。 */
export function tokensOf(values: Record<string, unknown> | undefined): TokenUsage {
  const raw = (values?.tokenUsage ?? {}) as Record<string, unknown>
  const num = (v: unknown): number => {
    const n = Number(v ?? 0)
    return Number.isFinite(n) && n > 0 ? n : 0
  }
  return {
    uncachedInputTokens: num(raw.uncachedInputTokens),
    outputTokens: num(raw.outputTokens),
    cacheReadTokens: num(raw.cacheReadTokens),
    cacheWriteTokens: num(raw.cacheWriteTokens),
  }
}

/** 提取会话计划模式状态投影。 */
export function planOf(values: Record<string, unknown> | undefined): PlanState {
  const raw = (values?.plan ?? {}) as Record<string, unknown>
  return {
    active: raw.active === true,
    pending: raw.pending === true,
  }
}

/** 提取会话当前选中的模型引用。 */
export function modelOf(values: Record<string, unknown> | undefined): ModelRef | null {
  const selection = (values?.modelSelection ?? {}) as Record<string, unknown>
  const next = (selection.next ?? selection.lastUsed ?? null) as Record<string, unknown> | null
  if (next === null || typeof next !== 'object') return null
  const provider = String(next.provider ?? '')
  const model = String(next.model ?? '')
  if (provider === '' || model === '') return null
  return { provider, model, reasoningEffort: String(next.reasoningEffort ?? '') }
}

/** 从 `ctl.list` 返回结构中取出数组主体。 */
export function rowsOf(payload: unknown): unknown[] {
  if (Array.isArray(payload)) return payload
  if (payload !== null && typeof payload === 'object') {
    const items = (payload as { items?: unknown }).items
    if (Array.isArray(items)) return items
  }
  return []
}

/** 将宿主会话列表投影为手机端统一行结构（过滤空白与子智能体壳会话）。 */
export function projectSessions(payload: unknown, liveAsking?: ReadonlySet<string>): SessionRow[] {
  const rows: SessionRow[] = []
  for (const item of rowsOf(payload)) {
    if (item === null || typeof item !== 'object') continue
    const s = item as Record<string, unknown>
    if (s.__blank === true) continue
    if (s.origin !== undefined && s.origin !== null && String(s.origin) === 'subagent') continue
    const id = String(s.sessionId ?? s.id ?? '')
    if (id.length === 0) continue
    const projections = s.projections as { values?: Record<string, unknown> } | undefined
    const projectedValues = projections?.values as Record<string, unknown> | undefined
    const projectedTitle = projectedValues?.title
    const title =
      typeof projectedTitle === 'string' && projectedTitle.length > 0
        ? projectedTitle
        : typeof s.title === 'string' && s.title.length > 0
          ? s.title
          : '(untitled)'
    const updated = Number(s.updatedAt ?? 0)
    rows.push({
      id,
      title,
      updatedAt: Number.isFinite(updated) ? updated : 0,
      cwd: String(s.cwd ?? ''),
      running: s.running === true,
      asking: (liveAsking?.has(id) ?? false) || asksOf(projectedValues).active.length > 0,
      archived: false,
      pinned: projectedValues?.pinned === true,
      tokens: tokensOf(projectedValues),
      context: contextOf(projectedValues),
      model: modelOf(projectedValues),
      agents: agentsOf(projectedValues),
      plan: planOf(projectedValues),
    })
  }
  rows.sort((a, b) => b.updatedAt - a.updatedAt)
  return rows
}

/** 归一化模型目录结构。 */
export function normalizeCatalog(raw: unknown): {
  current: { provider: string; model: string; reasoningEffort: string } | null
  routable: boolean
  groups: CatalogGroup[]
  failures: Array<{ id: string; name: string; message: string }>
} {
  let value: unknown = raw
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value)
    } catch {
      value = null
    }
  }
  let v = (value ?? {}) as Record<string, unknown>
  if (v.value !== null && typeof v.value === 'object') v = v.value as Record<string, unknown>
  if (v.catalog !== null && typeof v.catalog === 'object') v = v.catalog as Record<string, unknown>

  const currentRaw = v.current as Record<string, unknown> | undefined
  const current =
    currentRaw !== null && typeof currentRaw === 'object'
      ? {
          provider: String(currentRaw.provider ?? ''),
          model: String(currentRaw.model ?? ''),
          reasoningEffort: String(currentRaw.reasoningEffort ?? ''),
        }
      : null

  const groups = ((v.groups ?? []) as Array<Record<string, unknown>>).map((g) => ({
    id: String(g.id ?? ''),
    name: String(g.name ?? g.id ?? ''),
    models: ((g.models ?? []) as Array<Record<string, unknown>>).map((m) => {
      const reasoning = (m.reasoning ?? {}) as Record<string, unknown>
      const efforts = ((reasoning.efforts ?? []) as Array<Record<string, unknown>>).map((e) => ({
        id: String(e.id ?? ''),
        name: String(e.name ?? e.id ?? ''),
      }))
      return {
        id: String(m.id ?? ''),
        name: String(m.name ?? m.id ?? ''),
        description: String(m.description ?? ''),
        efforts,
        defaultEffort: String(reasoning.defaultEffort ?? ''),
      }
    }),
  }))

  const failures = ((v.failures ?? []) as Array<Record<string, unknown>>).map((f) => ({
    id: String(f.id ?? ''),
    name: String(f.name ?? ''),
    message: String(f.message ?? ''),
  }))

  return { current, routable: v.routable !== false, groups, failures }
}

/** 读取当前选中的智能体预设 ID。 */
export function presetCurrent(svc: Record<string, unknown>): string {
  const norm = (raw: unknown): string => {
    if (raw === null || raw === undefined) return ''
    if (typeof raw === 'function') return ''
    if (typeof raw === 'string') return raw
    if (typeof raw === 'number') return String(raw)
    if (typeof raw === 'object') {
      const o = raw as Record<string, unknown>
      return String(o.id ?? o.name ?? '')
    }
    return ''
  }
  try {
    const v = norm(svc.current ?? svc.selected)
    if (v !== '') return v
  } catch {
    // fall through
  }
  try {
    const v = norm(svc.defaultId)
    if (v !== '') return v
  } catch {
    // fall through
  }
  try {
    const cfg = svc.config as Record<string, unknown> | undefined
    if (cfg !== undefined && cfg !== null) {
      const raw = cfg.selectedDefault
      const v = norm(
        typeof (raw as { get?: () => unknown })?.get === 'function'
          ? (raw as { get: () => unknown }).get()
          : raw,
      )
      if (v !== '') return v
      const d = norm(cfg.default)
      if (d !== '') return d
    }
  } catch {
    // fall through
  }
  return ''
}

/** 归一化智能体预设列表。 */
export function presetRows(raw: unknown, currentId: string): Record<string, unknown>[] {
  let list: unknown[] = []
  if (Array.isArray(raw)) {
    list = raw
  } else if (raw !== null && typeof raw === 'object') {
    const o = raw as Record<string, unknown>
    if (Array.isArray(o.presets)) list = o.presets as unknown[]
    else if (Array.isArray(o.items)) list = o.items as unknown[]
  }
  const out: Record<string, unknown>[] = []
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue
    const r = item as Record<string, unknown>
    const id = String(r.id ?? '')
    const name = String(r.name ?? '')
    if (id === '' && name === '') continue
    out.push({
      id,
      name: name === '' ? id : name,
      description: String(r.description ?? ''),
      isDefault: r.isDefault === undefined ? (currentId !== '' && id === currentId) : r.isDefault === true,
      broken: r.broken === undefined || r.broken === null ? '' : String(r.broken),
    })
  }
  return out
}

/** 归一化宿主定时任务记录。 */
export function normalizeScheduleTask(raw: unknown): Record<string, unknown> {
  const bag = (raw !== null && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  const inner = (bag.record !== null && typeof bag.record === 'object' ? bag.record : bag) as Record<string, unknown>
  const target = (inner.target !== null && typeof inner.target === 'object' ? inner.target : {}) as Record<string, unknown>
  const status = String(inner.status ?? '')
  return {
    id: String(inner.id ?? bag.id ?? ''),
    title: String(inner.title ?? inner.name ?? '未命名任务'),
    kind: String(inner.kind ?? inner.type ?? ''),
    when: String(inner.nextRunAt ?? inner.nextAt ?? inner.next ?? inner.scheduledAt ?? inner.when ?? ''),
    active: inner.active === true || status === 'active' || status === 'scheduled',
    status,
    sessionId: String(target.sessionId ?? inner.sessionId ?? ''),
  }
}

const DEEP_CACHE_CAP = 128
const DEEP_TTL_MS = 15_000

/**
 * 有界化（LRU 128）的会话深层投影缓存，用于读取 `ctl.list()` 摘要中不含的 `contextPressure`。
 */
export function createDeepContextReader(
  service: (name: string) => any,
  logFile: string,
): (sessionId: string) => ContextUsage | null {
  const deepCache = new Map<string, { at: number; value: ContextUsage | null }>()

  return (sessionId: string): ContextUsage | null => {
    const now = Date.now()
    const hit = deepCache.get(sessionId)
    if (hit !== undefined && now - hit.at < DEEP_TTL_MS) {
      deepCache.delete(sessionId)
      deepCache.set(sessionId, hit)
      return hit.value
    }
    let value: ContextUsage | null = null
    try {
      const registry = service('sessionProjections')
      const sessions = service('sessions')
      const live: any = sessions !== null && typeof sessions.get === 'function'
        ? sessions.get(sessionId)
        : undefined
      if (registry !== null && live !== undefined && typeof registry.snapshot === 'function') {
        const snap: any = registry.snapshot(live)
        value = contextOf((snap?.values ?? {}) as Record<string, unknown>)
      }
    } catch (error) {
      void record(logFile, `deep context failed: ${String(error)}`)
    }
    deepCache.delete(sessionId)
    deepCache.set(sessionId, { at: now, value })
    while (deepCache.size > DEEP_CACHE_CAP) {
      const oldest = deepCache.keys().next().value
      if (oldest === undefined) break
      deepCache.delete(oldest)
    }
    return value
  }
}

/** 读取宿主归档与置顶标记并附加到会话列表。 */
export function createWorkspaceFlags(service: (name: string) => any): {
  archivedIds: () => string[] | null
  pinnedIds: () => string[] | null
  markArchived: (rows: SessionRow[]) => SessionRow[]
  markPinned: (rows: SessionRow[]) => SessionRow[]
} {
  const readIdSet = (field: 'archivedSessionIds' | 'pinnedSessionIds'): string[] | null => {
    const reg = service('workspaceRegistry')
    if (reg === null) return null
    try {
      const raw = reg[field]
      if (Array.isArray(raw)) return raw.map((x: unknown) => String(x)).filter(Boolean)
      if (raw && typeof raw.has === 'function' && typeof raw.size === 'number') {
        return Array.from(raw as Iterable<unknown>, (x) => String(x)).filter(Boolean)
      }
      return null
    } catch {
      return null
    }
  }

  const archivedIds = (): string[] | null => readIdSet('archivedSessionIds')
  const pinnedIds = (): string[] | null => readIdSet('pinnedSessionIds')

  const markArchived = (rows: SessionRow[]): SessionRow[] => {
    const set = archivedIds()
    if (set === null) return rows
    const lookup = new Set(set)
    return rows.map((row) => ({ ...row, archived: lookup.has(row.id) }))
  }

  const markPinned = (rows: SessionRow[]): SessionRow[] => {
    const set = pinnedIds()
    if (set === null) return rows
    const lookup = new Set(set)
    return rows.map((row) => ({ ...row, pinned: lookup.has(row.id) }))
  }

  return { archivedIds, pinnedIds, markArchived, markPinned }
}
