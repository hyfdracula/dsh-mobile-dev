/**
 * Claude Code 原生后端适配器（无需安装第三方 `claude-agent-acp`）：
 * - 直接扫描 `~/.claude/projects/` 下的 `.jsonl` 发现电脑端已有 Claude Code 会话与完整历史；
 * - 使用原生 `claude -p --output-format stream-json --verbose [--resume <id>] [--model <m>]` 执行续聊与新建；
 * - 实时解析 `stream-json` 增量（思考、正文、工具调用与结果），支持按进程树安全中断。
 */
import type { ChildProcess } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join } from 'node:path'
import type { ChatMessage, ToolTrace } from '../transcript.ts'
import {
  killProcessTree,
  probeCliVersion,
  resolveCliCommand,
  spawnCli,
  validateWorkingDir,
  type ResolvedCli,
} from './process-util.ts'
import {
  formatSessionId,
  type AgentBackend,
  type BackendAskState,
  type BackendCapabilities,
  type BackendImageInput,
  type BackendMessagesResult,
  type BackendModelOption,
  type BackendNotifyEvent,
  type BackendProbeResult,
  type BackendSessionRow,
  type BackendStreamEvent,
} from './types.ts'

export const CLAUDE_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: false,
  abort: true,
  images: false,
  files: false,
  modelSwitch: true,
  reasoningEffort: false,
  planMode: false,
  goalMode: false,
  compact: false,
  fork: false,
  archivePin: false,
  webConsole: false,
}

interface ClaudeRuntimeSession {
  rawId: string
  filePath: string
  cwd: string
  title: string
  model: string
  updatedAt: number
  isNew: boolean
  running: boolean
  activeChild: ChildProcess | null
  localMessages: ChatMessage[]
}

const DEFAULT_CLAUDE_MODELS: BackendModelOption[] = [
  { id: 'sonnet', name: 'Claude Sonnet (默认)', provider: 'claude' },
  { id: 'opus', name: 'Claude Opus', provider: 'claude' },
  { id: 'haiku', name: 'Claude Haiku', provider: 'claude' },
]

function claudeProjectsDir(): string {
  return join(homedir(), '.claude', 'projects')
}

function decodeProjectDirName(dirName: string): string {
  // Windows 编码示例: `C--Users-alice-workspace` -> 尝试还原为可读路径
  const winDrive = /^([A-Za-z])--(.*)$/.exec(dirName)
  if (winDrive) {
    return `${winDrive[1]}:\\${winDrive[2].replace(/-/g, '\\')}`
  }
  return dirName
}

interface ParsedClaudeFile {
  sessionId: string
  title: string
  cwd: string
  model: string
  preview: string
  messages: ChatMessage[]
}

function extractUserText(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const out: string[] = []
  for (const item of content) {
    if (typeof item === 'string') {
      out.push(item)
    } else if (item && typeof item === 'object') {
      const o = item as Record<string, unknown>
      if (o.type === 'text' && typeof o.text === 'string') {
        out.push(o.text)
      }
    }
  }
  return out.join('\n')
}

