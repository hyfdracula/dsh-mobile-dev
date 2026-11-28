/**
 * 会话 Zstd 事件日志解析、增量解压 + LRU 缓存（上限 16）、路径索引缓存、
 * 思考链与工具调用轨迹提取、精简模式裁剪以及 AgentTeams 视图复用。
 */
import { createHash } from 'node:crypto'
import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from 'node:fs'
import { join } from 'node:path'
import * as zlib from 'node:zlib'
import type { SessionStats, TokenUsage } from './projections.ts'
import { dshHome } from './state.ts'
import {
  applyTaskToolCall,
  cloneTaskSteps,
  normalizeTaskStatus,
  parseTaskStepArray,
  type TaskStep,
} from './task-steps.ts'

export interface ImageRef {
  id: string
  mediaType: string
  width: number
  height: number
  name: string
}

export interface ToolTrace {
  id: string
  name: string
  summary: string
  status: 'ok' | 'err' | 'run'
}

export interface TurnInfo {
  status: string
  ms: number
  tokensIn: number
  tokensOut: number
  atSeq: number
  finishedAt: number
  errCode?: string
  errText?: string
}

export interface TurnErr {
  code: string
  text: string
  time: number
}

export interface ChatMessage {
  role: 'user' | 'assistant'
  text: string
  time: number
  seq: number
  images?: ImageRef[]
  turn?: TurnInfo
  thinking?: string
  tools?: ToolTrace[]
}

export interface TeamSnapshot {
  enabled: boolean
  sawMode: boolean
  members: Array<Record<string, unknown>>
  tasks: Array<Record<string, unknown>>
}

export const zstdDecompressSync: ((buffer: Buffer) => Buffer) | undefined = (
  zlib as unknown as { zstdDecompressSync?: (buffer: Buffer) => Buffer }
).zstdDecompressSync

const ZSTD_MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const MAX_SESSION_BYTES = 160 * 1024 * 1024
const HISTORY_CACHE_CAP = 16
const PATH_CACHE_CAP = 512
const HEAD_HASH_BYTES = 4096
const MAX_THINKING_CHARS = 4000
const COMPACT_THINKING_CHARS = 160

/** `sessionId -> filePath` 映射缓存（LRU 上限 512），未命中或文件消失时才遍历磁盘目录。 */
const sessionFileCache = new Map<string, { home: string; file: string }>()

/** 定位某个会话的 `session.v4.jsonl.zstd` 文件。 */
export function findSessionFile(id: string): string | null {
  const home = dshHome()
  const hit = sessionFileCache.get(id)
  if (hit !== undefined && hit.home === home) {
    if (existsSync(hit.file)) {
      sessionFileCache.delete(id)
      sessionFileCache.set(id, hit)
      return hit.file
    }
    sessionFileCache.delete(id)
  }

  const root = join(home, 'sessions')
  let projects: string[]
  try {
    projects = readdirSync(root)
  } catch {
    return null
  }
  const candidates = id.startsWith('session-') ? [id, id.slice('session-'.length)] : [id, `session-${id}`]
  for (const project of projects) {
    for (const name of candidates) {
      const file = join(root, project, name, 'session.v4.jsonl.zstd')
      try {
        if (statSync(file).isFile()) {
          sessionFileCache.delete(id)
          sessionFileCache.set(id, { home, file })
          while (sessionFileCache.size > PATH_CACHE_CAP) {
            const oldest = sessionFileCache.keys().next().value
            if (oldest === undefined) break
            sessionFileCache.delete(oldest)
          }
          return file
        }
      } catch {
        // 继续尝试下一个候选目录。
      }
    }
  }
  return null
}

/** 读取文件区间字节。 */
function readRange(fd: number, offset: number, length: number): Buffer {
  if (length <= 0) return Buffer.alloc(0)
  const buf = Buffer.allocUnsafe(length)
  let readTotal = 0
  while (readTotal < length) {
    const n = readSync(fd, buf, readTotal, length - readTotal, offset + readTotal)
    if (n <= 0) break
    readTotal += n
  }
  return readTotal === length ? buf : buf.subarray(0, readTotal)
}

/** 计算头部块哈希，判断日志文件是否被截断重写。 */
function hashBuffer(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex').slice(0, 32)
}

/**
 * 解压一段字节中的完整 Zstd 帧序列。
 * 返回成功解码的事件行列表，以及已消费的精确字节偏移 `consumedBytes`：
 * 若末尾帧尚未写完（半帧），`consumedBytes` 停在该半帧起始位置，留待下次增量继续读取。
 */
