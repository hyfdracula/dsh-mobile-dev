/**
 * Antigravity 实时磁盘转录读取器：
 * - 直接按字节偏移增量读取 `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`，
 *   同步桌面端与手机端发出的全部最新消息、思考过程与工具调用轨迹；
 * - 结合只读 SQLite `conversations/<id>.db`（`steps.status === 2`）及 `-wal` 时间戳实时感知
 *   桌面端「正在思考（step_type=15） / 正在执行工具（step_type=132）」状态，无需等待回合结束。
 */
import { closeSync, existsSync, openSync, readdirSync, readFileSync, readSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import { applyTaskToolCall, cloneTaskSteps, type TaskStep } from '../task-steps.ts'
import type { ChatMessage, ToolTrace } from '../transcript.ts'

const MAX_CACHE_ENTRIES = 24
const MAX_THINKING_CHARS = 4000
const RECENT_WAL_MS = 90_000
const MAX_RECENT_READ_BYTES = 16 * 1024 * 1024

interface SqliteDbLike {
  prepare(sql: string): { all(...args: unknown[]): Array<Record<string, unknown>> }
  close(): void
}

type DatabaseSyncCtor = new (path: string, opts?: { readOnly?: boolean }) => SqliteDbLike

let sqliteCtorLoaded = false
let sqliteCtor: DatabaseSyncCtor | null = null

function getSqliteCtor(): DatabaseSyncCtor | null {
  if (sqliteCtorLoaded) return sqliteCtor
  sqliteCtorLoaded = true
  try {
    const req = createRequire(import.meta.url)
    const mod = req('node:sqlite') as { DatabaseSync?: DatabaseSyncCtor }
    if (typeof mod?.DatabaseSync === 'function') {
      sqliteCtor = mod.DatabaseSync
    }
  } catch {
    sqliteCtor = null
  }
  return sqliteCtor
}

export interface AntigravityLiveState {
  running: boolean
  phase: 'idle' | 'thinking' | 'tool'
  walMtimeMs: number
  maxStepIdx: number
}

export interface AntigravityTranscriptSnapshot {
  messages: ChatMessage[]
  tasks: TaskStep[]
  model: string
  running: boolean
  phase: 'idle' | 'thinking' | 'tool'
  updatedAt: number
  preview: string
}

interface ParsedSessionState {
  filePath: string
  fileSize: number
  fileMtimeMs: number
  byteOffset: number
  leftover: string
  messages: ChatMessage[]
  tasks: TaskStep[]
  activeAssistant: ChatMessage | null
  pendingToolIndices: number[]
  turnStartTime: number
  turnTokensIn: number
  turnTokensOut: number
  model: string
  liveFocus: string
  lastStepType: string
  lastStepStatus: string
  lastStepHasTools: boolean
  lastEventTime: number
  walCacheMtime: number
  walCacheSize: number
  walCacheState: AntigravityLiveState | null
  walCacheFromGrace: boolean
}

const cache = new Map<string, ParsedSessionState>()
const abortedAtMap = new Map<string, number>()

/** 记录会话被用户主动中断的时刻，立即清除运行中缓存，防止中断后残留「正在思考」态。 */
export function markAntigravityAborted(rawId: string): void {
  abortedAtMap.set(rawId, Date.now())
  const st = cache.get(rawId)
  if (st) {
    st.walCacheState = null
    st.walCacheFromGrace = false
  }
}

/** 清除主动中断标记（当用户发起新一轮对话时调用）。 */
export function clearAntigravityAborted(rawId: string): void {
  abortedAtMap.delete(rawId)
}

function baseAntigravityDir(): string {
  return join(homedir(), '.gemini', 'antigravity')
}

export function antigravityTranscriptPath(rawId: string): string {
  return join(baseAntigravityDir(), 'brain', rawId, '.system_generated', 'logs', 'transcript.jsonl')
}

export function antigravityDbPath(rawId: string): string {
  return join(baseAntigravityDir(), 'conversations', `${rawId}.db`)
}

function unquoteArg(val: unknown): string {
  if (typeof val !== 'string') {
    return val === undefined || val === null ? '' : String(val)
  }
  const s = val.trim()
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      const parsed = JSON.parse(s)
      if (typeof parsed === 'string') return parsed
    } catch {
      return s.slice(1, -1)
    }
  }
  return s
}

