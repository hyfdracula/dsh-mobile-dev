/**
 * 跨引擎统一任务/步骤清单解析器（DSH / Antigravity / Codex / Claude Code / OpenCode）：
 * 将各引擎异构的 todo/plan/steps 工具调用与事件归一化为统一的 `TaskStep[]` 契约，
 * 供 `GET /api/sessions/:id/messages` 与 SSE `event: update` 实时推送给手机端渲染。
 */

export type TaskStepStatus = 'pending' | 'in_progress' | 'done' | 'failed' | 'skipped'

export interface TaskStep {
  id: string
  title: string
  status: TaskStepStatus
  detail?: string
}

const MAX_STEPS = 80
const MAX_TITLE_CHARS = 220
const MAX_DETAIL_CHARS = 180

/** 归一化各引擎的状态枚举字符串。 */
export function normalizeTaskStatus(raw: unknown): TaskStepStatus {
  if (typeof raw !== 'string') return 'pending'
  const norm = raw.trim().toLowerCase().replace(/[\s-]+/g, '_')
  if (norm === 'done' || norm === 'completed' || norm === 'complete' || norm === 'finished' || norm === 'success' || norm === 'ok') {
    return 'done'
  }
  if (norm === 'in_progress' || norm === 'inprogress' || norm === 'running' || norm === 'active' || norm === 'working' || norm === 'doing') {
    return 'in_progress'
  }
  if (norm === 'failed' || norm === 'error' || norm === 'errored' || norm === 'err') {
    return 'failed'
  }
  if (norm === 'skipped' || norm === 'skip' || norm === 'cancelled' || norm === 'canceled' || norm === 'dropped') {
    return 'skipped'
  }
  return 'pending'
}

/** 宽松解析 JSON 字符串（兼容 Antigravity 转录中可能存在的双重 JSON 编码参数）。 */
export function parseJsonMaybe(raw: unknown, depth = 0): unknown {
  if (typeof raw !== 'string' || depth >= 2) return raw
  const s = raw.trim()
  if (s.length < 2) return raw
  const first = s[0]
  if (first !== '{' && first !== '[' && first !== '"') return raw
  try {
    const parsed = JSON.parse(s) as unknown
    if (typeof parsed === 'string') {
      return parseJsonMaybe(parsed, depth + 1)
    }
    return parsed
  } catch {
    return raw
  }
}

function firstText(...vals: unknown[]): string {
  for (const v of vals) {
    if (typeof v === 'string') {
      const clean = v.replace(/\s+/g, ' ').trim()
      if (clean !== '') return clean
    }
  }
  return ''
}

/** 将异构数组（steps / todos / plan / entries）解析为归一化 `TaskStep[]`。 */
export function parseTaskStepArray(raw: unknown): TaskStep[] {
  const unwrapped = parseJsonMaybe(raw)
  if (!Array.isArray(unwrapped)) return []
  const out: TaskStep[] = []
  for (let i = 0; i < unwrapped.length && out.length < MAX_STEPS; i++) {
    const item = unwrapped[i]
    if (typeof item === 'string') {
      const title = item.replace(/\s+/g, ' ').trim().slice(0, MAX_TITLE_CHARS)
      if (title !== '') {
        out.push({ id: `step-${String(out.length + 1)}`, title, status: 'pending' })
      }
      continue
    }
    if (!item || typeof item !== 'object') continue
    const o = item as Record<string, unknown>
    const rawStatus = typeof o.status === 'string' ? o.status.trim().toLowerCase() : ''
    if (rawStatus === 'deleted' || rawStatus === 'removed') continue
    const title = firstText(o.title, o.content, o.step, o.subject, o.text, o.name, o.task).slice(0, MAX_TITLE_CHARS)
    if (title === '') continue
    const rawId = firstText(o.id, o.taskId, o.task_id)
    const id = rawId || `step-${String(out.length + 1)}`
    const status = normalizeTaskStatus(o.status ?? o.state)
    const detailRaw = firstText(o.detail, o.activeForm, o.description, o.note, o.ownerName)
    const detail = detailRaw !== '' && detailRaw !== title ? detailRaw.slice(0, MAX_DETAIL_CHARS) : undefined
    const step: TaskStep = { id, title, status }
    if (detail !== undefined) step.detail = detail
    out.push(step)
  }
  return out
}

/** 从 Markdown 复选框文本（如 Codex `item.type === 'plan'` 的纯文本计划）中提取步骤清单。 */
export function parseChecklistMarkdown(text: string): TaskStep[] {
  if (!text || text.trim() === '') return []
  const out: TaskStep[] = []
  for (const rawLine of text.split(/\r?\n/)) {
    if (out.length >= MAX_STEPS) break
    const line = rawLine.trim()
    const cb = /^(?:[-*+]|\d+[.)])\s+\[([ xX~!-])\]\s+(.+)$/.exec(line)
    if (cb) {
      const mark = (cb[1] ?? '').toLowerCase()
      const title = (cb[2] ?? '').replace(/\s+/g, ' ').trim().slice(0, MAX_TITLE_CHARS)
      if (!title) continue
      let status: TaskStepStatus = 'pending'
      if (mark === 'x') status = 'done'
      else if (mark === '~') status = 'in_progress'
      else if (mark === '!') status = 'failed'
      else if (mark === '-') status = 'skipped'
      out.push({ id: `step-${String(out.length + 1)}`, title, status })
    }
  }
  return out
}