function decodeZstdFrames(raw: Buffer): { lines: string[]; consumedBytes: number } {
  if (zstdDecompressSync === undefined) throw new Error('this Node build has no zstd support')
  if (raw.length === 0) return { lines: [], consumedBytes: 0 }

  const starts: number[] = []
  let cursor = 0
  while ((cursor = raw.indexOf(ZSTD_MAGIC, cursor)) !== -1) {
    starts.push(cursor)
    cursor += 4
  }
  if (starts.length === 0) {
    return { lines: [], consumedBytes: 0 }
  }

  const parts: Buffer[] = []
  let consumedBytes = 0
  let index = 0
  while (index < starts.length) {
    const from = starts[index] as number
    let decoded: Buffer | null = null
    let nextIndex = index + 1
    // 若压缩载荷内巧合出现 4 字节 ZSTD_MAGIC，向后扩展切分边界重试（Node 解压器在真实帧尾自动停止）。
    while (nextIndex <= starts.length) {
      const to = nextIndex < starts.length ? (starts[nextIndex] as number) : raw.length
      try {
        decoded = zstdDecompressSync(raw.subarray(from, to))
        break
      } catch {
        if (nextIndex === starts.length) break
        nextIndex += 1
      }
    }
    if (decoded !== null) {
      parts.push(decoded)
      consumedBytes = nextIndex < starts.length ? (starts[nextIndex] as number) : raw.length
      index = nextIndex
    } else {
      // 若为末尾正在写入的残帧，停在 `from` 等下一轮补齐；中间损坏帧则跳过。
      if (index === starts.length - 1) {
        break
      }
      consumedBytes = starts[index + 1] as number
      index += 1
    }
  }

  if (parts.length === 0) return { lines: [], consumedBytes }
  const lines = Buffer.concat(parts)
    .toString('utf8')
    .split('\n')
    .filter((line) => line.length > 0)
  return { lines, consumedBytes }
}

/** 提取正文文本块。 */
export function textOf(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const out: string[] = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as { type?: unknown; text?: unknown }
    if (p.type === 'text' && typeof p.text === 'string') out.push(p.text)
  }
  return out.join('').trim()
}

/** 提取 assistant 内容块中的 `reasoning` / `thinking` 思考链文本。 */
function thinkingOf(content: unknown): string {
  if (!Array.isArray(content)) return ''
  const out: string[] = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as Record<string, unknown>
    if (p.type === 'reasoning' || p.type === 'thinking') {
      const raw = typeof p.text === 'string'
        ? p.text
        : typeof p.thinking === 'string'
          ? p.thinking
          : typeof p.reasoning === 'string'
            ? p.reasoning
            : ''
      const trimmed = raw.trim()
      if (trimmed.length > 0) out.push(trimmed)
    }
  }
  return out.join('\n\n')
}

/** 裁剪思考链文本至最多 4000 字符。 */
function capThinking(raw: string): string {
  if (raw.length <= MAX_THINKING_CHARS) return raw
  return `${raw.slice(0, MAX_THINKING_CHARS - 1)}⋯`
}

/** 从工具调用参数中提炼简明单行目标摘要（绝不混入大段文件内容或结果原文）。 */
export function summarizeToolArgs(name: string, rawArgs: unknown): string {
  let parsed: unknown = rawArgs
  if (typeof rawArgs === 'string') {
    const trimmed = rawArgs.trim()
    if (trimmed === '') return ''
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      return trimmed.split(/\r?\n/)[0]?.replace(/\s+/g, ' ').trim().slice(0, 100) ?? ''
    }
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return ''
  }
  const bag = parsed as Record<string, unknown>
  const firstLine = (v: unknown, max = 100): string => {
    if (typeof v !== 'string') return ''
    const line = v.trim().split(/\r?\n/)[0]?.replace(/\s+/g, ' ').trim() ?? ''
    return line.length > max ? `${line.slice(0, max - 1)}⋯` : line
  }

  const lower = name.toLowerCase()
  if (lower === 'pwsh' || lower === 'bash' || lower === 'shell' || lower.includes('terminal') || lower === 'run_command') {
    const cmd = firstLine(bag.command ?? bag.cmd ?? bag.script ?? bag.CommandLine, 100)
    if (cmd !== '') return cmd
  }
  if (lower === 'grep' || lower === 'glob') {
    const pat = firstLine(bag.pattern, 60)
    const scope = firstLine(bag.path ?? bag.include, 50)
    if (pat !== '') return scope !== '' ? `${pat} · ${scope}` : pat
  }

  const priorityKeys = [
    'file_path',
    'path',
    'filePath',
    'target_file',
    'command',
    'cmd',
    'pattern',
    'query',
    'url',
    'skill',
    'label',
    'subject',
    'objective',
    'task_id',
    'agent_id',
    'job_id',
    'to',
    'name',
    'action',
    'description',
    'prompt',
  ]
  for (const key of priorityKeys) {
    const val = bag[key]
    if (typeof val === 'string' && val.trim() !== '') {
      return firstLine(val, 100)
    }
    if (typeof val === 'number' || typeof val === 'boolean') {
      return `${key}=${String(val)}`
    }
  }
  for (const [k, v] of Object.entries(bag)) {
    if (k === 'content' || k === 'new_string' || k === 'old_string' || k === 'data') continue
    if (typeof v === 'string' && v.trim() !== '') return firstLine(v, 90)
    if (typeof v === 'number' || typeof v === 'boolean') return `${k}=${String(v)}`
  }
  return ''
}