function formatToolSummary(name: string, rawArgs: unknown): string {
  if (!rawArgs || typeof rawArgs !== 'object') return ''
  const args = rawArgs as Record<string, unknown>
  const summary = unquoteArg(args.toolSummary || args.Description || args.focus || args.query)
  if (summary) return summary.slice(0, 140)

  const pathVal = unquoteArg(args.Path || args.AbsolutePath || args.TargetFile || args.ScriptPath)
  if (pathVal) {
    const base = basename(pathVal.replace(/\\/g, '/'))
    return base || pathVal.slice(-80)
  }

  const cmdVal = unquoteArg(args.CommandLine)
  if (cmdVal) {
    return cmdVal.replace(/\s+/g, ' ').trim().slice(0, 120)
  }

  if (name === 'update_steps' && typeof args.steps === 'string') {
    return '更新执行计划'
  }

  for (const k of Object.keys(args)) {
    const v = unquoteArg(args[k]).replace(/\s+/g, ' ').trim()
    if (v) return `${k}: ${v}`.slice(0, 100)
  }
  return ''
}

function extractUserText(rawContent: string, mediaCount: number): string {
  let body = ''
  const m = /<USER_REQUEST>([\s\S]*?)<\/USER_REQUEST>/i.exec(rawContent)
  if (m) {
    body = m[1].trim()
  } else {
    body = rawContent
      .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/gi, '')
      .replace(/<\/?USER_REQUEST>/gi, '')
      .trim()
  }
  if (mediaCount > 0) {
    const note = mediaCount === 1 ? '[已附带 1 张图片]' : `[已附带 ${String(mediaCount)} 张图片]`
    return body ? `${body}\n${note}` : note
  }
  return body
}

function parseIsoTimeOptional(raw: unknown): number {
  if (typeof raw === 'number' && Number.isFinite(raw) && raw > 946_684_800_000) return raw
  if (typeof raw === 'string' && raw.trim() !== '') {
    const t = Date.parse(raw)
    if (Number.isFinite(t) && t > 946_684_800_000) return t
  }
  return 0
}

function appendThinking(prev: string | undefined, chunk: string): string {
  const clean = chunk.trim()
  if (!clean) return prev ?? ''
  const combined = prev && prev.trim() !== '' ? `${prev.trim()}\n\n${clean}` : clean
  if (combined.length <= MAX_THINKING_CHARS) return combined
  return combined.slice(combined.length - MAX_THINKING_CHARS)
}

function ensureAssistant(state: ParsedSessionState, ts: number): ChatMessage {
  if (!state.activeAssistant) {
    const m: ChatMessage = {
      seq: state.messages.length + 1,
      role: 'assistant',
      text: '',
      thinking: '',
      tools: [],
      time: ts,
    }
    state.messages.push(m)
    state.activeAssistant = m
    state.pendingToolIndices = []
    if (state.turnStartTime === 0) state.turnStartTime = ts
  }
  return state.activeAssistant
}

function finalizeAssistantTools(msg: ChatMessage | null): void {
  if (!msg?.tools) return
  for (const t of msg.tools) {
    if (t.status === 'run') t.status = 'ok'
  }
}