function parseClaudeJsonl(filePath: string, fullHistory: boolean): ParsedClaudeFile {
  const sessionId = basename(filePath, '.jsonl')
  let title = ''
  let cwd = ''
  let model = ''
  let preview = ''
  const messages: ChatMessage[] = []
  const toolIndex = new Map<string, ToolTrace>()

  let raw = ''
  try {
    raw = readFileSync(filePath, 'utf8')
  } catch {
    return { sessionId, title: 'Claude 会话', cwd: homedir(), model: '', preview: '', messages: [] }
  }

  const lines = raw.split(/\r?\n/)
  let seq = 0
  for (const line of lines) {
    if (!line.trim()) continue
    let o: Record<string, unknown>
    try {
      const p = JSON.parse(line)
      if (!p || typeof p !== 'object') continue
      o = p as Record<string, unknown>
    } catch {
      continue
    }

    if (typeof o.cwd === 'string' && o.cwd.trim() !== '') {
      cwd = o.cwd.trim()
    }
    const typ = typeof o.type === 'string' ? o.type : ''
    if (typ === 'ai-title' && typeof o.aiTitle === 'string' && o.aiTitle.trim() !== '') {
      title = o.aiTitle.trim()
      continue
    }
    if (typ === 'last-prompt' && typeof o.lastPrompt === 'string' && !title) {
      title = o.lastPrompt.replace(/\s+/g, ' ').trim().slice(0, 48)
      continue
    }

    const msgObj = o.message && typeof o.message === 'object' ? (o.message as Record<string, unknown>) : null
    if (!msgObj) continue
    const tMs = typeof o.timestamp === 'string' ? Date.parse(o.timestamp) || Date.now() : Date.now()

    if (typ === 'user') {
      const content = msgObj.content
      // 合并 tool_result 到上一个 assistant 工具卡片
      if (Array.isArray(content)) {
        let onlyToolResults = true
        for (const block of content) {
          if (block && typeof block === 'object') {
            const b = block as Record<string, unknown>
            if (b.type === 'tool_result') {
              const tid = typeof b.tool_use_id === 'string' ? b.tool_use_id : ''
              const tc = tid ? toolIndex.get(tid) : undefined
              if (tc) {
                tc.status = b.is_error === true ? 'err' : 'ok'
              }
            } else if (b.type === 'text' && typeof b.text === 'string' && b.text.trim() !== '') {
              onlyToolResults = false
            }
          }
        }
        if (onlyToolResults) continue
      }
      const txt = extractUserText(content).trim()
      if (!txt) continue
      if (!title) title = txt.replace(/\s+/g, ' ').slice(0, 48)
      if (!preview) preview = txt.replace(/\s+/g, ' ').slice(0, 120)
      if (fullHistory) {
        messages.push({
          seq: ++seq,
          role: 'user',
          text: txt,
          time: tMs,
        })
      }
      continue
    }

    if (typ === 'assistant') {
      if (typeof msgObj.model === 'string' && msgObj.model.trim() !== '') {
        model = msgObj.model.trim()
      }
      const content = msgObj.content
      let text = ''
      let thinking = ''
      const tools: ToolTrace[] = []
      if (typeof content === 'string') {
        text = content
      } else if (Array.isArray(content)) {
        for (const block of content) {
          if (!block || typeof block !== 'object') continue
          const b = block as Record<string, unknown>
          if (b.type === 'thinking' && typeof b.thinking === 'string') {
            thinking = thinking ? `${thinking}\n${b.thinking}` : b.thinking
          } else if (b.type === 'text' && typeof b.text === 'string') {
            text = text ? `${text}\n${b.text}` : b.text
          } else if (b.type === 'tool_use') {
            const tid = typeof b.id === 'string' ? b.id : `cl-t-${seq}`
            const name = typeof b.name === 'string' ? b.name : 'tool'
            const tc: ToolTrace = {
              id: tid,
              name,
              summary: b.input !== undefined ? JSON.stringify(b.input).slice(0, 200) : name,
              status: 'ok',
            }
            tools.push(tc)
            toolIndex.set(tid, tc)
          }
        }
      }
      if (text.trim() !== '') {
        preview = text.replace(/\s+/g, ' ').trim().slice(0, 120)
      }
      if (fullHistory && (text.trim() !== '' || thinking.trim() !== '' || tools.length > 0)) {
        const prev = messages[messages.length - 1]
        if (prev && prev.role === 'assistant' && !text && !thinking && tools.length > 0) {
          prev.tools = [...(prev.tools ?? []), ...tools]
        } else {
          messages.push({
            seq: ++seq,
            role: 'assistant',
            text,
            thinking,
            tools,
            time: tMs,
          })
        }
      }
    }
  }

  return {
    sessionId,
    title: title || 'Claude 会话',
    cwd,
    model,
    preview,
    messages,
  }
}

export class ClaudeBackend implements AgentBackend {
  readonly id = 'claude' as const
  readonly label = 'Claude Code'
  readonly capabilities = CLAUDE_CAPABILITIES