/** 提取 assistant 内容块中内嵌的 tool-call 列表。 */
function embeddedToolsOf(content: unknown): Array<{ id: string; name: string; args: unknown }> {
  if (!Array.isArray(content)) return []
  const out: Array<{ id: string; name: string; args: unknown }> = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as Record<string, unknown>
    if (p.type === 'tool-call' || p.type === 'tool_use') {
      const id = String(p.id ?? p.callId ?? '')
      const name = String(p.name ?? '')
      if (id !== '' && name !== '') {
        out.push({ id, name, args: p.arguments ?? p.input })
      }
    }
  }
  return out
}

/** 提取消息中的图片附件摘要。 */
function imagesOf(content: unknown): ImageRef[] {
  if (!Array.isArray(content)) return []
  const out: ImageRef[] = []
  for (const part of content) {
    if (part === null || typeof part !== 'object') continue
    const p = part as { type?: unknown; attachment?: unknown }
    if (p.type !== 'image') continue
    const a = (p.attachment ?? {}) as Record<string, unknown>
    const raw = String(a.attachmentId ?? '')
    const id = raw.startsWith('sha256:') ? raw.slice('sha256:'.length) : raw
    if (!/^[0-9a-f]{8,128}$/i.test(id)) continue
    const width = Number(a.width ?? 0)
    const height = Number(a.height ?? 0)
    out.push({
      id: id.toLowerCase(),
      mediaType: String(a.mediaType ?? 'image/png'),
      width: Number.isFinite(width) && width > 0 ? width : 0,
      height: Number.isFinite(height) && height > 0 ? height : 0,
      name: String(a.name ?? ''),
    })
  }
  return out
}

/** 累加单次模型调用的 Token 计数。 */
function accumulateTokens(total: TokenUsage, data: unknown): void {
  if (data === null || typeof data !== 'object') return
  const usage = ((data as Record<string, unknown>).usage ?? data) as Record<string, unknown>
  const num = (v: unknown): number => {
    const n = Number(v ?? 0)
    return Number.isFinite(n) && n > 0 ? n : 0
  }
  total.uncachedInputTokens += num(usage.inputTokens ?? usage.uncachedInputTokens)
  total.outputTokens += num(usage.outputTokens)
  total.cacheReadTokens += num(usage.cacheReadTokens ?? usage.cachedInputTokens)
  total.cacheWriteTokens += num(usage.cacheWriteTokens)
}

/** 将 Markdown 文本压平为单行会话预览。 */
export function plainPreview(text: string): string {
  const flat = text
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/^>\s?/gm, '')
    .replace(/^\s*[-*+]\s+/gm, '')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/\|/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  return flat.slice(0, 90)
}

/** 单个会话的流式增量折叠状态（支持任意断点追加更多事件行而结果完全一致）。 */
interface SessionFoldEntry {
  size: number
  mtimeMs: number
  headLen: number
  firstChunkHash: string
  byteOffset: number
  messages: ChatMessage[]
  stats: SessionStats
  lastTurn: string
  lastErr: TurnErr | null
  // 增量折叠内部游标
  stepAt: Map<string, number>
  stepThinking: Map<string, string>
  stepTools: Map<string, ToolTrace[]>
  turnStart: number
  turnIn: number
  turnOut: number
  turnReplyAt: number
  carryThinking: string[]
  carryTools: ToolTrace[]
  currentStepKey: string
  toolById: Map<string, ToolTrace>
  // AgentTeams 增量状态（供 `/api/sessions/:id/team` 零解压直接复用）
  teamEnabled: boolean
  teamSawMode: boolean
  teamMembers: Map<string, Record<string, unknown>>
  teamTasks: Map<string, Record<string, unknown>>
  // 统一步骤/任务清单（来自 DSH `todo/write` 事件与 todo/task 类工具调用）
  todoSteps: TaskStep[]
}

const historyCache = new Map<string, SessionFoldEntry>()