function ingestTranscriptLine(state: ParsedSessionState, rawLine: string): void {
  const line = rawLine.trim()
  if (!line) return
  let obj: Record<string, unknown>
  try {
    const parsed = JSON.parse(line)
    if (!parsed || typeof parsed !== 'object') return
    obj = parsed as Record<string, unknown>
  } catch {
    return
  }

  const type = typeof obj.type === 'string' ? obj.type : ''
  const source = typeof obj.source === 'string' ? obj.source : ''
  const status = typeof obj.status === 'string' ? obj.status : ''
  const parsedTs = parseIsoTimeOptional(obj.created_at)
  if (parsedTs > state.lastEventTime) state.lastEventTime = parsedTs
  const ts = parsedTs > 0 ? parsedTs : (state.lastEventTime || state.fileMtimeMs || Date.now())

  if (type === 'CHECKPOINT' || type === 'SYSTEM_MESSAGE' || source === 'SYSTEM') {
    // 跳过系统注入与上下文压缩检查点，避免污染用户可见对话
    return
  }

  if (type === 'USER_INPUT' || source === 'USER_EXPLICIT' || source === 'USER') {
    finalizeAssistantTools(state.activeAssistant)
    state.activeAssistant = null
    state.pendingToolIndices = []
    state.liveFocus = ''
    state.turnStartTime = ts
    state.turnTokensIn = 0
    state.turnTokensOut = 0

    const rawContent = typeof obj.content === 'string' ? obj.content : ''
    const mediaArr = Array.isArray(obj.media) ? obj.media : []
    const text = extractUserText(rawContent, mediaArr.length)
    state.lastStepType = 'USER_INPUT'
    state.lastStepStatus = status || 'DONE'
    state.lastStepHasTools = false
    if (!text) return

    state.messages.push({
      seq: state.messages.length + 1,
      role: 'user',
      text,
      time: ts,
    })
    return
  }

  if (type === 'PLANNER_RESPONSE') {
    const a = ensureAssistant(state, ts)
    if (typeof obj.model === 'string' && obj.model.trim() !== '') {
      state.model = obj.model.trim()
    }
    const inTok = (typeof obj.input_tokens === 'number' ? obj.input_tokens : 0)
      + (typeof obj.cache_read_tokens === 'number' ? obj.cache_read_tokens : 0)
    const outTok = typeof obj.output_tokens === 'number' ? obj.output_tokens : 0
    if (inTok > state.turnTokensIn) state.turnTokensIn = inTok
    state.turnTokensOut += outTok

    if (typeof obj.thinking === 'string' && obj.thinking.trim() !== '') {
      a.thinking = appendThinking(a.thinking, obj.thinking)
    }

    const toolCalls = Array.isArray(obj.tool_calls) ? obj.tool_calls : []
    state.pendingToolIndices = []
    if (toolCalls.length > 0) {
      if (!a.tools) a.tools = []
      const stepIdx = typeof obj.step_index === 'number' ? obj.step_index : state.messages.length
      for (let i = 0; i < toolCalls.length; i++) {
        const rawTc = toolCalls[i]
        if (!rawTc || typeof rawTc !== 'object') continue
        const tc = rawTc as Record<string, unknown>
        const name = typeof tc.name === 'string' && tc.name.trim() !== '' ? tc.name.trim() : 'tool'
        const summary = formatToolSummary(name, tc.args)
        if (name === 'update_focus' && summary) {
          state.liveFocus = summary
        }
        const taskMut = applyTaskToolCall(state.tasks, name, tc.args)
        if (taskMut.changed) {
          state.tasks = taskMut.tasks
        }
        const trace: ToolTrace = {
          id: `ag-${String(stepIdx)}-${String(i)}`,
          name,
          summary: summary || name,
          status: 'run',
        }
        a.tools.push(trace)
        state.pendingToolIndices.push(a.tools.length - 1)
      }
    }

    const content = typeof obj.content === 'string' ? obj.content : ''
    if (content.trim() !== '') {
      a.text = a.text.trim() !== '' ? `${a.text}\n\n${content}` : content
    }

    state.lastStepType = 'PLANNER_RESPONSE'
    state.lastStepStatus = status || 'DONE'
    state.lastStepHasTools = toolCalls.length > 0

    // 无后续工具调用的 DONE 响应即本轮最终答复
    if (toolCalls.length === 0 && status === 'DONE' && content.trim() !== '') {
      finalizeAssistantTools(a)
      a.turn = {
        status: 'completed',
        ms: state.turnStartTime > 0 ? Math.max(0, ts - state.turnStartTime) : 0,
        tokensIn: state.turnTokensIn,
        tokensOut: state.turnTokensOut,
        atSeq: a.seq,
        finishedAt: ts,
      }
      state.liveFocus = ''
    }
    return
  }

  if (type === 'GENERIC' && source === 'MODEL') {
    state.lastStepType = 'GENERIC'
    state.lastStepStatus = status || 'DONE'
    const a = state.activeAssistant
    if (a?.tools && state.pendingToolIndices.length > 0) {
      const idx = state.pendingToolIndices[0]!
      const trace = a.tools[idx]
      if (trace) {
        if (status === 'RUNNING') {
          trace.status = 'run'
        } else if (status === 'ERROR') {
          trace.status = 'err'
          state.pendingToolIndices.shift()
        } else {
          trace.status = 'ok'
          state.pendingToolIndices.shift()
        }
      }
    }
  }
}

