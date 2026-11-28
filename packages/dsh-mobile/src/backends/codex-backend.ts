/**
 * Codex 原生后端适配器（基于 `codex app-server` JSON-RPC over stdio）：
 * - 完整支持发现本机 Codex 会话（`thread/list`）、加载历史（`thread/read`）、新建（`thread/start`）、
 *   续聊（`thread/resume` + `turn/start`）、实时流式增量、工具/文件修改审批与中断（`turn/interrupt`）；
 * - 独立管理单常驻 `codex app-server` 子进程，带 15 分钟空闲自动回收与 Windows 进程树强杀。
 */
import type { ChildProcess } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import {
  applyTaskToolCall,
  cloneTaskSteps,
  parseChecklistMarkdown,
  parseTaskStepArray,
  type TaskStep,
} from '../task-steps.ts'
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
  type BackendAskOption,
  type BackendAskState,
  type BackendCapabilities,
  type BackendImageInput,
  type BackendMessagesResult,
  type BackendModelOption,
  type BackendNotifyEvent,
  type BackendPendingAsk,
  type BackendProbeResult,
  type BackendSessionRow,
  type BackendStreamEvent,
} from './types.ts'

export const CODEX_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: true,
  abort: true,
  images: true,
  files: false,
  modelSwitch: true,
  reasoningEffort: true,
  planMode: false,
  goalMode: false,
  compact: false,
  fork: false,
  archivePin: false,
  webConsole: false,
}

interface PendingRpc {
  resolve: (val: unknown) => void
  reject: (err: Error) => void
  timer: ReturnType<typeof setTimeout>
}

interface CodexRuntimeSession {
  rawId: string
  cwd: string
  model: string
  title: string
  updatedAt: number
  loaded: boolean
  running: boolean
  activeTurnId: string
  liveAssistant: ChatMessage | null
  tasks: TaskStep[]
  pendingAsk: { ask: BackendPendingAsk; rpcId: number | string; method: string } | null
}

const IDLE_TTL_MS = 15 * 60 * 1000

function tsMs(raw: unknown): number {
  if (typeof raw !== 'number' || !Number.isFinite(raw) || raw <= 0) return 0
  return raw > 1e12 ? raw : Math.round(raw * 1000)
}

function extractTextFromContent(content: unknown): string {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  const parts: string[] = []
  for (const item of content) {
    if (typeof item === 'string') {
      parts.push(item)
    } else if (item && typeof item === 'object') {
      const o = item as Record<string, unknown>
      if (typeof o.text === 'string') parts.push(o.text)
    }
  }
  return parts.join('\n')
}