function createEmptyFoldEntry(size: number, mtimeMs: number, headLen: number, firstChunkHash: string): SessionFoldEntry {
  return {
    size,
    mtimeMs,
    headLen,
    firstChunkHash,
    byteOffset: 0,
    messages: [],
    stats: {
      turns: 0,
      steps: 0,
      toolCalls: 0,
      tokens: { uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 },
    },
    lastTurn: '',
    lastErr: null,
    stepAt: new Map(),
    stepThinking: new Map(),
    stepTools: new Map(),
    turnStart: 0,
    turnIn: 0,
    turnOut: 0,
    turnReplyAt: -1,
    carryThinking: [],
    carryTools: [],
    currentStepKey: '',
    toolById: new Map(),
    teamEnabled: false,
    teamSawMode: false,
    teamMembers: new Map(),
    teamTasks: new Map(),
    todoSteps: [],
  }
}

/** 注册或更新一条工具调用轨迹，并挂到所属 step 或待合并队列上。 */
function registerToolTrace(
  entry: SessionFoldEntry,
  stepKey: string,
  callId: string,
  name: string,
  rawArgs: unknown,
): ToolTrace {
  const existing = entry.toolById.get(callId)
  if (existing !== undefined) {
    if (existing.summary === '' && rawArgs !== undefined) {
      existing.summary = summarizeToolArgs(name, rawArgs)
    }
    return existing
  }
  const trace: ToolTrace = {
    id: callId,
    name,
    summary: summarizeToolArgs(name, rawArgs),
    status: 'run',
  }
  entry.toolById.set(callId, trace)
  const msgIdx = entry.stepAt.get(stepKey)
  if (msgIdx !== undefined) {
    const row = entry.messages[msgIdx]
    if (row !== undefined) {
      if (row.tools === undefined) row.tools = []
      row.tools.push(trace)
      return trace
    }
  }
  const list = entry.stepTools.get(stepKey) ?? []
  list.push(trace)
  entry.stepTools.set(stepKey, list)
  return trace
}

/** 将未发言 step 累积的思考与工具轨迹刷入指定回复气泡。 */
function flushCarryIntoRow(entry: SessionFoldEntry, row: ChatMessage, stepKey: string): void {
  const ownThinking = entry.stepThinking.get(stepKey) ?? ''
  const allThinking = [...entry.carryThinking, ...(ownThinking !== '' ? [ownThinking] : [])].join('\n\n').trim()
  entry.carryThinking = []
  if (allThinking !== '') {
    row.thinking = capThinking(allThinking)
  }

  const ownTools = entry.stepTools.get(stepKey) ?? []
  const mergedTools: ToolTrace[] = []
  const seen = new Set<string>()
  for (const t of [...entry.carryTools, ...(row.tools ?? []), ...ownTools]) {
    if (!seen.has(t.id)) {
      seen.add(t.id)
      mergedTools.push(t)
    }
  }
  entry.carryTools = []
  entry.stepTools.delete(stepKey)
  if (mergedTools.length > 0) {
    row.tools = mergedTools
  }
}

/** 把上一个无文本 step 的思考与工具移入本轮 carry 池，等待本轮下一条有文本的回复承接。 */
function stashSilentStep(entry: SessionFoldEntry, stepKey: string): void {
  if (stepKey === '' || entry.stepAt.has(stepKey)) return
  const t = entry.stepThinking.get(stepKey)
  if (t !== undefined && t !== '') {
    entry.carryThinking.push(t)
    entry.stepThinking.delete(stepKey)
  }
  const tools = entry.stepTools.get(stepKey)
  if (tools !== undefined && tools.length > 0) {
    for (const item of tools) {
      if (!entry.carryTools.some((x) => x.id === item.id)) {
        entry.carryTools.push(item)
      }
    }
    entry.stepTools.delete(stepKey)
  }
}