function probeSqliteLiveState(rawId: string, state?: ParsedSessionState): AntigravityLiveState {
  const dbPath = antigravityDbPath(rawId)
  const walPath = `${dbPath}-wal`
  let walMtimeMs = 0
  let walSize = 0
  try {
    if (existsSync(walPath)) {
      const ws = statSync(walPath)
      walMtimeMs = ws.mtimeMs
      walSize = ws.size
    } else if (existsSync(dbPath)) {
      const ds = statSync(dbPath)
      walMtimeMs = ds.mtimeMs
      walSize = ds.size
    } else {
      return { running: false, phase: 'idle', walMtimeMs: 0, maxStepIdx: 0 }
    }
  } catch {
    return { running: false, phase: 'idle', walMtimeMs: 0, maxStepIdx: 0 }
  }

  const now = Date.now()
  const ageMs = now - walMtimeMs
  const abortedAt = abortedAtMap.get(rawId) ?? 0
  if (abortedAt > 0) {
    if (now - abortedAt < 30_000 && walMtimeMs <= abortedAt + 4000) {
      return { running: false, phase: 'idle', walMtimeMs, maxStepIdx: 0 }
    }
    if (walMtimeMs > abortedAt + 4000 || now - abortedAt >= 30_000) {
      abortedAtMap.delete(rawId)
    }
  }

  // 若最近无新写入且已有缓存，则直接复用（注意间隙宽限态超过 8 秒即自动失效，不沿用 90 秒窗口）
  if (state && state.walCacheState && state.walCacheMtime === walMtimeMs && state.walCacheSize === walSize) {
    if (state.walCacheState.running && (ageMs > RECENT_WAL_MS || (state.walCacheFromGrace && ageMs > 8_000))) {
      return { running: false, phase: 'idle', walMtimeMs, maxStepIdx: state.walCacheState.maxStepIdx }
    }
    return state.walCacheState
  }

  if (ageMs > 5 * 60_000) {
    const idle: AntigravityLiveState = { running: false, phase: 'idle', walMtimeMs, maxStepIdx: 0 }
    if (state) {
      state.walCacheMtime = walMtimeMs
      state.walCacheSize = walSize
      state.walCacheState = idle
      state.walCacheFromGrace = false
    }
    return idle
  }

  const DatabaseSync = getSqliteCtor()
  if (DatabaseSync && existsSync(dbPath)) {
    let db: SqliteDbLike | null = null
    try {
      db = new DatabaseSync(dbPath, { readOnly: true })
      const rows = db.prepare('SELECT idx, step_type, status FROM steps ORDER BY idx DESC LIMIT 8').all()
      let running = false
      let phase: 'idle' | 'thinking' | 'tool' = 'idle'
      let maxStepIdx = 0
      let fromGrace = false
      for (const r of rows) {
        const idx = Number(r.idx ?? 0)
        if (idx > maxStepIdx) maxStepIdx = idx
        const st = Number(r.status ?? 0)
        const stepType = Number(r.step_type ?? 0)
        if (st === 2) {
          running = true
          // step_type 15 = PLANNER_RESPONSE（思考/规划），132 = GENERIC（工具执行）
          phase = stepType === 15 ? 'thinking' : 'tool'
          break
        }
      }
      // 防御：若最新步刚提交 USER_INPUT（step_type=14）或刚结束工具步且 8 秒内仍有写入，判定处于思考间隙
      if (!running && ageMs < 8_000 && rows.length > 0) {
        const latestType = Number(rows[0]!.step_type ?? 0)
        const latestStatus = Number(rows[0]!.status ?? 0)
        if (latestType === 14 || (latestType === 132 && latestStatus === 3)) {
          running = true
          phase = 'thinking'
          fromGrace = true
        }
      }
      const res: AntigravityLiveState = { running, phase, walMtimeMs, maxStepIdx }
      if (state) {
        state.walCacheMtime = walMtimeMs
        state.walCacheSize = walSize
        state.walCacheState = res
        state.walCacheFromGrace = fromGrace
      }
      return res
    } catch {
      // 锁冲突或旧版 Node 无 node:sqlite 时回退到时间窗启发式
    } finally {
      try {
        db?.close()
      } catch {
        // ignore
      }
    }
  }

  // 无 SQLite 时的降级启发式
  const heuristicRunning =
    ageMs < RECENT_WAL_MS
    && state !== undefined
    && (
      state.lastStepStatus === 'RUNNING'
      || state.lastStepType === 'USER_INPUT'
      || state.lastStepType === 'GENERIC'
      || (state.lastStepType === 'PLANNER_RESPONSE' && state.lastStepHasTools)
    )
  const fallback: AntigravityLiveState = {
    running: heuristicRunning,
    phase: heuristicRunning
      ? (state?.pendingToolIndices.length ? 'tool' : 'thinking')
      : 'idle',
    walMtimeMs,
    maxStepIdx: 0,
  }
  if (state) {
    state.walCacheMtime = walMtimeMs
    state.walCacheSize = walSize
    state.walCacheState = fallback
    state.walCacheFromGrace = true
  }
  return fallback
}