  private cli: ResolvedCli | null = null
  private readonly runtime = new Map<string, ClaudeRuntimeSession>()
  private readonly listeners = new Map<string, Set<(ev: BackendStreamEvent) => void>>()
  private notifyHook: ((ev: BackendNotifyEvent) => void) | null = null

  setNotifyHook(fn: ((ev: BackendNotifyEvent) => void) | null): void {
    this.notifyHook = fn
  }

  private emitNotify(rawId: string, kind: 'done' | 'asking', status?: string): void {
    if (!this.notifyHook) return
    const title = this.runtime.get(rawId)?.title || 'Claude 会话'
    try {
      this.notifyHook({ sessionId: formatSessionId(this.id, rawId), title, kind, status })
    } catch {
      // isolate notify listener errors
    }
  }

  private ensureCli(force = false): ResolvedCli | null {
    if (!force && this.cli) return this.cli
    this.cli = resolveCliCommand('claude', force)
    return this.cli
  }

  private emit(rawId: string, ev: BackendStreamEvent): void {
    const set = this.listeners.get(rawId)
    if (!set) return
    for (const fn of set) {
      try {
        fn(ev)
      } catch {
        // isolate subscriber errors
      }
    }
  }

  private scanSessionFiles(): Array<{ rawId: string; filePath: string; mtimeMs: number; dirName: string }> {
    const root = claudeProjectsDir()
    if (!existsSync(root)) return []
    const found: Array<{ rawId: string; filePath: string; mtimeMs: number; dirName: string }> = []
    try {
      for (const projDir of readdirSync(root)) {
        const fullDir = join(root, projDir)
        let st
        try {
          st = statSync(fullDir)
        } catch {
          continue
        }
        if (!st.isDirectory()) continue
        for (const name of readdirSync(fullDir)) {
          if (!name.endsWith('.jsonl')) continue
          const fp = join(fullDir, name)
          try {
            const fst = statSync(fp)
            if (!fst.isFile() || fst.size === 0) continue
            found.push({
              rawId: basename(name, '.jsonl'),
              filePath: fp,
              mtimeMs: fst.mtimeMs,
              dirName: projDir,
            })
          } catch {
            // skip unreadable file
          }
        }
      }
    } catch {
      return []
    }
    found.sort((a, b) => b.mtimeMs - a.mtimeMs)
    return found
  }

  private locateSessionFile(rawId: string): string {
    const cached = this.runtime.get(rawId)
    if (cached?.filePath && existsSync(cached.filePath)) return cached.filePath
    const hit = this.scanSessionFiles().find((f) => f.rawId === rawId)
    return hit?.filePath ?? ''
  }

  async probe(force = false): Promise<BackendProbeResult> {
    const cli = this.ensureCli(force)
    if (!cli) {
      return { installed: false, version: '', binaryPath: '', error: '未检测到 claude 命令' }
    }
    const version = await probeCliVersion(cli, force)
    return { installed: true, version: version || 'installed', binaryPath: cli.displayPath }
  }

  async listSessions(limit = 40): Promise<BackendSessionRow[]> {
    const files = this.scanSessionFiles().slice(0, Math.max(limit, 50))
    const rows: BackendSessionRow[] = []
    const seen = new Set<string>()

    for (const f of files) {
      seen.add(f.rawId)
      const parsed = parseClaudeJsonl(f.filePath, false)
      const fallbackCwd = decodeProjectDirName(f.dirName)
      const cwd = parsed.cwd || (existsSync(fallbackCwd) ? fallbackCwd : homedir())
      let rt = this.runtime.get(f.rawId)
      if (!rt) {
        rt = {
          rawId: f.rawId,
          filePath: f.filePath,
          cwd,
          title: parsed.title,
          model: parsed.model,
          updatedAt: Math.round(f.mtimeMs),
          isNew: false,
          running: false,
          activeChild: null,
          localMessages: [],
        }
        this.runtime.set(f.rawId, rt)
      } else {
        rt.filePath = f.filePath
        rt.isNew = false
        if (parsed.title && parsed.title !== 'Claude 会话') rt.title = parsed.title
        if (parsed.model) rt.model = parsed.model
        if (cwd) rt.cwd = cwd
        if (f.mtimeMs > rt.updatedAt) rt.updatedAt = Math.round(f.mtimeMs)
      }
      rows.push({
        id: formatSessionId('claude', f.rawId),
        rawId: f.rawId,
        backend: 'claude',
        title: rt.title,
        cwd: rt.cwd,
        updatedAt: rt.updatedAt,
        running: rt.running,
        asking: false,
        preview: parsed.preview,
        model: rt.model ? { provider: 'claude', model: rt.model, reasoningEffort: '' } : null,
      })
    }

    // 合并手机端刚新建、尚未发第一条消息落盘的会话
    for (const rt of this.runtime.values()) {
      if (seen.has(rt.rawId)) continue
      rows.push({
        id: formatSessionId('claude', rt.rawId),
        rawId: rt.rawId,
        backend: 'claude',
        title: rt.title,
        cwd: rt.cwd,
        updatedAt: rt.updatedAt,
        running: rt.running,
        asking: false,
        model: rt.model ? { provider: 'claude', model: rt.model, reasoningEffort: '' } : null,
      })
    }

    rows.sort((a, b) => b.updatedAt - a.updatedAt)
    return rows.slice(0, limit)
  }