/** 向增量状态喂入单行事件 JSON。 */
function foldEventLine(entry: SessionFoldEntry, line: string): void {
  let event: unknown
  try {
    event = JSON.parse(line)
  } catch {
    return
  }
  if (event === null || typeof event !== 'object') return
  const ev = event as Record<string, any>
  const type = String(ev.type ?? '')

  if (type === 'todo/write') {
    const rawTodos = ev.data?.todos ?? ev.data?.steps ?? ev.data?.items
    if (Array.isArray(rawTodos)) {
      entry.todoSteps = parseTaskStepArray(rawTodos)
    }
    return
  }

  // AgentTeams 事件顺带折叠，供 `/team` 路由直接读取。
  if (type === 'team/mode') {
    entry.teamSawMode = true
    entry.teamEnabled = ev.data?.enabled === true
    return
  }
  if (type === 'team/member') {
    const member = ev.data?.member
    if (member !== null && typeof member === 'object') {
      const id = String(member.id ?? '')
      entry.teamMembers.set(id, {
        id,
        name: String(member.name ?? ''),
        description: String(member.description ?? ''),
        phase: String(member.phase ?? ''),
        error: String(member.error ?? ''),
      })
    }
    return
  }
  if (type === 'team/task') {
    const task = ev.data?.task
    if (task !== null && typeof task === 'object') {
      const id = String(task.id ?? '')
      const seen = entry.teamTasks.get(id)
      const revision = Number(task.revision ?? 0)
      if (seen === undefined || Number(seen.revision ?? -1) <= revision) {
        entry.teamTasks.set(id, {
          id,
          revision,
          subject: String(task.subject ?? ''),
          description: String(task.description ?? ''),
          status: String(task.status ?? 'pending'),
          ownerName: String(task.ownerName ?? ''),
          ownerId: String(task.ownerId ?? ''),
        })
      }
    }
    return
  }

  if (type === 'turn/start') {
    stashSilentStep(entry, entry.currentStepKey)
    entry.stats.turns += 1
    entry.turnStart = Number(ev.time ?? 0)
    entry.turnIn = 0
    entry.turnOut = 0
    entry.turnReplyAt = -1
    entry.carryThinking = []
    entry.carryTools = []
    entry.currentStepKey = ''
    entry.toolById.clear()
    return
  }

  if (type === 'step/start') {
    stashSilentStep(entry, entry.currentStepKey)
    entry.stats.steps += 1
    entry.currentStepKey = `${String(ev.data?.turn ?? '')}:${String(ev.data?.step ?? '')}`
    return
  }

  if (type === 'turn/end') {
    stashSilentStep(entry, entry.currentStepKey)
    entry.currentStepKey = ''
    entry.lastTurn = String(ev.data?.reason?.kind ?? '')
    const rawErr = ev.data?.reason?.error
    let errCode = ''
    let errText = ''
    if (rawErr !== null && typeof rawErr === 'object') {
      errCode = String((rawErr as Record<string, unknown>).code ?? '')
      errText = String((rawErr as Record<string, unknown>).message ?? '')
    } else if (typeof rawErr === 'string') {
      errText = rawErr
    }
    if (errText !== '') {
      entry.lastErr = { code: errCode, text: errText, time: Number(ev.time ?? 0) }
    } else {
      entry.lastErr = null
    }
    const row = entry.turnReplyAt >= 0 ? entry.messages[entry.turnReplyAt] : undefined
    if (row !== undefined) {
      // 若本轮最后几跳是纯工具调用而未再发新文本，将其思考与工具并入本轮最后一条可见回复。
      if (entry.carryThinking.length > 0) {
        const merged = [row.thinking ?? '', ...entry.carryThinking].filter(Boolean).join('\n\n')
        row.thinking = capThinking(merged)
        entry.carryThinking = []
      }
      if (entry.carryTools.length > 0) {
        const existing = row.tools ?? []
        const seen = new Set(existing.map((t) => t.id))
        for (const t of entry.carryTools) {
          if (!seen.has(t.id)) {
            seen.add(t.id)
            existing.push(t)
          }
        }
        row.tools = existing
        entry.carryTools = []
      }
      const endAt = Number(ev.time ?? 0)
      row.turn = {
        status: entry.lastTurn,
        ms: endAt > entry.turnStart && entry.turnStart > 0 ? endAt - entry.turnStart : 0,
        tokensIn: entry.turnIn,
        tokensOut: entry.turnOut,
        atSeq: Number(ev.seq ?? 0),
        finishedAt: endAt > 0 ? endAt : Date.now(),
      }
      if (errText !== '') {
        row.turn.errCode = errCode
        row.turn.errText = errText
      }
    }
    return
  }

  if (type === 'tool/call') {
    entry.stats.toolCalls += 1
    const callId = String(ev.data?.callId ?? ev.data?.id ?? '')
    const name = String(ev.data?.name ?? '')
    const rawArgs = ev.data?.arguments ?? ev.data?.args ?? ev.data?.input
    const stepKey = `${String(ev.data?.turn ?? '')}:${String(ev.data?.step ?? '')}`
    if (callId !== '' && name !== '') {
      registerToolTrace(entry, stepKey, callId, name, rawArgs)
    }
    if (name !== '') {
      const mut = applyTaskToolCall(entry.todoSteps, name, rawArgs)
      if (mut.changed) entry.todoSteps = mut.tasks
    }
    return
  }

  if (type === 'tool/result') {
    const msg = ev.data?.message
    const parts = Array.isArray(msg?.content) ? (msg.content as Array<Record<string, unknown>>) : []
    const callId = String(
      ev.data?.callId
      ?? ev.data?.toolCallId
      ?? msg?.source?.callId
      ?? parts[0]?.toolCallId
      ?? '',
    )
    if (callId !== '') {
      const trace = entry.toolById.get(callId)
      if (trace !== undefined) {
        const isErr = ev.data?.isError === true || parts.some((p) => p?.isError === true)
        trace.status = isErr ? 'err' : 'ok'
      }
    }
    return
  }

  if (type === 'assistant/attempt') {
    accumulateTokens(entry.stats.tokens, ev.data)
    return
  }

  if (type === 'user/message') {
    const source = ev.data?.source
    if (source !== undefined && source !== null && String(source.kind ?? 'user') !== 'user') return
    const text = textOf(ev.data?.content)
    if (text.length === 0 || text.startsWith('<system-reminder>')) return
    const images = imagesOf(ev.data?.content)
    const row: ChatMessage = { role: 'user', text, time: Number(ev.time ?? 0), seq: Number(ev.seq ?? 0) }
    if (images.length > 0) row.images = images
    entry.messages.push(row)
    return
  }

  if (type === 'assistant/message') {
    const content = ev.data?.message?.content
    const text = textOf(content)
    const thinking = thinkingOf(content)
    const embedded = embeddedToolsOf(content)
    const stepKey = `${String(ev.data?.turn ?? '')}:${String(ev.data?.step ?? '')}`
    if (entry.currentStepKey !== '' && entry.currentStepKey !== stepKey) {
      stashSilentStep(entry, entry.currentStepKey)
    }
    entry.currentStepKey = stepKey

    const usage = ev.data?.usage
    if (usage !== null && typeof usage === 'object') {
      const freshIn = Number(usage.inputTokens ?? 0) || 0
      const cachedIn = Number(usage.cacheReadTokens ?? usage.cachedInputTokens ?? 0) || 0
      entry.turnIn = freshIn + cachedIn
      entry.turnOut += Number(usage.outputTokens ?? 0) || 0
    }

    if (thinking !== '') {
      entry.stepThinking.set(stepKey, thinking)
    }
    for (const tool of embedded) {
      registerToolTrace(entry, stepKey, tool.id, tool.name, tool.args)
    }

    if (text.length === 0) return

    const prevIdx = entry.stepAt.get(stepKey)
    const prevRow = prevIdx !== undefined ? entry.messages[prevIdx] : undefined
    const row: ChatMessage = {
      role: 'assistant',
      text,
      time: Number(ev.time ?? 0),
      seq: Number(ev.seq ?? 0),
    }
    if (prevRow?.thinking !== undefined) row.thinking = prevRow.thinking
    if (prevRow?.tools !== undefined) row.tools = prevRow.tools
    flushCarryIntoRow(entry, row, stepKey)
    if (thinking !== '' && row.thinking === undefined) {
      row.thinking = capThinking(thinking)
    }

    if (prevIdx !== undefined) {
      entry.messages[prevIdx] = row
      entry.turnReplyAt = prevIdx
    } else {
      const idx = entry.messages.length
      entry.stepAt.set(stepKey, idx)
      entry.turnReplyAt = idx
      entry.messages.push(row)
    }
  }
}

