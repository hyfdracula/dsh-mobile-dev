/**
 * 通用 ACP 会话后端基类：
 * 统一实现基于 ACP（JSON-RPC 2.0 over stdio）的探测、会话列表、历史重放、流式增量、
 * 工具审批、模型切换（当后端能力支持时）与安全中断。
 */
import { randomUUID } from 'node:crypto'
import { homedir } from 'node:os'
import type { ChatMessage, ToolTrace } from '../transcript.ts'
import { AcpClient, type AcpPermissionRequest, type AcpSessionUpdate } from './acp-client.ts'
import { probeCliVersion, validateWorkingDir, type ResolvedCli } from './process-util.ts'
import {
  formatSessionId,
  type AgentBackend,
  type BackendAskOption,
  type BackendAskState,
  type BackendCapabilities,
  type BackendId,
  type BackendImageInput,
  type BackendMessagesResult,
  type BackendModelOption,
  type BackendNotifyEvent,
  type BackendPendingAsk,
  type BackendProbeResult,
  type BackendSessionRow,
  type BackendStreamEvent,
} from './types.ts'

export interface AcpSessionCache {
  rawId: string
  title: string
  cwd: string
  updatedAt: number
  model: string
  messages: ChatMessage[]
  loaded: boolean
  boundToProcess: boolean
  running: boolean
  activeAssistant: ChatMessage | null
  pendingAsk: { ask: BackendPendingAsk; rpcId: number | string; optionIds: string[] } | null
}

export interface AcpCliSpec {
  cli: ResolvedCli
  args: string[]
}

export abstract class AcpSessionBackend implements AgentBackend {
  abstract readonly id: BackendId
  abstract readonly label: string
  abstract readonly capabilities: BackendCapabilities

  protected client: AcpClient | null = null
  private resolvedSpec: AcpCliSpec | null = null
  protected readonly sessions = new Map<string, AcpSessionCache>()
  private readonly listeners = new Map<string, Set<(ev: BackendStreamEvent) => void>>()
  private readonly replayingSessions = new Set<string>()
  private readonly inflightLoads = new Map<string, Promise<void>>()
  private loadChain: Promise<void> = Promise.resolve()
  protected cachedModels: BackendModelOption[] = []
  private inflightList: Promise<Array<Record<string, unknown>>> | null = null
  private inflightModels: Promise<BackendModelOption[]> | null = null
  private notifyHook: ((ev: BackendNotifyEvent) => void) | null = null

  setNotifyHook(fn: ((ev: BackendNotifyEvent) => void) | null): void {
    this.notifyHook = fn
  }

  private emitNotify(rawId: string, kind: 'done' | 'asking', status?: string): void {
    if (!this.notifyHook) return
    const title = this.sessions.get(rawId)?.title || this.defaultSessionTitle(false)
    try {
      this.notifyHook({ sessionId: formatSessionId(this.id, rawId), title, kind, status })
    } catch {
      // isolate notify listener errors
    }
  }

  protected abstract resolveSpec(force?: boolean): AcpCliSpec | null
  protected abstract missingCliMessage(): string

  protected autoInitForList(): boolean {
    return false
  }

  protected async listViaCliFallback(_limit: number): Promise<Array<Record<string, unknown>>> {
    return []
  }

  protected async listModelsViaCliFallback(): Promise<BackendModelOption[]> {
    return []
  }