  async getMessages(
    rawId: string,
    opts?: { limit?: number; offset?: number; compact?: boolean },
  ): Promise<BackendMessagesResult> {
    const rt = this.runtime.get(rawId)
    const fp = this.locateSessionFile(rawId)
    let all: ChatMessage[] = []
    let model = rt?.model ?? ''
    let cwd = rt?.cwd ?? homedir()

    if (fp) {
      const parsed = parseClaudeJsonl(fp, true)
      all = parsed.messages
      if (parsed.model) model = parsed.model
      if (parsed.cwd) cwd = parsed.cwd
      if (rt) {
        rt.filePath = fp
        rt.isNew = false
        if (model) rt.model = model
        if (cwd) rt.cwd = cwd
      }
    } else if (rt && rt.localMessages.length > 0) {
      all = [...rt.localMessages]
    }

    const lim = opts?.limit && opts.limit > 0 ? opts.limit : all.length
    const start = Math.max(0, all.length - lim)
    return {
      messages: all.slice(start),
      total: all.length,
      hasMore: start > 0,
      model: model || undefined,
      cwd,
      running: rt?.running === true,
      asking: false,
    }
  }

  async createSession(cwd: string, opts?: { title?: string; model?: string }): Promise<BackendSessionRow> {
    const safeCwd = validateWorkingDir(cwd, true)
    const rawId = randomUUID()
    const rt: ClaudeRuntimeSession = {
      rawId,
      filePath: '',
      cwd: safeCwd,
      title: opts?.title?.trim() || 'Claude 新会话',
      model: opts?.model?.trim() || '',
      updatedAt: Date.now(),
      isNew: true,
      running: false,
      activeChild: null,
      localMessages: [],
    }
    this.runtime.set(rawId, rt)
    return {
      id: formatSessionId('claude', rawId),
      rawId,
      backend: 'claude',
      title: rt.title,
      cwd: rt.cwd,
      updatedAt: rt.updatedAt,
      running: false,
      asking: false,
      model: rt.model ? { provider: 'claude', model: rt.model, reasoningEffort: '' } : null,
    }
  }