/** 维护 `historyCache` 的 LRU 顺序并裁剪到最多 16 个会话。 */
function touchHistoryCache(file: string, entry: SessionFoldEntry): void {
  historyCache.delete(file)
  historyCache.set(file, entry)
  while (historyCache.size > HISTORY_CACHE_CAP) {
    const oldest = historyCache.keys().next().value
    if (oldest === undefined) break
    historyCache.delete(oldest)
  }
}

/**
 * 确保指定会话日志文件在 `historyCache` 中已解码到最新字节：
 * - 文件未变：直接命中返回；
 * - 文件追加增长且头部块哈希未变：仅读取 `[cached.byteOffset, stat.size)` 增量解压合并；
 * - 首次读取、文件缩小或头部重写：全量读取重算。
 */
function ensureDecoded(file: string): SessionFoldEntry {
  if (zstdDecompressSync === undefined) throw new Error('this Node build has no zstd support')
  const st = statSync(file)
  if (st.size > MAX_SESSION_BYTES) {
    throw new Error(`session log is ${String(st.size)} bytes, over the safety cap`)
  }

  const cached = historyCache.get(file)
  if (cached !== undefined && cached.size === st.size && cached.mtimeMs === st.mtimeMs) {
    touchHistoryCache(file, cached)
    return cached
  }

  let fd: number | undefined
  try {
    fd = openSync(file, 'r')

    if (cached !== undefined && st.size >= cached.byteOffset && cached.headLen > 0 && st.size >= cached.headLen) {
      const currentHead = readRange(fd, 0, cached.headLen)
      if (hashBuffer(currentHead) === cached.firstChunkHash) {
        if (st.size === cached.byteOffset) {
          cached.size = st.size
          cached.mtimeMs = st.mtimeMs
          touchHistoryCache(file, cached)
          return cached
        }
        const delta = readRange(fd, cached.byteOffset, st.size - cached.byteOffset)
        const { lines, consumedBytes } = decodeZstdFrames(delta)
        for (const line of lines) {
          foldEventLine(cached, line)
        }
        cached.byteOffset += consumedBytes
        cached.size = st.size
        cached.mtimeMs = st.mtimeMs
        touchHistoryCache(file, cached)
        return cached
      }
    }

    // 全量读取路径
    const raw = readRange(fd, 0, st.size)
    const headLen = Math.min(raw.length, HEAD_HASH_BYTES)
    const firstChunkHash = headLen > 0 ? hashBuffer(raw.subarray(0, headLen)) : ''
    const entry = createEmptyFoldEntry(st.size, st.mtimeMs, headLen, firstChunkHash)
    const { lines, consumedBytes } = decodeZstdFrames(raw)
    for (const line of lines) {
      foldEventLine(entry, line)
    }
    entry.byteOffset = consumedBytes
    touchHistoryCache(file, entry)
    return entry
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // ignore close error
      }
    }
  }
}