function touchCache(rawId: string, state: ParsedSessionState): void {
  cache.delete(rawId)
  cache.set(rawId, state)
  while (cache.size > MAX_CACHE_ENTRIES) {
    const oldest = cache.keys().next().value
    if (oldest === undefined) break
    cache.delete(oldest)
  }
}

function readBytes(filePath: string, offset: number, length: number): string {
  if (length <= 0) return ''
  const fd = openSync(filePath, 'r')
  try {
    const buf = Buffer.allocUnsafe(length)
    let totalRead = 0
    while (totalRead < length) {
      const n = readSync(fd, buf, totalRead, length - totalRead, offset + totalRead)
      if (n <= 0) break
      totalRead += n
    }
    return buf.subarray(0, totalRead).toString('utf8')
  } finally {
    closeSync(fd)
  }
}

function lastPreviewText(messages: readonly ChatMessage[]): string {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]!
    const txt = m.text.replace(/\s+/g, ' ').trim()
    if (txt) return txt.slice(0, 120)
  }
  return ''
}

export interface AntigravitySessionMeta {
  rawId: string
  title: string
  preview: string
  updatedAt: number
  workspaceUri: string
  projectId: string
  stepCount: number
  runningHint: boolean
  archived: boolean
  hidden: boolean
  hasAnnotation: boolean
}

interface SessionIndexCache {
  sig: string
  checkedAt: number
  map: Map<string, AntigravitySessionMeta>
}

let sessionIndexCache: SessionIndexCache | null = null

function parseAntigravityIsoTime(raw: unknown): number {
  if (typeof raw !== 'string') return 0
  const s = raw.trim()
  if (!s || s.startsWith('0001-')) return 0
  const norm = s.replace(' ', 'T').replace(/\.(\d{3})\d+/, '.$1')
  const ms = Date.parse(norm)
  return Number.isFinite(ms) && ms > 946_684_800_000 ? ms : 0
}