  async sendMessage(
    rawId: string,
    text: string,
    opts?: { images?: BackendImageInput[]; model?: string; cwd?: string },
  ): Promise<{ ok: boolean; runId?: string; status?: string }> {
    const cli = this.ensureCli()
    if (!cli) throw new Error('本机未检测到 claude 命令')
    const trimmed = text.trim()
    if (!trimmed) throw new Error('消息内容不能为空')

    let rt = this.runtime.get(rawId)
    if (!rt) {
      const fp = this.locateSessionFile(rawId)
      const parsed = fp ? parseClaudeJsonl(fp, false) : null
      rt = {
        rawId,
        filePath: fp,
        cwd: opts?.cwd || parsed?.cwd || homedir(),
        title: parsed?.title || trimmed.slice(0, 36),
        model: opts?.model || parsed?.model || '',
        updatedAt: Date.now(),
        isNew: !fp,
        running: false,
        activeChild: null,
        localMessages: [],
      }
      this.runtime.set(rawId, rt)
    }
    if (rt.running) {
      throw new Error('Claude Code 当前会话正在运行，请等待完成或先中断')
    }

    const safeCwd = validateWorkingDir(opts?.cwd || rt.cwd, true)
    rt.cwd = safeCwd
    if (opts?.model && opts.model.trim() !== '') {
      rt.model = opts.model.trim()
    }
    if (rt.title === 'Claude 新会话' || rt.title === 'Claude 会话') {
      rt.title = trimmed.slice(0, 36)
    }

    const args: string[] = [
      '-p',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
    ]
    if (rt.isNew) {
      args.push('--session-id', rawId)
    } else {
      args.push('--resume', rawId)
    }
    if (rt.model) {
      args.push('--model', rt.model)
    }
    args.push(trimmed)

    rt.localMessages.push({
      seq: rt.localMessages.length + 1,
      role: 'user',
      text: trimmed,
      time: Date.now(),
    })

    const child = spawnCli(cli, args, { cwd: safeCwd })
    rt.activeChild = child
    rt.running = true
    rt.updatedAt = Date.now()
    this.emit(rawId, { type: 'status', running: true })

    let stdoutBuf = ''
    let stderrText = ''
    let accText = ''
    let accThinking = ''
    let sawStreamDeltas = false

    const handleJsonLine = (line: string): void => {
      let ev: Record<string, unknown>
      try {
        const p = JSON.parse(line)
        if (!p || typeof p !== 'object') return
        ev = p as Record<string, unknown>
      } catch {
        return
      }

      // 1. 流式增量事件（--include-partial-messages）
      if (ev.type === 'stream_event' && ev.event && typeof ev.event === 'object') {
        const inner = ev.event as Record<string, unknown>
        if (inner.type === 'content_block_delta' && inner.delta && typeof inner.delta === 'object') {
          const d = inner.delta as Record<string, unknown>
          if (d.type === 'text_delta' && typeof d.text === 'string' && d.text !== '') {
            sawStreamDeltas = true
            accText += d.text
            rt!.updatedAt = Date.now()
            this.emit(rawId, { type: 'delta', text: d.text, running: true })
          } else if (d.type === 'thinking_delta' && typeof d.thinking === 'string' && d.thinking !== '') {
            sawStreamDeltas = true
            accThinking += d.thinking
            rt!.updatedAt = Date.now()
            this.emit(rawId, { type: 'thinking', thinking: d.thinking, running: true })
          }
        }
        return
      }

      // 2. 完整 assistant 块（若未开启/未收到增量时兜底补发，同时推送工具调用）
      if (ev.type === 'assistant' && ev.message && typeof ev.message === 'object') {
        const m = ev.message as Record<string, unknown>
        if (typeof m.model === 'string' && m.model) rt!.model = m.model
        const content = Array.isArray(m.content) ? m.content : []
        for (const block of content) {
          if (!block || typeof block !== 'object') continue
          const b = block as Record<string, unknown>
          if (b.type === 'text' && typeof b.text === 'string' && b.text && !sawStreamDeltas) {
            const diff = b.text.startsWith(accText) ? b.text.slice(accText.length) : b.text
            if (diff) {
              accText += diff
              this.emit(rawId, { type: 'delta', text: diff, running: true })
            }
          } else if (b.type === 'thinking' && typeof b.thinking === 'string' && b.thinking && !sawStreamDeltas) {
            const diff = b.thinking.startsWith(accThinking) ? b.thinking.slice(accThinking.length) : b.thinking
            if (diff) {
              accThinking += diff
              this.emit(rawId, { type: 'thinking', thinking: diff, running: true })
            }
          } else if (b.type === 'tool_use') {
            this.emit(rawId, {
              type: 'tool',
              toolId: typeof b.id === 'string' ? b.id : undefined,
              toolName: typeof b.name === 'string' ? b.name : 'tool',
              toolInput: b.input !== undefined ? JSON.stringify(b.input).slice(0, 500) : '',
              toolStatus: 'running',
              running: true,
            })
          }
        }
        return
      }

      // 3. 最终结果事件
      if (ev.type === 'result') {
        if (ev.is_error === true) {
          const errStr = typeof ev.result === 'string' ? ev.result : 'Claude Code 执行失败'
          this.emit(rawId, { type: 'error', error: errStr, running: false })
        } else if (typeof ev.result === 'string' && ev.result !== '' && accText === '') {
          accText = ev.result
          this.emit(rawId, { type: 'delta', text: ev.result, running: true })
        }
      }
    }

    child.stdout?.on('data', (chunk: Buffer) => {
      stdoutBuf += chunk.toString('utf8')
      let nl: number
      while ((nl = stdoutBuf.indexOf('\n')) >= 0) {
        const line = stdoutBuf.slice(0, nl).trim()
        stdoutBuf = stdoutBuf.slice(nl + 1)
        if (line) handleJsonLine(line)
      }
    })

    child.stderr?.on('data', (chunk: Buffer) => {
      stderrText += chunk.toString('utf8')
      if (stderrText.length > 2000) stderrText = stderrText.slice(-2000)
    })

    child.on('exit', (code) => {
      if (stdoutBuf.trim()) handleJsonLine(stdoutBuf.trim())
      if (accText || accThinking) {
        rt!.localMessages.push({
          seq: rt!.localMessages.length + 1,
          role: 'assistant',
          text: accText,
          thinking: accThinking,
          time: Date.now(),
        })
      }
      rt!.isNew = false
      rt!.running = false
      rt!.activeChild = null
      rt!.updatedAt = Date.now()
      const fp = this.locateSessionFile(rawId)
      if (fp) rt!.filePath = fp
      const hadErr = code !== 0 && code !== null && !accText
      if (hadErr) {
        const hint = stderrText.trim().slice(0, 260) || `Claude Code 退出码 ${String(code)}`
        this.emit(rawId, { type: 'error', error: hint, running: false })
      }
      this.emit(rawId, { type: 'done', running: false })
      this.emitNotify(rawId, 'done', hadErr ? 'error' : 'completed')
    })

    child.on('error', (err) => {
      rt!.running = false
      rt!.activeChild = null
      this.emit(rawId, { type: 'error', error: err.message, running: false })
      this.emit(rawId, { type: 'done', running: false })
      this.emitNotify(rawId, 'done', 'error')
    })

    return { ok: true, runId: `cl-${Date.now()}`, status: 'started' }
  }