function mapTurnsToMessages(turns: unknown, fallbackTime: number): { messages: ChatMessage[]; tasks: TaskStep[] } {
  if (!Array.isArray(turns)) return { messages: [], tasks: [] }
  const out: ChatMessage[] = []
  let tasks: TaskStep[] = []
  let seq = 0
  for (const t of turns) {
    if (!t || typeof t !== 'object') continue
    const turnObj = t as Record<string, unknown>
    const items = Array.isArray(turnObj.items) ? turnObj.items : []
    let curAssistant: ChatMessage | null = null

    const ensureA = (): ChatMessage => {
      if (!curAssistant) {
        curAssistant = {
          seq: ++seq,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
          time: fallbackTime,
        }
        out.push(curAssistant)
      }
      return curAssistant
    }

    for (const rawItem of items) {
      if (!rawItem || typeof rawItem !== 'object') continue
      const item = rawItem as Record<string, unknown>
      const typ = typeof item.type === 'string' ? item.type : ''

      if (typ === 'userMessage') {
        curAssistant = null
        const txt = extractTextFromContent(item.content) || (typeof item.text === 'string' ? item.text : '')
        if (txt.trim() !== '') {
          out.push({
            seq: ++seq,
            role: 'user',
            text: txt,
            time: fallbackTime,
          })
        }
        continue
      }

      if (typ === 'agentMessage') {
        const a = ensureA()
        const txt = typeof item.text === 'string' ? item.text : extractTextFromContent(item.content)
        if (txt) {
          a.text = a.text ? `${a.text}\n${txt}` : txt
        }
        continue
      }

      if (typ === 'reasoning') {
        const a = ensureA()
        const summary = Array.isArray(item.summary)
          ? item.summary.map((x) => (typeof x === 'string' ? x : extractTextFromContent(x))).filter(Boolean).join('\n')
          : typeof item.summary === 'string'
            ? item.summary
            : ''
        const body = extractTextFromContent(item.content)
        const combined = [summary, body].filter(Boolean).join('\n')
        if (combined) {
          a.thinking = a.thinking ? `${a.thinking}\n${combined}` : combined
        }
        continue
      }

      if (typ === 'commandExecution') {
        const a = ensureA()
        if (!a.tools) a.tools = []
        const cmd = typeof item.command === 'string' ? item.command : 'shell'
        const status = typeof item.status === 'string' ? item.status : ''
        const done = status !== 'inProgress' && status !== 'running'
        const ok = status !== 'failed' && status !== 'declined' && (item.exitCode === undefined || item.exitCode === 0)
        const tc: ToolTrace = {
          id: typeof item.id === 'string' ? item.id : `cx-cmd-${seq}`,
          name: 'command',
          summary: cmd.slice(0, 200),
          status: !done ? 'run' : ok ? 'ok' : 'err',
        }
        a.tools.push(tc)
        continue
      }

      if (typ === 'plan') {
        const structured = parseTaskStepArray(item.plan ?? item.steps ?? item.entries ?? item.items)
        if (structured.length > 0) {
          tasks = structured
        } else if (typeof item.text === 'string') {
          const parsedMd = parseChecklistMarkdown(item.text)
          if (parsedMd.length > 0) tasks = parsedMd
        }
        continue
      }

      if (typ === 'fileChange' || typ === 'mcpToolCall' || typ === 'toolCall' || typ === 'webSearch') {
        const a = ensureA()
        if (!a.tools) a.tools = []
        const name =
          typeof item.tool === 'string'
            ? item.tool
            : typeof item.name === 'string'
              ? item.name
              : typ
        const taskMut = applyTaskToolCall(tasks, name, item.arguments)
        if (taskMut.changed) tasks = taskMut.tasks
        const input =
          item.arguments !== undefined
            ? JSON.stringify(item.arguments).slice(0, 200)
            : item.changes !== undefined
              ? JSON.stringify(item.changes).slice(0, 200)
              : typeof item.query === 'string'
                ? item.query.slice(0, 200)
                : name
        const status = typeof item.status === 'string' ? item.status : ''
        const done = status !== 'inProgress' && status !== 'running'
        const ok = status !== 'failed' && status !== 'declined'
        a.tools.push({
          id: typeof item.id === 'string' ? item.id : `cx-t-${seq}`,
          name,
          summary: input,
          status: !done ? 'run' : ok ? 'ok' : 'err',
        })
      }
    }
  }
  return { messages: out, tasks }
}

export class CodexBackend implements AgentBackend {
  readonly id = 'codex' as const
  readonly label = 'Codex'
  readonly capabilities = CODEX_CAPABILITIES

  private cli: ResolvedCli | null = null
  private child: ChildProcess | null = null
  private stdoutBuf = ''
  private nextId = 1
  private readonly pending = new Map<number, PendingRpc>()
  private initPromise: Promise<void> | null = null
  private initialized = false
  private lastActivity = Date.now()
  private idleTimer: ReturnType<typeof setInterval> | null = null
  private readonly runtime = new Map<string, CodexRuntimeSession>()
  private readonly listeners = new Map<string, Set<(ev: BackendStreamEvent) => void>>()
  private modelsCache: { at: number; items: BackendModelOption[] } | null = null
  private notifyHook: ((ev: BackendNotifyEvent) => void) | null = null

  setNotifyHook(fn: ((ev: BackendNotifyEvent) => void) | null): void {
    this.notifyHook = fn
  }

  private emitNotify(rawId: string, kind: 'done' | 'asking', status?: string): void {
    if (!this.notifyHook) return
    const title = this.runtime.get(rawId)?.title || 'Codex 会话'
    try {
      this.notifyHook({ sessionId: formatSessionId(this.id, rawId), title, kind, status })
    } catch {
      // isolate notify listener errors
    }
  }

  private ensureCli(force = false): ResolvedCli | null {
    if (!force && this.cli) return this.cli
    this.cli = resolveCliCommand('codex', force)
    return this.cli
  }

