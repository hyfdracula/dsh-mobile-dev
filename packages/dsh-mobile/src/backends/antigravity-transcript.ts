/**
 * Antigravity 实时磁盘转录读取器：
 * - 直接按字节偏移增量读取 `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`，
 *   同步桌面端与手机端发出的全部最新消息、思考过程与工具调用轨迹；
 * - 结合只读 SQLite `conversations/<id>.db`（`steps.status === 2`）及 `-wal` 时间戳实时感知
 *   桌面端「正在思考（step_type=15） / 正在执行工具（step_type=132）」状态，无需等待回合结束。
 */
import { closeSync, existsSync, openSync, readSync, statSync } from 'node:fs'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
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
}

const cache = new Map<string, ParsedSessionState>()

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

function parseIsoTime(raw: unknown): number {
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw
  if (typeof raw === 'string' && raw.trim() !== '') {
    const t = Date.parse(raw)
    if (Number.isFinite(t)) return t
  }
  return Date.now()
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
  const ts = parseIsoTime(obj.created_at)
  if (ts > state.lastEventTime) state.lastEventTime = ts

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

  // 若最近 3 分钟无任何写入且已有缓存，则直接判定为空闲，免打开 SQLite
  const ageMs = Date.now() - walMtimeMs
  if (state && state.walCacheState && state.walCacheMtime === walMtimeMs && state.walCacheSize === walSize) {
    // 超过 90 秒仍无新写入则自动降级为空闲，避免僵死 running 态
    if (state.walCacheState.running && ageMs > RECENT_WAL_MS) {
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
      // 防御：若最新步刚提交 USER_INPUT（step_type=14）或刚结束工具步且 25 秒内仍有写入，大概率正处于下一轮思考间隙
      if (!running && ageMs < 25_000 && rows.length > 0) {
        const latestType = Number(rows[0]!.step_type ?? 0)
        const latestStatus = Number(rows[0]!.status ?? 0)
        if (latestType === 14 || (latestType === 132 && latestStatus === 3)) {
          running = true
          phase = 'thinking'
        }
      }
      const res: AntigravityLiveState = { running, phase, walMtimeMs, maxStepIdx }
      if (state) {
        state.walCacheMtime = walMtimeMs
        state.walCacheSize = walSize
        state.walCacheState = res
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
    model: state.model,
    running: live.running,
    phase: live.phase,
    updatedAt: Math.max(state.fileMtimeMs, live.walMtimeMs, state.lastEventTime),
    preview: lastPreviewText(outMessages),
  }
}