/** 从折叠状态组装统一的任务/步骤列表：优先返回原生 todoSteps，否则回退映射 AgentTeams 任务。 */
function resolveSessionTasks(entry: SessionFoldEntry): TaskStep[] {
  if (entry.todoSteps.length > 0) {
    return cloneTaskSteps(entry.todoSteps)
  }
  if (entry.teamTasks.size === 0) return []
  const rows = Array.from(entry.teamTasks.values())
    .filter((task) => task.status !== 'deleted')
    .sort((a, b) => {
      const rank = (s: unknown): number =>
        s === 'in_progress' ? 0 : s === 'pending' ? 1 : s === 'completed' ? 2 : 3
      const delta = rank(a.status) - rank(b.status)
      return delta !== 0 ? delta : String(a.subject ?? '').localeCompare(String(b.subject ?? ''))
    })
  return rows
    .map((task, idx): TaskStep | null => {
      const title = String(task.subject ?? '').replace(/\s+/g, ' ').trim().slice(0, 220)
      if (!title) return null
      const id = String(task.id ?? '') || `team-${String(idx + 1)}`
      const status = normalizeTaskStatus(task.status)
      const owner = String(task.ownerName ?? '').trim()
      const descLine = String(task.description ?? '').split(/\r?\n/)[0]?.trim() ?? ''
      const detail = owner ? `负责: ${owner}` : (descLine && descLine !== title ? descLine.slice(0, 140) : undefined)
      const step: TaskStep = { id, title, status }
      if (detail) step.detail = detail
      return step
    })
    .filter((x): x is TaskStep => x !== null)
}

/** 读取会话完整消息轨迹与统计（自动走增量 Zstd 缓存）。 */
export function historyOf(file: string): {
  messages: ChatMessage[]
  stats: SessionStats
  lastTurn: string
  lastErr: TurnErr | null
  byteOffset: number
  tasks: TaskStep[]
} {
  const entry = ensureDecoded(file)
  return {
    messages: entry.messages,
    stats: entry.stats,
    lastTurn: entry.lastTurn,
    lastErr: entry.lastErr,
    byteOffset: entry.byteOffset,
    tasks: resolveSessionTasks(entry),
  }
}

/** 复用 `historyCache` 增量解压结果构造 AgentTeams 团队状态快照。 */
export function teamOf(file: string): TeamSnapshot {
  const entry = ensureDecoded(file)
  const taskRows = Array.from(entry.teamTasks.values())
    .filter((task) => task.status !== 'deleted')
    .sort((a, b) => {
      const rank = (s: unknown): number =>
        s === 'in_progress' ? 0 : s === 'pending' ? 1 : s === 'completed' ? 2 : 3
      const delta = rank(a.status) - rank(b.status)
      return delta !== 0 ? delta : String(a.subject).localeCompare(String(b.subject))
    })
  return {
    enabled: entry.teamEnabled,
    sawMode: entry.teamSawMode,
    members: Array.from(entry.teamMembers.values()),
    tasks: taskRows,
  }
}