  private getOrCreateRuntime(rawId: string): CodexRuntimeSession {
    let s = this.runtime.get(rawId)
    if (!s) {
      s = {
        rawId,
        cwd: homedir(),
        model: '',
        title: 'Codex 会话',
        updatedAt: 0,
        loaded: false,
        running: false,
        activeTurnId: '',
        liveAssistant: null,
        tasks: [],
        pendingAsk: null,
      }
      this.runtime.set(rawId, s)
    }
    return s
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

  private ensureProcess(): void {
    if (this.child && !this.child.killed && this.child.exitCode === null) return
    const cli = this.ensureCli()
    if (!cli) throw new Error('本机未检测到 codex 命令')
    this.stdoutBuf = ''
    this.initialized = false
    const child = spawnCli(cli, ['app-server'], { cwd: homedir() })
    this.child = child
    this.lastActivity = Date.now()

    child.stdout?.on('data', (chunk: Buffer) => {
      this.lastActivity = Date.now()
      this.stdoutBuf += chunk.toString('utf8')
      let nl: number
      while ((nl = this.stdoutBuf.indexOf('\n')) >= 0) {
        const line = this.stdoutBuf.slice(0, nl).trim()
        this.stdoutBuf = this.stdoutBuf.slice(nl + 1)
        if (!line) continue
        this.handleLine(line)
      }
    })

    child.stderr?.on('data', () => {
      // ignore stderr logs
    })

    child.on('exit', (code, signal) => {
      this.failAllPending(`codex app-server exited (code=${String(code)}, signal=${String(signal)})`)
      this.child = null
      this.initialized = false
      this.initPromise = null
      for (const s of this.runtime.values()) {
        s.loaded = false
        if (s.running) {
          s.running = false
          s.activeTurnId = ''
          s.liveAssistant = null
          this.emit(s.rawId, { type: 'done', running: false })
          this.emitNotify(s.rawId, 'done', 'interrupted')
        }
        if (s.pendingAsk) {
          s.pendingAsk = null
          this.emit(s.rawId, { type: 'ask', asking: false, ask: null })
        }
      }
    })

    child.on('error', (err) => {
      this.failAllPending(err.message)
      this.child = null
      this.initialized = false
      this.initPromise = null
    })

    if (!this.idleTimer) {
      this.idleTimer = setInterval(() => {
        const anyRunning = Array.from(this.runtime.values()).some((s) => s.running)
        if (!anyRunning && this.child && Date.now() - this.lastActivity > IDLE_TTL_MS) {
          this.stopProcess()
        }
      }, 60_000)
      this.idleTimer.unref?.()
    }
  }

  private stopProcess(): void {
    this.failAllPending('codex app-server stopped')
    killProcessTree(this.child)
    this.child = null
    this.initialized = false
    this.initPromise = null
  }

  private failAllPending(reason: string): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer)
      p.reject(new Error(reason))
    }
    this.pending.clear()
  }

  private writeFrame(frame: Record<string, unknown>): void {
    this.ensureProcess()
    if (!this.child?.stdin || this.child.stdin.destroyed) {
      throw new Error('codex app-server stdin 不可写')
    }
    this.lastActivity = Date.now()
    this.child.stdin.write(JSON.stringify(frame) + '\n')
  }

  private async ensureInitialized(): Promise<void> {
    if (this.initialized && this.child && this.child.exitCode === null) return
    if (this.initPromise) return this.initPromise
    this.initPromise = this.rawRequest(
      'initialize',
      { clientInfo: { name: 'dsh-mobile', version: '3.0.0' } },
      15_000,
    )
      .then(() => {
        this.initialized = true
      })
      .catch((err) => {
        this.initPromise = null
        throw err
      })
    return this.initPromise
  }

  private async rawRequest(method: string, params: Record<string, unknown>, timeoutMs = 25_000): Promise<unknown> {
    this.ensureProcess()
    const id = this.nextId++
    return await new Promise<unknown>((resolveReq, rejectReq) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        rejectReq(new Error(`codex RPC timeout: ${method}`))
      }, timeoutMs)
      this.pending.set(id, { resolve: resolveReq, reject: rejectReq, timer })
      try {
        this.writeFrame({ jsonrpc: '2.0', id, method, params })
      } catch (err) {
        clearTimeout(timer)
        this.pending.delete(id)
        rejectReq(err instanceof Error ? err : new Error(String(err)))
      }
    })
  }

  private async request(method: string, params: Record<string, unknown>, timeoutMs = 25_000): Promise<unknown> {
    await this.ensureInitialized()
    return await this.rawRequest(method, params, timeoutMs)
  }

  private handleLine(line: string): void {
    let msg: Record<string, unknown>
    try {
      const parsed = JSON.parse(line)
      if (!parsed || typeof parsed !== 'object') return
      msg = parsed as Record<string, unknown>
    } catch {
      return
    }

    // 1. Response
    if (msg.id !== undefined && msg.method === undefined) {
      const id = Number(msg.id)
      const p = this.pending.get(id)
      if (!p) return
      this.pending.delete(id)
      clearTimeout(p.timer)
      if (msg.error !== undefined && msg.error !== null) {
        const errObj = msg.error as Record<string, unknown>
        p.reject(new Error(typeof errObj.message === 'string' ? errObj.message : JSON.stringify(errObj)))
      } else {
        p.resolve(msg.result)
      }
      return
    }

    // 2. Server -> Client bidirectional approval request
    if (msg.id !== undefined && typeof msg.method === 'string') {
      const rpcId = msg.id as number | string
      const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>
      const threadId = typeof params.threadId === 'string' ? params.threadId : ''
      if (
        msg.method === 'item/commandExecution/requestApproval' ||
        msg.method === 'item/fileChange/requestApproval' ||
        msg.method.endsWith('/requestApproval')
      ) {
        if (!threadId) {
          this.replyApproval(rpcId, 'decline')
          return
        }
        const s = this.getOrCreateRuntime(threadId)
        const askId = `cx-ask-${randomUUID().slice(0, 8)}`
        const isCmd = msg.method.includes('commandExecution')
        const detail =
          typeof params.command === 'string'
            ? params.command
            : typeof params.reason === 'string'
              ? params.reason
              : JSON.stringify(params).slice(0, 260)
        const options: BackendAskOption[] = [
          { label: '允许本次', description: '仅允许这一次操作', value: 'accept' },
          { label: '本会话始终允许', description: '当前会话内同类操作自动放行', value: 'acceptForSession' },
          { label: '拒绝', description: '拒绝此操作', value: 'decline' },
        ]
        const ask: BackendPendingAsk = {
          askId,
          sessionId: formatSessionId('codex', threadId),
          createdAt: Date.now(),
          questions: [
            {
              header: isCmd ? 'Codex 命令审批' : 'Codex 文件修改审批',
              question: detail,
              multiSelect: false,
              options,
            },
          ],
        }
        s.pendingAsk = { ask, rpcId, method: msg.method }
        this.emit(threadId, { type: 'ask', asking: true, ask })
        this.emitNotify(threadId, 'asking')
        return
      }
      try {
        this.writeFrame({
          jsonrpc: '2.0',
          id: rpcId,
          error: { code: -32601, message: `Unsupported method: ${msg.method}` },
        })
      } catch {
        // ignore
      }
      return
    }

    // 3. Notifications
    if (typeof msg.method !== 'string') return
    const params = (msg.params && typeof msg.params === 'object' ? msg.params : {}) as Record<string, unknown>
    const threadId =
      typeof params.threadId === 'string'
        ? params.threadId
        : params.thread && typeof (params.thread as Record<string, unknown>).id === 'string'
          ? String((params.thread as Record<string, unknown>).id)
          : ''
    if (!threadId) return
    const s = this.getOrCreateRuntime(threadId)

    const ensureLiveAssistant = (): ChatMessage => {
      if (!s.liveAssistant) {
        s.liveAssistant = {
          seq: 0,
          role: 'assistant',
          text: '',
          thinking: '',
          tools: [],
          time: Date.now(),
        }
      }
      return s.liveAssistant
    }

    if (msg.method === 'turn/started') {
      const turn = params.turn as Record<string, unknown> | undefined
      s.running = true
      s.activeTurnId = typeof turn?.id === 'string' ? turn.id : (typeof params.turnId === 'string' ? params.turnId : '')
      s.liveAssistant = null
      s.updatedAt = Date.now()
      this.emit(threadId, { type: 'status', running: true })
      return
    }

    if (msg.method === 'item/agentMessage/delta') {
      const delta = typeof params.delta === 'string' ? params.delta : ''
      if (delta) {
        s.updatedAt = Date.now()
        ensureLiveAssistant().text += delta
        this.emit(threadId, { type: 'delta', text: delta, running: true })
      }
      return
    }

    if (msg.method === 'item/reasoning/summaryTextDelta' || msg.method === 'item/reasoning/textDelta') {
      const delta = typeof params.delta === 'string' ? params.delta : ''
      if (delta) {
        s.updatedAt = Date.now()
        const live = ensureLiveAssistant()
        live.thinking = (live.thinking ?? '') + delta
        this.emit(threadId, { type: 'thinking', thinking: delta, running: true })
      }
      return
    }

    if (msg.method === 'turn/plan/updated' || msg.method === 'plan/updated') {
      const parsed = parseTaskStepArray(params.plan ?? params.steps ?? params.entries ?? params.items)
      s.tasks = parsed
      s.updatedAt = Date.now()
      this.emit(threadId, { type: 'tasks', tasks: cloneTaskSteps(s.tasks), running: s.running })
      return
    }

    if (msg.method === 'item/started' || msg.method === 'item/completed') {
      const item = params.item as Record<string, unknown> | undefined
      if (!item) return
      const typ = typeof item.type === 'string' ? item.type : ''
      if (typ === 'plan') {
        const structured = parseTaskStepArray(item.plan ?? item.steps ?? item.entries ?? item.items)
        const nextTasks = structured.length > 0
          ? structured
          : (typeof item.text === 'string' ? parseChecklistMarkdown(item.text) : [])
        if (nextTasks.length > 0) {
          s.tasks = nextTasks
          s.updatedAt = Date.now()
          this.emit(threadId, { type: 'tasks', tasks: cloneTaskSteps(s.tasks), running: s.running })
        }
        return
      }
      if (typ === 'commandExecution' || typ === 'fileChange' || typ === 'mcpToolCall' || typ === 'toolCall') {
        const done = msg.method === 'item/completed'
        const statusRaw = typeof item.status === 'string' ? item.status : ''
        const toolStatus: 'running' | 'done' | 'error' = !done
          ? 'running'
          : statusRaw === 'failed' || statusRaw === 'declined'
            ? 'error'
            : 'done'
        const toolName =
          typ === 'commandExecution'
            ? 'command'
            : typeof item.tool === 'string'
              ? item.tool
              : typeof item.name === 'string'
                ? item.name
                : typ
        const toolInput =
          typeof item.command === 'string'
            ? item.command.slice(0, 400)
            : item.arguments !== undefined
              ? JSON.stringify(item.arguments).slice(0, 400)
              : ''
        const toolOutput =
          typeof item.aggregatedOutput === 'string'
            ? item.aggregatedOutput.slice(0, 1200)
            : typeof item.output === 'string'
              ? item.output.slice(0, 1200)
              : ''
        const live = ensureLiveAssistant()
        if (!live.tools) live.tools = []
        const tid = typeof item.id === 'string' ? item.id : `cx-live-${live.tools.length}`
        const stMapped: ToolTrace['status'] = toolStatus === 'error' ? 'err' : toolStatus === 'done' ? 'ok' : 'run'
        const summary = (toolInput || toolOutput || toolName).slice(0, 200)
        const existing = live.tools.find((t) => t.id === tid)
        if (existing) {
          existing.name = toolName
          if (summary) existing.summary = summary
          existing.status = stMapped
        } else {
          live.tools.push({ id: tid, name: toolName, summary, status: stMapped })
        }
        const taskMut = applyTaskToolCall(s.tasks, toolName, item.arguments)
        if (taskMut.changed) {
          s.tasks = taskMut.tasks
          this.emit(threadId, { type: 'tasks', tasks: cloneTaskSteps(s.tasks), running: true })
        }
        this.emit(threadId, {
          type: 'tool',
          toolId: tid,
          toolName,
          toolInput,
          toolOutput,
          toolStatus,
          running: true,
        })
      }
      return
    }

    if (msg.method === 'turn/completed') {
      s.running = false
      s.activeTurnId = ''
      s.liveAssistant = null
      s.updatedAt = Date.now()
      const turn = params.turn as Record<string, unknown> | undefined
      const errObj = turn?.error as Record<string, unknown> | undefined
      const hasErr = Boolean(errObj && typeof errObj.message === 'string' && errObj.message.trim() !== '')
      if (hasErr) {
        this.emit(threadId, { type: 'error', error: String(errObj!.message), running: false })
      }
      this.emit(threadId, { type: 'done', running: false })
      this.emitNotify(threadId, 'done', hasErr ? 'error' : 'completed')
      return
    }

    if (msg.method === 'error') {
      const errMsg =
        typeof params.message === 'string'
          ? params.message
          : params.error && typeof (params.error as Record<string, unknown>).message === 'string'
            ? String((params.error as Record<string, unknown>).message)
            : 'Codex 运行出错'
      this.emit(threadId, { type: 'error', error: errMsg, running: s.running })
    }
  }

  private replyApproval(rpcId: number | string, decision: string): void {
    try {
      this.writeFrame({
        jsonrpc: '2.0',
        id: rpcId,
        result: { decision },
      })
    } catch {
      // ignore
    }
  }

  async probe(force = false): Promise<BackendProbeResult> {
    const cli = this.ensureCli(force)
    if (!cli) {
      return { installed: false, version: '', binaryPath: '', error: '未检测到 codex 命令' }
    }
    const version = await probeCliVersion(cli, force)
    return { installed: true, version: version || 'installed', binaryPath: cli.displayPath }
  }

  async listSessions(limit = 40): Promise<BackendSessionRow[]> {
    const res = (await this.request('thread/list', { limit }, 15_000)) as Record<string, unknown> | null
    const data = res && Array.isArray(res.data) ? res.data : []
    const rows: BackendSessionRow[] = []
    for (const item of data) {
      if (!item || typeof item !== 'object') continue
      const o = item as Record<string, unknown>
      const rawId = typeof o.id === 'string' ? o.id : ''
      if (!rawId) continue
      const rt = this.getOrCreateRuntime(rawId)
      const nameStr = typeof o.name === 'string' && o.name.trim() !== '' ? o.name.trim() : ''
      const preview = typeof o.preview === 'string' ? o.preview.trim() : ''
      const title = nameStr || preview.slice(0, 48) || 'Codex 会话'
      const cwd = typeof o.cwd === 'string' && o.cwd.trim() !== '' ? o.cwd : homedir()
      const updatedAt = tsMs(o.updatedAt ?? o.createdAt)
      const model = typeof o.model === 'string' ? o.model : ''
      const provider = typeof o.modelProvider === 'string' ? o.modelProvider : 'codex'
      const stObj = o.status as Record<string, unknown> | undefined
      const running = rt.running || stObj?.type === 'active'
      rt.cwd = cwd
      rt.title = title
      if (model) rt.model = model
      if (updatedAt > 0 && (rt.updatedAt === 0 || updatedAt > rt.updatedAt)) {
        rt.updatedAt = updatedAt
      }
      const effectiveUpdatedAt = rt.updatedAt > 0 ? rt.updatedAt : Date.now()
      rows.push({
        id: formatSessionId('codex', rawId),
        rawId,
        backend: 'codex',
        title,
        cwd,
        updatedAt: effectiveUpdatedAt,
        running,
        asking: rt.pendingAsk !== null,
        preview: preview.slice(0, 120),
        model: model ? { provider, model, reasoningEffort: typeof o.reasoningEffort === 'string' ? o.reasoningEffort : '' } : null,
      })
    }
    rows.sort((a, b) => b.updatedAt - a.updatedAt)
    return rows.slice(0, limit)
  }

  async getMessages(
    rawId: string,
    opts?: { limit?: number; offset?: number; compact?: boolean },
  ): Promise<BackendMessagesResult> {
    const rt = this.getOrCreateRuntime(rawId)
    const res = (await this.request(
      'thread/read',
      { threadId: rawId, includeTurns: true },
      20_000,
    )) as Record<string, unknown> | null
    const thread = (res?.thread && typeof res.thread === 'object' ? res.thread : {}) as Record<string, unknown>
    if (typeof thread.cwd === 'string' && thread.cwd) rt.cwd = thread.cwd
    if (typeof thread.model === 'string' && thread.model) rt.model = thread.model
    const updatedAt = tsMs(thread.updatedAt ?? thread.createdAt) || Date.now()
    const mapped = mapTurnsToMessages(thread.turns, updatedAt)
    const all = mapped.messages
    if (!rt.running && mapped.tasks.length > 0) {
      rt.tasks = mapped.tasks
    }
    const tasks = rt.running && rt.tasks.length > 0
      ? cloneTaskSteps(rt.tasks)
      : (mapped.tasks.length > 0 ? mapped.tasks : cloneTaskSteps(rt.tasks))
    // 公网 E2EE 轮询场景下同步拼入运行中增量（正文/思考/工具），避免流式过程空白
    if (rt.running && rt.liveAssistant) {
      const live = rt.liveAssistant
      const tail = all[all.length - 1]
      if (tail && tail.role === 'assistant') {
        if (live.text.length > tail.text.length) tail.text = live.text
        if ((live.thinking?.length ?? 0) > (tail.thinking?.length ?? 0)) tail.thinking = live.thinking
        if ((live.tools?.length ?? 0) > (tail.tools?.length ?? 0)) tail.tools = live.tools?.map((t) => ({ ...t }))
      } else if (live.text || live.thinking || (live.tools && live.tools.length > 0)) {
        all.push({
          ...live,
          seq: all.length + 1,
          tools: live.tools?.map((t) => ({ ...t })),
        })
      }
    }
    const lim = opts?.limit && opts.limit > 0 ? opts.limit : all.length
    const start = Math.max(0, all.length - lim)
    return {
      messages: all.slice(start),
      total: all.length,
      hasMore: start > 0,
      model: rt.model || undefined,
      cwd: rt.cwd,
      running: rt.running,
      asking: rt.pendingAsk !== null,
      tasks,
    }
  }

  async createSession(cwd: string, opts?: { title?: string; model?: string }): Promise<BackendSessionRow> {
    const safeCwd = validateWorkingDir(cwd, true)
    const params: Record<string, unknown> = { cwd: safeCwd }
    if (opts?.model && opts.model.trim() !== '') {
      params.model = opts.model.trim()
    }
    const res = (await this.request('thread/start', params, 20_000)) as Record<string, unknown> | null
    const thread = (res?.thread && typeof res.thread === 'object' ? res.thread : res) as Record<string, unknown>
    const rawId = typeof thread?.id === 'string' ? thread.id : ''
    if (!rawId) throw new Error('Codex thread/start 未返回线程 ID')
    const rt = this.getOrCreateRuntime(rawId)
    rt.cwd = safeCwd
    rt.loaded = true
    rt.title = opts?.title?.trim() || 'Codex 新会话'
    rt.model = typeof thread.model === 'string' ? thread.model : (opts?.model ?? '')
    rt.updatedAt = Date.now()
    return {
      id: formatSessionId('codex', rawId),
      rawId,
      backend: 'codex',
      title: rt.title,
      cwd: rt.cwd,
      updatedAt: rt.updatedAt,
      running: false,
      asking: false,
      model: rt.model ? { provider: 'codex', model: rt.model, reasoningEffort: '' } : null,
    }
  }

  async sendMessage(
    rawId: string,
    text: string,
    opts?: { images?: BackendImageInput[]; model?: string; cwd?: string },
  ): Promise<{ ok: boolean; runId?: string; status?: string }> {
    const rt = this.getOrCreateRuntime(rawId)
    if (opts?.cwd) rt.cwd = opts.cwd
    if (rt.running) {
      throw new Error('Codex 当前会话正在运行，请等待完成或先中断')
    }

    if (!rt.loaded) {
      try {
        await this.request('thread/resume', { threadId: rawId }, 20_000)
        rt.loaded = true
      } catch {
        // 已加载或新创建的 thread 可能无需 resume
        rt.loaded = true
      }
    }

    const input: Array<Record<string, unknown>> = []
    if (text.trim() !== '') {
      input.push({ type: 'text', text })
    }
    if (opts?.images && opts.images.length > 0) {
      for (const img of opts.images) {
        const url = img.data.startsWith('data:') ? img.data : `data:${img.mime || 'image/jpeg'};base64,${img.data}`
        input.push({ type: 'image', url })
      }
    }
    if (input.length === 0) {
      throw new Error('消息内容不能为空')
    }

    const params: Record<string, unknown> = { threadId: rawId, input }
    const wantModel = opts?.model?.trim() || rt.model
    if (wantModel) {
      params.model = wantModel
    }

    rt.running = true
    rt.liveAssistant = null
    rt.updatedAt = Date.now()
    if (rt.title === 'Codex 新会话' || rt.title === 'Codex 会话') {
      rt.title = text.trim().slice(0, 36) || rt.title
    }
    this.emit(rawId, { type: 'status', running: true })

    try {
      const res = (await this.request('turn/start', params, 30_000)) as Record<string, unknown> | null
      const turn = (res?.turn && typeof res.turn === 'object' ? res.turn : {}) as Record<string, unknown>
      if (typeof turn.id === 'string') {
        rt.activeTurnId = turn.id
      }
      return { ok: true, runId: rt.activeTurnId || `cx-${Date.now()}`, status: 'started' }
    } catch (err) {
      rt.running = false
      rt.activeTurnId = ''
      rt.liveAssistant = null
      const msg = err instanceof Error ? err.message : String(err)
      this.emit(rawId, { type: 'error', error: msg, running: false })
      this.emit(rawId, { type: 'done', running: false })
      throw err
    }
  }

  async abort(rawId: string): Promise<boolean> {
    const rt = this.runtime.get(rawId)
    if (rt?.pendingAsk) {
      this.replyApproval(rt.pendingAsk.rpcId, 'cancel')
      rt.pendingAsk = null
      this.emit(rawId, { type: 'ask', asking: false, ask: null })
    }
    try {
      const params: Record<string, unknown> = { threadId: rawId }
      if (rt?.activeTurnId) params.turnId = rt.activeTurnId
      await this.request('turn/interrupt', params, 8_000)
    } catch {
      // ignore if turn already finished
    }
    if (rt) {
      rt.running = false
      rt.activeTurnId = ''
      rt.liveAssistant = null
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

  getAsk(rawId: string): BackendAskState {
    return { pending: this.runtime.get(rawId)?.pendingAsk?.ask ?? null }
  }

  async answerAsk(rawId: string, askId: string, answers: Record<string, string>): Promise<boolean> {
    const rt = this.runtime.get(rawId)
    if (!rt?.pendingAsk) return false
    if (askId && rt.pendingAsk.ask.askId !== askId) return false
    const pending = rt.pendingAsk
    rt.pendingAsk = null
    const chosen = Object.values(answers)[0] ?? ''
    const q = pending.ask.questions[0]
    const matched = q?.options.find((o) => o.label === chosen || o.value === chosen)
    const decision = matched?.value || 'decline'
    this.replyApproval(pending.rpcId, decision)
    this.emit(rawId, { type: 'ask', asking: false, ask: null })
    return true
  }

  async listModels(): Promise<BackendModelOption[]> {
    if (this.modelsCache && Date.now() - this.modelsCache.at < 5 * 60 * 1000) {
      return this.modelsCache.items
    }
    try {
      const res = (await this.request('model/list', {}, 12_000)) as Record<string, unknown> | null
      const data = res && Array.isArray(res.data) ? res.data : []
      const items: BackendModelOption[] = []
      for (const item of data) {
        if (!item || typeof item !== 'object') continue
        const o = item as Record<string, unknown>
        if (o.hidden === true) continue
        const id = typeof o.model === 'string' ? o.model : typeof o.id === 'string' ? o.id : ''
        if (!id) continue
        items.push({
          id,
          name: typeof o.displayName === 'string' && o.displayName ? o.displayName : id,
          provider: 'codex',
          description: typeof o.description === 'string' ? o.description : undefined,
        })
      }
      this.modelsCache = { at: Date.now(), items }
      return items
    } catch {
      return this.modelsCache?.items ?? []
    }
  }

  async setModel(rawId: string, model: string): Promise<boolean> {
    const rt = this.getOrCreateRuntime(rawId)
    rt.model = model.trim()
    return true
  }

  isRunning(rawId: string): boolean {
    return this.runtime.get(rawId)?.running === true
  }

  dispose(): void {
    if (this.idleTimer) {
      clearInterval(this.idleTimer)
      this.idleTimer = null
    }
    this.stopProcess()
    this.runtime.clear()
    this.listeners.clear()
  }
}