function parseFirstWorkspaceUri(raw: unknown): string {
  if (typeof raw !== 'string') return ''
  const s = raw.trim()
  if (!s) return ''
  if (s.startsWith('[')) {
    try {
      const arr = JSON.parse(s) as unknown
      if (Array.isArray(arr)) {
        for (const item of arr) {
          if (typeof item === 'string' && item.trim()) return item.trim()
        }
      }
    } catch {
      // ignore malformed workspace_uris
    }
  }
  return s
}

function decodePbtxtString(raw: string): string {
  try {
    return JSON.parse(`"${raw}"`) as string
  } catch {
    return raw
  }
}

/**
 * 读取 Antigravity 桌面端真实的会话元数据索引：
 * - 结合 `annotations/<id>.pbtxt`（`archived:true` 与用户自定义标题）和
 *   `conversation_summaries.db`（真实 `last_modified_time`、`nesting_depth`、`killed`、`preview`、`workspace_uris`）；
 * - 用于准确过滤已在桌面端归档/隐藏的旧会话与子 Agent，并还原每条会话的真实活跃时间。
 */
export function readAntigravitySessionIndex(): Map<string, AntigravitySessionMeta> {
  const root = baseAntigravityDir()
  const sumDbPath = join(root, 'conversation_summaries.db')
  const sumWalPath = `${sumDbPath}-wal`
  const annDir = join(root, 'annotations')

  const statTag = (p: string): string => {
    try {
      const st = statSync(p)
      return `${String(st.mtimeMs)}:${String(st.size)}`
    } catch {
      return '0'
    }
  }

  const now = Date.now()
  const sig = `${statTag(sumDbPath)}|${statTag(sumWalPath)}|${statTag(annDir)}`
  if (sessionIndexCache && sessionIndexCache.sig === sig && now - sessionIndexCache.checkedAt < 1500) {
    return sessionIndexCache.map
  }

  const map = new Map<string, AntigravitySessionMeta>()

  // 1. 扫描 annotations/*.pbtxt 获取精确的归档标记与桌面端自定义标题
  const annMap = new Map<string, { archived: boolean; title: string }>()
  try {
    if (existsSync(annDir)) {
      for (const name of readdirSync(annDir)) {
        if (!name.endsWith('.pbtxt')) continue
        const rawId = name.slice(0, -'.pbtxt'.length)
        if (!rawId) continue
        try {
          const txt = readFileSync(join(annDir, name), 'utf8')
          const archived = /\barchived:\s*true\b/.test(txt)
          const tm = /\btitle:\s*"((?:[^"\\]|\\.)*)"/.exec(txt)
          const title = tm ? decodePbtxtString(tm[1] ?? '').trim() : ''
          annMap.set(rawId, { archived, title })
        } catch {
          // ignore unreadable annotation
        }
      }
    }
  } catch {
    // ignore missing annotations dir
  }

  // 2. 通过内置 node:sqlite 只读查询 conversation_summaries.db
  const SqliteDb = getSqliteCtor()
  if (SqliteDb && existsSync(sumDbPath)) {
    let db: SqliteDbLike | null = null
    try {
      db = new SqliteDb(sumDbPath, { readOnly: true })
      const ftsArchived = new Set<string>()
      try {
        const ftsRows = db
          .prepare('SELECT conversation_id, MAX(archived) AS arch FROM conversations_fts GROUP BY conversation_id')
          .all()
        for (const r of ftsRows) {
          const cid = typeof r.conversation_id === 'string' ? r.conversation_id : ''
          if (cid && Number(r.arch ?? 0) === 1) ftsArchived.add(cid)
        }
      } catch {
        // conversations_fts 可选
      }

      const rows = db
        .prepare(
          'SELECT conversation_id, title, preview, last_modified_time, status, project_id, nesting_depth, parent_conversation_id, not_fully_idle, killed, step_count, workspace_uris FROM conversation_summaries',
        )
        .all()
      for (const r of rows) {
        const rawId = typeof r.conversation_id === 'string' ? r.conversation_id.trim() : ''
        if (!rawId) continue
        const ann = annMap.get(rawId)
        const hasAnnotation = ann !== undefined
        const sumTitle = typeof r.title === 'string' ? r.title.trim() : ''
        const title = ann?.title || sumTitle
        const preview = typeof r.preview === 'string' ? r.preview.replace(/\s+/g, ' ').trim().slice(0, 120) : ''
        const updatedAt = parseAntigravityIsoTime(r.last_modified_time)
        const workspaceUri = parseFirstWorkspaceUri(r.workspace_uris)
        const projectId = typeof r.project_id === 'string' ? r.project_id.trim() : ''
        const nestingDepth = Number(r.nesting_depth ?? 0)
        const parentId = typeof r.parent_conversation_id === 'string' ? r.parent_conversation_id.trim() : ''
        const killed = Number(r.killed ?? 0) !== 0
        const stepCount = Number(r.step_count ?? 0)
        const statusStr = typeof r.status === 'string' ? r.status : ''
        const runningHint = statusStr === 'CASCADE_RUN_STATUS_RUNNING' || Number(r.not_fully_idle ?? 0) !== 0
        const archived = ann?.archived === true || ftsArchived.has(rawId)
        const isSubagent = nestingDepth > 0 || parentId !== ''
        const isOrphanStub = (stepCount <= 0 && !title) || (!title && !projectId && !hasAnnotation)
        const hidden = archived || isSubagent || killed || isOrphanStub

        map.set(rawId, {
          rawId,
          title,
          preview,
          updatedAt,
          workspaceUri,
          projectId,
          stepCount,
          runningHint,
          archived,
          hidden,
          hasAnnotation,
        })
      }
    } catch {
      // SQLite 只读失败时退回 annotations-only 兜底
    } finally {
      try {
        db?.close()
      } catch {
        // ignore
      }
    }
  }

  // 3. 补齐仅存在于 annotations/*.pbtxt 的条目（例如 SQLite 不可用时的兜底）
  for (const [rawId, ann] of annMap.entries()) {
    if (map.has(rawId)) continue
    map.set(rawId, {
      rawId,
      title: ann.title,
      preview: '',
      updatedAt: 0,
      workspaceUri: '',
      projectId: '',
      stepCount: 0,
      runningHint: false,
      archived: ann.archived,
      hidden: ann.archived,
      hasAnnotation: true,
    })
  }

  sessionIndexCache = { sig, checkedAt: now, map }
  return map
}