/** 折叠单条历史消息中的超长 Markdown 代码块（保持围栏闭合）。 */
function foldLongCodeBlocks(text: string): string {
  return text.replace(/```([^\n`]*)\n([\s\S]*?)```/g, (full, lang: string, body: string) => {
    const lines = body.split('\n')
    if (lines.length <= 8 && body.length <= 360) return full
    const head = lines.slice(0, 4).join('\n')
    const omitted = Math.max(1, lines.length - 4)
    return `\`\`\`${lang}\n${head}\n⋯ (已折叠 ${String(omitted)} 行代码)\n\`\`\``
  })
}

/**
 * R4 会话精简模式（`?compact=1`）：
 * 对早于最后 6 条的历史消息裁剪 `thinking`（最多 160 字）并折叠超长代码块，不改动缓存原对象。
 */
export function applyCompactMode(all: readonly ChatMessage[], page: readonly ChatMessage[]): ChatMessage[] {
  const keepFullFromSeq = all.length > 6 ? (all[all.length - 6]?.seq ?? 0) : 0
  return page.map((msg) => {
    if (msg.seq >= keepFullFromSeq) return msg
    const nextText = msg.text.includes('```') ? foldLongCodeBlocks(msg.text) : msg.text
    const nextThinking = msg.thinking !== undefined && msg.thinking.length > COMPACT_THINKING_CHARS
      ? `${msg.thinking.slice(0, COMPACT_THINKING_CHARS - 1)}⋯`
      : msg.thinking
    if (nextText === msg.text && nextThinking === msg.thinking) return msg
    const copy: ChatMessage = { ...msg, text: nextText }
    if (nextThinking !== undefined) copy.thinking = nextThinking
    return copy
  })
}

/** 读取日志尾部 96 KB 窗口提取最后一条消息单行预览（无需全量解压）。 */
export function previewOf(file: string): { preview: string; count: number } {
  // 若该会话已在增量缓存中，直接取最后一条可读消息，零磁盘读取！
  const cached = historyCache.get(file)
  if (cached !== undefined && cached.messages.length > 0) {
    const last = cached.messages[cached.messages.length - 1]
    return { preview: plainPreview(last?.text ?? ''), count: cached.messages.length }
  }

  if (zstdDecompressSync === undefined) return { preview: '', count: 0 }
  let size = 0
  try {
    size = statSync(file).size
  } catch {
    return { preview: '', count: 0 }
  }
  const window = Math.min(size, 96 * 1024)
  if (window < 16) return { preview: '', count: 0 }
  let fd: number | undefined
  let buf: Buffer
  try {
    fd = openSync(file, 'r')
    buf = readRange(fd, size - window, window)
  } catch {
    return { preview: '', count: 0 }
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // ignore
      }
    }
  }
  const starts: number[] = []
  let cursor = 0
  while ((cursor = buf.indexOf(ZSTD_MAGIC, cursor)) !== -1) {
    starts.push(cursor)
    cursor += 4
  }
  const startIdx = size > window ? 1 : 0
  if (starts.length <= startIdx) return { preview: '', count: 0 }
  const texts: string[] = []
  let count = 0
  for (let index = startIdx; index < starts.length; index += 1) {
    const from = starts[index] as number
    const to = index + 1 < starts.length ? (starts[index + 1] as number) : buf.length
    let decoded = ''
    try {
      decoded = zstdDecompressSync(buf.subarray(from, to)).toString('utf8')
    } catch {
      continue
    }
    for (const raw of decoded.split('\n')) {
      if (raw.length === 0) continue
      let ev: { type?: unknown; data?: { content?: unknown; message?: { content?: unknown } } }
      try {
        ev = JSON.parse(raw) as typeof ev
      } catch {
        continue
      }
      const kind = String(ev.type ?? '')
      if (kind !== 'user/message' && kind !== 'assistant/message') continue
      count += 1
      const content = kind === 'user/message' ? ev.data?.content : ev.data?.message?.content
      const text = textOf(content)
      if (text === '' || text.startsWith('<system-reminder>')) continue
      texts.push(text)
    }
  }
  const last = texts.length > 0 ? (texts[texts.length - 1] as string) : ''
  return { preview: plainPreview(last), count }
}

/** 读取完整会话日志的原始 JSONL 文本（用于 ZIP 导出）。 */
export function rawSessionJsonl(file: string): string {
  if (zstdDecompressSync === undefined) throw new Error('this Node build has no zstd support')
  const st = statSync(file)
  if (st.size > MAX_SESSION_BYTES) {
    throw new Error(`session log is ${String(st.size)} bytes, over the safety cap`)
  }
  let fd: number | undefined
  try {
    fd = openSync(file, 'r')
    const raw = readRange(fd, 0, st.size)
    const { lines } = decodeZstdFrames(raw)
    return lines.length > 0 ? `${lines.join('\n')}\n` : ''
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd)
      } catch {
        // ignore close error
      }
    }
  }
}