  protected normalizeSessionCwd(raw: string): string {
    let trimmed = raw.trim()
    if (!trimmed) return homedir()
    if (trimmed.includes('%')) {
      try {
        trimmed = decodeURIComponent(trimmed)
      } catch {
        // keep raw path when percent sequence is malformed
      }
    }
    if (process.platform === 'win32') {
      const m = /^\/([A-Za-z]:[\\/].*)$/.exec(trimmed)
      if (m) {
        const winPath = m[1].replace(/\//g, '\\')
        return winPath.charAt(0).toUpperCase() + winPath.slice(1)
      }
    }
    return trimmed
  }

  protected ensureSpec(force = false): AcpCliSpec | null {
    if (!force && this.resolvedSpec) return this.resolvedSpec
    this.resolvedSpec = this.resolveSpec(force)
    return this.resolvedSpec
  }

  protected ensureClient(): AcpClient {
    if (this.client) return this.client
    const spec = this.ensureSpec()
    if (!spec) {
      throw new Error(this.missingCliMessage())
    }
    this.client = new AcpClient(spec.cli, spec.args, homedir(), {
      onSessionUpdate: (ev) => this.handleUpdate(ev),
      onPermissionRequest: (req) => this.handlePermission(req),
      onClose: () => {
        for (const s of this.sessions.values()) {
          // 进程退出后需要重新 bind 到新子进程，但保留已拉取的历史消息缓存，不丢失聊天记录
          s.boundToProcess = false
          if (s.running) {
            s.running = false
            this.emit(s.rawId, { type: 'done', running: false })
            this.emitNotify(s.rawId, 'done', 'interrupted')
          }
          if (s.pendingAsk) {
            s.pendingAsk = null
            this.emit(s.rawId, { type: 'ask', asking: false, ask: null })
          }
        }
      },
    })
    return this.client
  }

  protected defaultSessionTitle(isNew = false): string {
    return isNew ? `${this.label} 新会话` : `${this.label} 会话`
  }

  protected getOrCreateCache(rawId: string, cwd?: string, title?: string): AcpSessionCache {
    let s = this.sessions.get(rawId)
    if (!s) {
      s = {
        rawId,
        title: title && title.trim() !== '' ? title.trim() : this.defaultSessionTitle(false),
        cwd: cwd || homedir(),
        updatedAt: Date.now(),
        model: '',
        messages: [],
        loaded: false,
        boundToProcess: false,
        running: false,
        activeAssistant: null,
        pendingAsk: null,
      }
      this.sessions.set(rawId, s)
    } else {
      if (cwd && cwd.trim() !== '') s.cwd = cwd
      if (title && title.trim() !== '') s.title = title.trim()
    }
    return s
  }

  protected emit(rawId: string, ev: BackendStreamEvent): void {
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

  private ensureActiveAssistant(s: AcpSessionCache): ChatMessage {
    if (!s.activeAssistant) {
      const m: ChatMessage = {
        seq: s.messages.length + 1,
        role: 'assistant',
        text: '',
        thinking: '',
        tools: [],
        time: Date.now(),
      }
      s.messages.push(m)
      s.activeAssistant = m
    }
    return s.activeAssistant
  }

  private extractChunkText(update: Record<string, unknown>): string {
    const content = update.content
    if (typeof content === 'string') return content
    if (content && typeof content === 'object') {
      const c = content as Record<string, unknown>
      if (typeof c.text === 'string') return c.text
    }
    if (typeof update.text === 'string') return update.text
    return ''
  }

  private captureModelsMetadata(cache: AcpSessionCache, raw: Record<string, unknown>): void {
    if (typeof raw.model === 'string' && raw.model.trim() !== '') {
      cache.model = raw.model.trim()
    }
    if (raw.models && typeof raw.models === 'object') {
      const m = raw.models as Record<string, unknown>
      if (typeof m.currentModelId === 'string' && m.currentModelId.trim() !== '') {
        cache.model = m.currentModelId.trim()
      }
      if (Array.isArray(m.availableModels)) {
        const parsed = m.availableModels
          .filter((x): x is Record<string, unknown> => x !== null && typeof x === 'object')
          .map((x) => ({
            id: String(x.modelId ?? x.id ?? ''),
            name: String(x.name ?? x.modelId ?? x.id ?? ''),
            provider: this.id,
            description: typeof x.description === 'string' ? x.description : undefined,
          }))
          .filter((x) => x.id !== '')
        if (parsed.length > 0) {
          this.cachedModels = parsed
        }
      }
    }
  }

  private handleUpdate(ev: AcpSessionUpdate): void {
    const sid = ev.sessionId || (this.replayingSessions.size === 1 ? [...this.replayingSessions][0] : '')
    if (!sid) return
    const s = this.getOrCreateCache(sid)
    const u = ev.update
    const kind = typeof u.sessionUpdate === 'string' ? u.sessionUpdate : ''
    const isReplay = this.replayingSessions.has(sid)

    if (kind === 'user_message_chunk') {
      const txt = this.extractChunkText(u)
      if (!txt) return
      s.activeAssistant = null
      const last = s.messages[s.messages.length - 1]
      if (isReplay && last && last.role === 'user') {
        last.text += txt
      } else {
        s.messages.push({
          seq: s.messages.length + 1,
          role: 'user',
          text: txt,
          time: Date.now(),
        })
      }
      return
    }

    if (kind === 'agent_thought_chunk') {
      const delta = this.extractChunkText(u)
      if (!delta) return
      const a = this.ensureActiveAssistant(s)
      a.thinking = (a.thinking ?? '') + delta
      s.updatedAt = Date.now()
      if (!isReplay) {
        this.emit(sid, { type: 'thinking', thinking: delta, running: true })
      }
      return
    }

    if (kind === 'agent_message_chunk') {
      const delta = this.extractChunkText(u)
      if (!delta) return
      const a = this.ensureActiveAssistant(s)
      a.text += delta
      s.updatedAt = Date.now()
      if (!isReplay) {
        this.emit(sid, { type: 'delta', text: delta, running: true })
      }
      return
    }

    if (kind === 'tool_call' || kind === 'tool_call_update') {
      const a = this.ensureActiveAssistant(s)
      if (!a.tools) a.tools = []
      const callId = typeof u.toolCallId === 'string' ? u.toolCallId : `tool-${a.tools.length}`
      const name =
        typeof u.title === 'string' && u.title.trim() !== ''
          ? u.title
          : typeof u.kind === 'string'
            ? u.kind
            : 'tool'
      const rawStatus = typeof u.status === 'string' ? u.status : ''
      const status: 'running' | 'done' | 'error' =
        rawStatus === 'failed' || rawStatus === 'error'
          ? 'error'
          : rawStatus === 'completed' || rawStatus === 'done'
            ? 'done'
            : 'running'
      let existing: ToolTrace | undefined = a.tools.find((t) => t.id === callId)
      const inputStr = u.rawInput !== undefined ? JSON.stringify(u.rawInput).slice(0, 200) : ''
      const outStr = u.rawOutput !== undefined ? JSON.stringify(u.rawOutput).slice(0, 200) : ''
      const summary = inputStr || outStr || name
      const traceStatus: 'ok' | 'err' | 'run' = status === 'error' ? 'err' : status === 'done' ? 'ok' : 'run'
      if (!existing) {
        existing = {
          id: callId,
          name,
          summary,
          status: traceStatus,
        }
        a.tools.push(existing)
      } else {
        if (name && name !== 'tool') existing.name = name
        if (summary) existing.summary = summary
        existing.status = traceStatus
      }
      if (!isReplay) {
        this.emit(sid, {
          type: 'tool',
          toolId: callId,
          toolName: existing.name,
          toolInput: inputStr,
          toolOutput: outStr,
          toolStatus: status,
          running: true,
        })
      }
    }
  }

  protected autoApprovePermissions(): boolean {
    return false
  }

  private pickAutoApproveOptionId(req: AcpPermissionRequest): string {
    const opts = req.options
    const allowAlways = opts.find((o) => o.kind === 'allow_always')
    if (allowAlways) return allowAlways.optionId
    const allowOnce = opts.find((o) => o.kind === 'allow_once')
    if (allowOnce) return allowOnce.optionId
    const allowAny = opts.find((o) => typeof o.kind === 'string' && o.kind.toLowerCase().includes('allow'))
    if (allowAny) return allowAny.optionId
    const nonReject = opts.find(
      (o) => !(typeof o.kind === 'string' && o.kind.toLowerCase().includes('reject'))
        && !o.name.toLowerCase().includes('reject')
        && !o.name.toLowerCase().includes('deny')
        && !o.name.includes('拒绝'),
    )
    if (nonReject) return nonReject.optionId
    return opts[0]?.optionId ?? 'allow'
  }

  private handlePermission(req: AcpPermissionRequest): void {
    const sid = req.sessionId
    if (!sid) {
      this.client?.replyPermission(req.rpcId, null)
      return
    }
    if (this.autoApprovePermissions()) {
      const chosen = this.pickAutoApproveOptionId(req)
      this.client?.replyPermission(req.rpcId, chosen)
      return
    }
    const s = this.getOrCreateCache(sid)
    const askId = `${this.id}-ask-${randomUUID().slice(0, 8)}`
    const opts: BackendAskOption[] = req.options.map((o) => ({
      label: o.name,
      description: o.kind ?? '',
      value: o.optionId,
    }))
    if (opts.length === 0) {
      opts.push({ label: '允许', value: 'allow' }, { label: '拒绝', value: '' })
    }
    const inputPreview =
      req.rawInput !== undefined ? `\n${JSON.stringify(req.rawInput).slice(0, 260)}` : ''
    const ask: BackendPendingAsk = {
      askId,
      sessionId: formatSessionId(this.id, sid),
      createdAt: Date.now(),
      questions: [
        {
          header: `${this.label} 权限审批`,
          question: `${req.title}${inputPreview}`,
          multiSelect: false,
          options: opts,
        },
      ],
    }
    s.pendingAsk = {
      ask,
      rpcId: req.rpcId,
      optionIds: opts.map((o) => o.value ?? ''),
    }
    this.emit(sid, { type: 'ask', asking: true, ask })
    this.emitNotify(sid, 'asking')
  }

  async probe(force = false): Promise<BackendProbeResult> {
    const spec = this.ensureSpec(force)
    if (!spec) {
      return { installed: false, version: '', binaryPath: '', error: this.missingCliMessage() }
    }
    const version = await probeCliVersion(spec.cli, force)
    return { installed: true, version: version || 'installed', binaryPath: spec.cli.displayPath }
  }

  private async fetchAcpSessions(): Promise<Array<Record<string, unknown>>> {
    if (this.inflightList) return await this.inflightList
    const p = (async (): Promise<Array<Record<string, unknown>>> => {
      try {
        const client = this.client ?? (this.autoInitForList() && this.ensureSpec() ? this.ensureClient() : null)
        if (!client) return []
        return await client.listSessions()
      } catch {
        return []
      } finally {
        this.inflightList = null
      }
    })()
    this.inflightList = p
    return await p
  }

  async listSessions(limit = 40): Promise<BackendSessionRow[]> {
    let rawList: Array<Record<string, unknown>> = []
    if (this.client) {
      rawList = await this.fetchAcpSessions()
    }
    if (rawList.length === 0) {
      rawList = await this.listViaCliFallback(limit)
    }
    if (rawList.length === 0 && !this.client && this.autoInitForList()) {
      rawList = await this.fetchAcpSessions()
    }

    const rows: BackendSessionRow[] = []
    const seen = new Set<string>()
    for (const item of rawList) {
      const rawId =
        typeof item.sessionId === 'string'
          ? item.sessionId
          : typeof item.id === 'string'
            ? item.id
            : ''
      if (!rawId || seen.has(rawId)) continue
      seen.add(rawId)
      const title =
        typeof item.title === 'string' && item.title.trim() !== ''
          ? item.title.trim()
          : this.defaultSessionTitle(false)
      const cwdRaw =
        typeof item.cwd === 'string'
          ? item.cwd
          : typeof item.directory === 'string'
            ? item.directory
            : homedir()
      const cwd = this.normalizeSessionCwd(cwdRaw)
      const updatedRaw = item.updatedAt ?? item.updated ?? item.created
      const parsedUpdatedAt =
        typeof updatedRaw === 'number'
          ? updatedRaw
          : typeof updatedRaw === 'string'
            ? Date.parse(updatedRaw) || 0
            : 0
      const cache = this.getOrCreateCache(rawId, cwd, title)
      if (parsedUpdatedAt > 0) cache.updatedAt = parsedUpdatedAt
      rows.push({
        id: formatSessionId(this.id, rawId),
        rawId,
        backend: this.id,
        title: cache.title,
        cwd: cache.cwd,
        updatedAt: cache.updatedAt,
        running: cache.running,
        asking: cache.pendingAsk !== null,
        model: cache.model ? { provider: this.id, model: cache.model, reasoningEffort: '' } : null,
      })
    }

    for (const cache of this.sessions.values()) {
      if (seen.has(cache.rawId)) continue
      rows.push({
        id: formatSessionId(this.id, cache.rawId),
        rawId: cache.rawId,
        backend: this.id,
        title: cache.title,
        cwd: cache.cwd,
        updatedAt: cache.updatedAt,
        running: cache.running,
        asking: cache.pendingAsk !== null,
        model: cache.model ? { provider: this.id, model: cache.model, reasoningEffort: '' } : null,
      })
    }

    rows.sort((a, b) => b.updatedAt - a.updatedAt)
    return rows.slice(0, limit)
  }

  private async loadHistoryOnce(rawId: string, cache: AcpSessionCache): Promise<void> {
    if (cache.loaded || cache.running) return
    const existing = this.inflightLoads.get(rawId)
    if (existing) {
      await existing
      return
    }
    const run = async (): Promise<void> => {
      if (cache.loaded || cache.running) return
      const client = this.ensureClient()
      const prevMessages = cache.messages.slice()
      cache.messages = []
      cache.activeAssistant = null
      this.replayingSessions.add(rawId)
      try {
        const res = await client.loadSession(rawId, cache.cwd)
        this.captureModelsMetadata(cache, res)
        cache.boundToProcess = true
        if (cache.messages.length === 0 && prevMessages.length > 0) {
          cache.messages = prevMessages
        }
        // 仅在 session/load 真正成功时标记历史已加载（禁止用不重放历史的 resumeSession 锁死空缓存）
        cache.loaded = true
      } catch {
        if (cache.messages.length === 0 && prevMessages.length > 0) {
          cache.messages = prevMessages
        }
        // 仅尝试绑定会话以便后续发送，但不标记 history loaded（避免永久返回空历史）
        try {
          const res = await client.resumeSession(rawId, cache.cwd)
          this.captureModelsMetadata(cache, res)
          cache.boundToProcess = true
        } catch {
          // 下次打开或发送时可重试
        }
      } finally {
        this.replayingSessions.delete(rawId)
        cache.activeAssistant = null
      }
    }

    // 串行化 session/load，避免列表并发预拉把 ACP 子进程打爆或互相踩空
    let releaseQueue: () => void = () => {}
    const prevChain = this.loadChain
    this.loadChain = new Promise<void>((resolve) => {
      releaseQueue = resolve
    })
    let task!: Promise<void>
    task = (async (): Promise<void> => {
      await prevChain
      try {
        await run()
      } finally {
        releaseQueue()
        if (this.inflightLoads.get(rawId) === task) {
          this.inflightLoads.delete(rawId)
        }
      }
    })()
    this.inflightLoads.set(rawId, task)
    await task
  }

  private async ensureSessionBound(rawId: string, cache: AcpSessionCache): Promise<void> {
    if (cache.boundToProcess) return
    const client = this.ensureClient()
    if (!cache.loaded) {
      await this.loadHistoryOnce(rawId, cache)
      if (cache.boundToProcess) return
    }
    try {
      const res = await client.resumeSession(rawId, cache.cwd)
      this.captureModelsMetadata(cache, res)
      cache.boundToProcess = true
      return
    } catch {
      // resumeSession 不可用时退回 loadSession，保留已有历史
    }
    const prevMessages = cache.messages.slice()
    this.replayingSessions.add(rawId)
    try {
      cache.messages = []
      cache.activeAssistant = null
      const res = await client.loadSession(rawId, cache.cwd)
      this.captureModelsMetadata(cache, res)
      cache.boundToProcess = true
      if (cache.messages.length === 0 && prevMessages.length > 0) {
        cache.messages = prevMessages
      }
      if (cache.messages.length > 0) {
        cache.loaded = true
      }
    } finally {
      this.replayingSessions.delete(rawId)
      cache.activeAssistant = null
    }
  }

  async getMessages(
    rawId: string,
    opts?: { limit?: number; offset?: number; compact?: boolean },
  ): Promise<BackendMessagesResult> {
    const cache = this.getOrCreateCache(rawId)
    // 后台列表巡检（limit=1 & compact=true）绝不对未加载的空闲会话触发重型 session/load 风暴
    const isLightPreviewProbe = opts?.compact === true && opts?.limit === 1
    if (!cache.loaded && !cache.running && !isLightPreviewProbe) {
      await this.loadHistoryOnce(rawId, cache)
    }
    const all = cache.messages
    const lim = opts?.limit && opts.limit > 0 ? opts.limit : all.length
    const start = Math.max(0, all.length - lim)
    return {
      messages: all.slice(start),
      total: all.length,
      hasMore: start > 0,
      model: cache.model || undefined,
      cwd: cache.cwd,
      running: cache.running,
      asking: cache.pendingAsk !== null,
    }
  }

  async createSession(cwd: string, opts?: { title?: string; model?: string }): Promise<BackendSessionRow> {
    const safeCwd = validateWorkingDir(cwd, true)
    const client = this.ensureClient()
    const { sessionId, raw } = await client.newSession(safeCwd)
    const cache = this.getOrCreateCache(sessionId, safeCwd, opts?.title || this.defaultSessionTitle(true))
    cache.loaded = true
    cache.boundToProcess = true
    cache.updatedAt = Date.now()
    this.captureModelsMetadata(cache, raw)
    if (opts?.model && opts.model.trim() !== '' && this.capabilities.modelSwitch) {
      try {
        const switched = await client.setModel(sessionId, opts.model.trim())
        if (switched) cache.model = opts.model.trim()
      } catch {
        // ignore optional initial model override error
      }
    }
    return {
      id: formatSessionId(this.id, sessionId),
      rawId: sessionId,
      backend: this.id,
      title: cache.title,
      cwd: cache.cwd,
      updatedAt: cache.updatedAt,
      running: false,
      asking: false,
      model: cache.model ? { provider: this.id, model: cache.model, reasoningEffort: '' } : null,
    }
  }

  async sendMessage(
    rawId: string,
    text: string,
    opts?: { images?: BackendImageInput[]; model?: string; cwd?: string },
  ): Promise<{ ok: boolean; runId?: string; status?: string }> {
    const cache = this.getOrCreateCache(rawId, opts?.cwd)
    if (cache.running) {
      throw new Error(`${this.label} 当前会话正在运行，请等待完成或先中断`)
    }
    const client = this.ensureClient()
    await this.ensureSessionBound(rawId, cache)
    if (opts?.model && opts.model.trim() !== '' && opts.model.trim() !== cache.model && this.capabilities.modelSwitch) {
      try {
        const switched = await client.setModel(rawId, opts.model.trim())
        if (switched) cache.model = opts.model.trim()
      } catch {
        // ignore unsupported model switch during turn
      }
    }

    const promptBlocks: Array<Record<string, unknown>> = []
    if (text.trim() !== '') {
      promptBlocks.push({ type: 'text', text })
    }
    if (opts?.images && opts.images.length > 0) {
      for (const img of opts.images) {
        promptBlocks.push({
          type: 'image',
          mimeType: img.mime || 'image/jpeg',
          data: img.data,
        })
      }
    }
    if (promptBlocks.length === 0) {
      throw new Error('消息内容不能为空')
    }

    const runId = `${this.id}-${Date.now()}`
    cache.messages.push({
      seq: cache.messages.length + 1,
      role: 'user',
      text,
      time: Date.now(),
    })
    if (cache.title === this.defaultSessionTitle(true) || cache.title === this.defaultSessionTitle(false)) {
      cache.title = text.trim().slice(0, 36) || cache.title
    }
    cache.activeAssistant = null
    cache.running = true
    cache.updatedAt = Date.now()
    this.emit(rawId, { type: 'status', running: true })

    const runPrompt = async (): Promise<void> => {
      try {
        await client.prompt(rawId, promptBlocks)
      } catch (firstErr) {
        const msg1 = firstErr instanceof Error ? firstErr.message : String(firstErr)
        // 若因 ACP 子进程刚重启或会话未绑定导致失败，自动重新绑定会话并重试一次
        const retriable =
          !cache.activeAssistant
          && (/not\s+found|not\s+loaded|unknown\s+session|exited|closed|stdin/i.test(msg1))
        if (!retriable) {
          throw firstErr
        }
        cache.boundToProcess = false
        await this.ensureSessionBound(rawId, cache)
        await this.ensureClient().prompt(rawId, promptBlocks)
      }
    }

    void runPrompt()
      .then(() => {
        cache.running = false
        cache.activeAssistant = null
        cache.updatedAt = Date.now()
        this.emit(rawId, { type: 'done', running: false })
        this.emitNotify(rawId, 'done', 'completed')
      })
      .catch((err) => {
        cache.running = false
        const msg = err instanceof Error ? err.message : String(err)
        // 把真实失败原因写进消息流，避免手机轮询时静默无回复
        const a = this.ensureActiveAssistant(cache)
        const notice = `[${this.label} 执行中断] ${msg}`
        a.text = a.text.trim() !== '' ? `${a.text}\n\n${notice}` : notice
        cache.activeAssistant = null
        cache.updatedAt = Date.now()
        this.emit(rawId, { type: 'error', error: msg, running: false })
        this.emit(rawId, { type: 'done', running: false })
        this.emitNotify(rawId, 'done', 'error')
      })

    return { ok: true, runId, status: 'started' }
  }

  async abort(rawId: string): Promise<boolean> {
    const cache = this.sessions.get(rawId)
    if (this.client) {
      this.client.cancel(rawId)
    }
    if (cache) {
      if (cache.pendingAsk) {
        this.client?.replyPermission(cache.pendingAsk.rpcId, null)
        cache.pendingAsk = null
        this.emit(rawId, { type: 'ask', asking: false, ask: null })
      }
      cache.running = false
      cache.activeAssistant = null
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
    const s = this.sessions.get(rawId)
    return { pending: s?.pendingAsk?.ask ?? null }
  }

  async answerAsk(rawId: string, askId: string, answers: Record<string, string>): Promise<boolean> {
    const s = this.sessions.get(rawId)
    if (!s?.pendingAsk) return false
    if (askId && s.pendingAsk.ask.askId !== askId) return false
    const pending = s.pendingAsk
    s.pendingAsk = null
    const chosenLabel = Object.values(answers)[0] ?? ''
    const q = pending.ask.questions[0]
    let chosenOptionId: string | null = null
    if (q) {
      const idx = q.options.findIndex((o) => o.label === chosenLabel || o.value === chosenLabel)
      if (idx >= 0) {
        const oid = pending.optionIds[idx]
        chosenOptionId = oid && oid.trim() !== '' ? oid : null
      }
    }
    this.client?.replyPermission(pending.rpcId, chosenOptionId)
    this.emit(rawId, { type: 'ask', asking: false, ask: null })
    return true
  }

  async listModels(): Promise<BackendModelOption[]> {
    if (this.cachedModels.length > 0) return this.cachedModels
    if (this.inflightModels) return await this.inflightModels
    const p = (async (): Promise<BackendModelOption[]> => {
      try {
        const list = await this.listModelsViaCliFallback()
        if (list.length > 0) {
          this.cachedModels = list
        }
        return this.cachedModels
      } catch {
        return this.cachedModels
      } finally {
        this.inflightModels = null
      }
    })()
    this.inflightModels = p
    return await p
  }

  async setModel(rawId: string, model: string): Promise<boolean> {
    if (!this.capabilities.modelSwitch) return false
    const client = this.ensureClient()
    const cache = this.getOrCreateCache(rawId)
    if (!cache.loaded) {
      await this.getMessages(rawId, { limit: 1 })
    }
    const ok = await client.setModel(rawId, model)
    if (ok) {
      cache.model = model
    }
    return ok
  }

  isRunning(rawId: string): boolean {
    return this.sessions.get(rawId)?.running === true
  }

  dispose(): void {
    this.client?.dispose()
    this.client = null
    this.inflightList = null
    this.inflightModels = null
    this.cachedModels = []
    this.sessions.clear()
    this.listeners.clear()
  }
}