  async abort(rawId: string): Promise<boolean> {
    const rt = this.runtime.get(rawId)
    if (rt?.activeChild) {
      killProcessTree(rt.activeChild)
      rt.activeChild = null
    }
    if (rt) {
      rt.running = false
      this.emit(rawId, { type: 'done', running: false })
      this.emitNotify(rawId, 'done', 'interrupted')
    }
    return true
  }

  subscribe(rawId: string, listener: (ev: BackendStreamEvent) => void): () => void {
    let set = this.listeners.get(rawId)
    if (!set) {
      set = new Set()
      this.listeners.set(rawId, set)
    }
    set.add(listener)
    return () => {
      const s = this.listeners.get(rawId)
      if (!s) return
      s.delete(listener)
      if (s.size === 0) this.listeners.delete(rawId)
    }
  }

  getAsk(_rawId: string): BackendAskState {
    return { pending: null }
  }

  async answerAsk(_rawId: string, _askId: string, _answers: Record<string, string>): Promise<boolean> {
    return false
  }

  async listModels(): Promise<BackendModelOption[]> {
    return DEFAULT_CLAUDE_MODELS
  }

  async setModel(rawId: string, model: string): Promise<boolean> {
    const rt = this.runtime.get(rawId)
    if (rt) rt.model = model.trim()
    return true
  }

  isRunning(rawId: string): boolean {
    return this.runtime.get(rawId)?.running === true
  }

  dispose(): void {
    for (const rt of this.runtime.values()) {
      if (rt.activeChild) {
        killProcessTree(rt.activeChild)
        rt.activeChild = null
      }
    }
    this.runtime.clear()
    this.listeners.clear()
  }
}