const REPLACE_LIST_TOOLS = new Set([
  'updatesteps',
  'todowrite',
  'writetodos',
  'updateplan',
  'setplan',
  'planwrite',
  'taskswrite',
  'managetodos',
])

const CREATE_TASK_TOOLS = new Set([
  'taskcreate',
  'createtask',
  'agentteamscreatetask',
])

const UPDATE_TASK_TOOLS = new Set([
  'taskupdate',
  'updatetask',
  'agentteamsupdatetask',
])

function canonicalToolName(rawName: string): string {
  const last = rawName.includes('__') ? rawName.slice(rawName.lastIndexOf('__') + 2) : rawName
  return last.trim().toLowerCase().replace(/[^a-z0-9]/g, '')
}

/** 识别各类步骤/任务工具调用并将其应用到当前任务列表（纯函数，返回新数组）。 */
export function applyTaskToolCall(
  current: readonly TaskStep[],
  rawToolName: string,
  rawArgs: unknown,
): { changed: boolean; tasks: TaskStep[] } {
  const normName = canonicalToolName(rawToolName)
  if (!normName) return { changed: false, tasks: current.slice() }

  if (REPLACE_LIST_TOOLS.has(normName)) {
    const parsed = parseJsonMaybe(rawArgs)
    if (Array.isArray(parsed)) {
      return { changed: true, tasks: parseTaskStepArray(parsed) }
    }
    if (parsed && typeof parsed === 'object') {
      const obj = parsed as Record<string, unknown>
      const candidate = obj.steps ?? obj.todos ?? obj.plan ?? obj.entries ?? obj.tasks ?? obj.items
      if (candidate !== undefined) {
        const unwrapped = parseJsonMaybe(candidate)
        if (Array.isArray(unwrapped)) {
          return { changed: true, tasks: parseTaskStepArray(unwrapped) }
        }
      }
    }
    return { changed: false, tasks: current.slice() }
  }

  if (CREATE_TASK_TOOLS.has(normName)) {
    const parsed = parseJsonMaybe(rawArgs)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { changed: false, tasks: current.slice() }
    }
    const obj = parsed as Record<string, unknown>
    const title = firstText(obj.subject, obj.title, obj.content, obj.name).slice(0, MAX_TITLE_CHARS)
    if (!title) return { changed: false, tasks: current.slice() }
    const next = cloneTaskSteps(current)
    const id = firstText(obj.id, obj.taskId, obj.task_id) || String(next.length + 1)
    const status = normalizeTaskStatus(obj.status)
    const detailRaw = firstText(obj.activeForm, obj.description, obj.detail)
    const detail = detailRaw !== '' && detailRaw !== title ? detailRaw.slice(0, MAX_DETAIL_CHARS) : undefined
    const step: TaskStep = { id, title, status }
    if (detail !== undefined) step.detail = detail
    const idx = next.findIndex((t) => t.id === id)
    if (idx >= 0) {
      next[idx] = step
    } else if (next.length < MAX_STEPS) {
      next.push(step)
    }
    return { changed: true, tasks: next }
  }

  if (UPDATE_TASK_TOOLS.has(normName)) {
    const parsed = parseJsonMaybe(rawArgs)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { changed: false, tasks: current.slice() }
    }
    const obj = parsed as Record<string, unknown>
    const id = firstText(obj.taskId, obj.task_id, obj.id)
    if (!id) return { changed: false, tasks: current.slice() }
    const next = cloneTaskSteps(current)
    let idx = next.findIndex((t) => t.id === id)
    if (idx < 0 && /^\d+$/.test(id)) {
      const numIdx = Number(id) - 1
      if (numIdx >= 0 && numIdx < next.length) idx = numIdx
    }
    const rawStatus = typeof obj.status === 'string' ? obj.status.trim().toLowerCase() : ''
    if (rawStatus === 'deleted' || rawStatus === 'delete' || rawStatus === 'removed') {
      if (idx >= 0) {
        next.splice(idx, 1)
        return { changed: true, tasks: next }
      }
      return { changed: false, tasks: next }
    }
    if (idx < 0) return { changed: false, tasks: next }
    const cur = next[idx]!
    const nextTitle = firstText(obj.subject, obj.title, obj.content).slice(0, MAX_TITLE_CHARS)
    const nextDetail = firstText(obj.activeForm, obj.description, obj.detail).slice(0, MAX_DETAIL_CHARS)
    const updated: TaskStep = {
      id: cur.id,
      title: nextTitle || cur.title,
      status: obj.status !== undefined ? normalizeTaskStatus(obj.status) : cur.status,
    }
    const finalDetail = nextDetail !== '' && nextDetail !== updated.title ? nextDetail : cur.detail
    if (finalDetail !== undefined) updated.detail = finalDetail
    next[idx] = updated
    return { changed: true, tasks: next }
  }

  return { changed: false, tasks: current.slice() }
}

/** 浅拷贝步骤数组，防止缓存态被调用方原地修改。 */
export function cloneTaskSteps(tasks: readonly TaskStep[]): TaskStep[] {
  return tasks.map((t) => {
    const copy: TaskStep = { id: t.id, title: t.title, status: t.status }
    if (t.detail !== undefined && t.detail !== '') copy.detail = t.detail
    return copy
  })
}

/** 生成用于 SSE 变化检测的稳定指纹。 */
export function taskStepsFingerprint(tasks: readonly TaskStep[]): string {
  if (tasks.length === 0) return ''
  return tasks.map((t) => `${t.id}:${t.status}:${t.title}:${t.detail ?? ''}`).join('|')
}