/** 轻量探测某个 Antigravity 会话是否正在桌面端运行（用于会话列表绿点与排序）。 */
export function probeAntigravityDiskActivity(rawId: string): {
  exists: boolean
  running: boolean
  updatedAt: number
  model: string
  preview: string
} {
  const trPath = antigravityTranscriptPath(rawId)
  const cached = cache.get(rawId)
  const live = probeSqliteLiveState(rawId, cached)
  let trMtime = 0
  let trExists = false
  try {
    if (existsSync(trPath)) {
      trMtime = statSync(trPath).mtimeMs
      trExists = true
    }
  } catch {
    trExists = false
  }
  const updatedAt = Math.max(trMtime, live.walMtimeMs, cached?.lastEventTime ?? 0)
  return {
    exists: trExists || live.walMtimeMs > 0,
    running: live.running,
    updatedAt,
    model: cached?.model ?? '',
    preview: cached ? lastPreviewText(cached.messages) : '',
  }
}

/**
 * 增量读取指定 Antigravity 会话的最新消息、思考链、工具轨迹与实时运行状态。
 * 若该会话没有桌面端 `transcript.jsonl` 文件则返回 `null`（交由 ACP 内存缓存兜底）。
 */
export function readAntigravityTranscript(rawId: string): AntigravityTranscriptSnapshot | null {
  const filePath = antigravityTranscriptPath(rawId)
  let st: ReturnType<typeof statSync>
  try {
    st = statSync(filePath)
    if (!st.isFile()) return null
  } catch {
    return null
  }

  let state = cache.get(rawId)
  if (!state || state.filePath !== filePath || st.size < state.byteOffset) {
    state = {
      filePath,
      fileSize: 0,
      fileMtimeMs: 0,
      byteOffset: 0,
      leftover: '',
      messages: [],
      tasks: [],
      activeAssistant: null,
      pendingToolIndices: [],
      turnStartTime: 0,
      turnTokensIn: 0,
      turnTokensOut: 0,
      model: '',
      liveFocus: '',
      lastStepType: '',
      lastStepStatus: '',
      lastStepHasTools: false,
      lastEventTime: 0,
      walCacheMtime: 0,
      walCacheSize: 0,
      walCacheState: null,
      walCacheFromGrace: false,
    }
  }

  if (st.size > state.byteOffset) {
    // 极大文件首次读取时只取末尾 16MB 防止内存抖动
    if (state.byteOffset === 0 && st.size > MAX_RECENT_READ_BYTES) {
      state.byteOffset = st.size - MAX_RECENT_READ_BYTES
    }
    const delta = readBytes(filePath, state.byteOffset, st.size - state.byteOffset)
    state.byteOffset = st.size
    state.fileSize = st.size
    state.fileMtimeMs = st.mtimeMs

    const combined = state.leftover + delta
    const lines = combined.split('\n')
    state.leftover = lines.pop() ?? ''
    for (const line of lines) {
      ingestTranscriptLine(state, line)
    }
  }

  touchCache(rawId, state)

  const live = probeSqliteLiveState(rawId, state)
  const outMessages: ChatMessage[] = state.messages.map((m) => ({
    ...m,
    tools: m.tools ? m.tools.map((t) => ({ ...t })) : undefined,
  }))

  if (!live.running) {
    // 非运行态：确保所有历史轨迹中不再残留蓝色运行中转圈
    for (const m of outMessages) {
      if (m.tools) {
        for (const t of m.tools) {
          if (t.status === 'run') t.status = 'ok'
        }
      }
    }
  } else {
    // 实时运行态：若当前正在思考或工具执行中但末尾仍是用户消息，补出一条占位助手轨迹气泡
    const tail = outMessages[outMessages.length - 1]
    if (!tail || tail.role === 'user') {
      const placeholder: ChatMessage = {
        seq: outMessages.length + 1,
        role: 'assistant',
        text: '',
        thinking: state.liveFocus ? `${state.liveFocus}…` : '正在思考分析当前上下文…',
        tools: [],
        time: Date.now(),
      }
      outMessages.push(placeholder)
    } else if (tail.role === 'assistant') {
      // 运行中不展示“已完成”角标
      if (tail.turn !== undefined) {
        delete tail.turn
      }
      const hasRunningTool = tail.tools?.some((t) => t.status === 'run') === true
      if (live.phase === 'tool' && !hasRunningTool) {
        if (!tail.tools) tail.tools = []
        if (tail.tools.length > 0) {
          tail.tools[tail.tools.length - 1]!.status = 'run'
        } else {
          tail.tools.push({
            id: `ag-live-${String(live.maxStepIdx)}`,
            name: 'tool',
            summary: state.liveFocus || '正在执行工具步骤…',
            status: 'run',
          })
        }
      } else if (live.phase === 'thinking' && (!tail.thinking || tail.thinking.trim() === '')) {
        tail.thinking = state.liveFocus ? `${state.liveFocus}…` : '正在思考分析…'
      }
    }
  }

  return {
    messages: outMessages,
    tasks: cloneTaskSteps(state.tasks),
    model: state.model,
    running: live.running,
    phase: live.phase,
    updatedAt: Math.max(state.fileMtimeMs, live.walMtimeMs, state.lastEventTime),
    preview: lastPreviewText(outMessages),
  }
}
