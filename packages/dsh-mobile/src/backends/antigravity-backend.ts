/**
 * Antigravity CLI 后端适配器（基于通用 ACP 引擎驱动 `agy acp` / `agy_acp_server`）：
 * - 按官方白名单顺序探测 `agy` -> `antigravity` -> `agy_acp_server` -> `antigravity-acp`；
 * - 通过 ACP stdio 协议完成会话新建、历史重放、流式增量输出、权限审批与模型切换；
 * - 无私有磁盘结构强依赖，完全遵循 ACP v1 规范。
 */
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { cloneTaskSteps } from '../task-steps.ts'
import { AcpSessionBackend, type AcpCliSpec } from './acp-backend.ts'
import {
  clearAntigravityAborted,
  markAntigravityAborted,
  probeAntigravityDiskActivity,
  readAntigravitySessionIndex,
  readAntigravityTranscript,
} from './antigravity-transcript.ts'
import { killProcessTree, resolveCliCommand, spawnCli } from './process-util.ts'
import {
  formatSessionId,
  type BackendCapabilities,
  type BackendImageInput,
  type BackendMessagesResult,
  type BackendModelOption,
  type BackendSessionRow,
} from './types.ts'

export const ANTIGRAVITY_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: true,
  abort: true,
  images: true,
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

export class AntigravityBackend extends AcpSessionBackend {
  readonly id = 'antigravity' as const
  readonly label = 'Antigravity'
  readonly capabilities = ANTIGRAVITY_CAPABILITIES

  protected autoApprovePermissions(): boolean {
    return true
  }

  protected override autoInitForList(): boolean {
    return true
  }

  private readonly createdRawIds = new Set<string>()

  override isRunning(rawId: string): boolean {
    if (super.isRunning(rawId)) return true
    return probeAntigravityDiskActivity(rawId).running
  }

  override async createSession(cwd: string, opts?: { title?: string; model?: string }): Promise<BackendSessionRow> {
    const row = await super.createSession(cwd, opts)
    this.createdRawIds.add(row.rawId)
    return row
  }

  override async sendMessage(
    rawId: string,
    text: string,
    opts?: { images?: BackendImageInput[]; model?: string; cwd?: string },
  ): Promise<{ ok: boolean; runId?: string; status?: string }> {
    clearAntigravityAborted(rawId)
    return await super.sendMessage(rawId, text, opts)
  }

  override async abort(rawId: string): Promise<boolean> {
    markAntigravityAborted(rawId)
    return await super.abort(rawId)
  }

  private isSameDirPath(a: string, b: string): boolean {
    const norm = (s: string): string => s.trim().replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()
    const na = norm(a)
    const nb = norm(b)
    return na !== '' && na === nb
  }

  override async listSessions(limit = 40): Promise<BackendSessionRow[]> {
    // 先取足量原始列表，避免桌面端大量已归档历史会话把当前活跃会话挤出 limit 截断
    const rawRows = await super.listSessions(Math.max(limit * 5, 200))
    const index = readAntigravitySessionIndex()
    const home = homedir()
    const byId = new Map<string, BackendSessionRow>()

    for (const row of rawRows) {
      const meta = index.get(row.rawId)
      const inMemRunning = super.isRunning(row.rawId)
      const isCreatedHere = this.createdRawIds.has(row.rawId)
      if (meta?.archived && !inMemRunning) {
        this.createdRawIds.delete(row.rawId)
        continue
      }
      if (meta?.hidden && !inMemRunning && !isCreatedHere) {
        continue
      }
      byId.set(row.rawId, row)
    }

    // 补充桌面端 conversation_summaries.db 中活跃但 ACP 列表暂未返回的会话
    for (const meta of index.values()) {
      if (meta.hidden || byId.has(meta.rawId)) continue
      const displayCwd = meta.workspaceUri ? this.normalizeSessionCwd(meta.workspaceUri) : ''
      const title = meta.title || this.defaultSessionTitle(false)
      const cache = this.getOrCreateCache(meta.rawId, displayCwd || home, title)
      if (meta.updatedAt > 0) cache.updatedAt = meta.updatedAt
      byId.set(meta.rawId, {
        id: formatSessionId(this.id, meta.rawId),
        rawId: meta.rawId,
        backend: this.id,
        title: meta.title || cache.title,
        cwd: displayCwd,
        updatedAt: meta.updatedAt > 0 ? meta.updatedAt : cache.updatedAt,
        running: cache.running,
        asking: cache.pendingAsk !== null,
        model: cache.model ? { provider: this.id, model: cache.model, reasoningEffort: '' } : null,
      })
    }

    const activeRows: BackendSessionRow[] = []
    for (const row of byId.values()) {
      const meta = index.get(row.rawId)
      const disk = probeAntigravityDiskActivity(row.rawId)

      if (meta?.title) row.title = meta.title
      if (meta?.workspaceUri) {
        row.cwd = this.normalizeSessionCwd(meta.workspaceUri)
      } else if (this.isSameDirPath(row.cwd, home)) {
        // 未分配 Project 的会话不展示系统用户主目录名
        row.cwd = ''
      }

      // 优先采信磁盘真实活跃时间，彻底覆盖 ACP session/list 缺省回退生成的网关启动时刻
      const authoritativeUpdatedAt = Math.max(meta?.updatedAt ?? 0, disk.updatedAt)
      if (authoritativeUpdatedAt > 0) {
        row.updatedAt = authoritativeUpdatedAt
        const cache = this.getOrCreateCache(row.rawId, row.cwd || home, row.title)
        cache.updatedAt = authoritativeUpdatedAt
      }

      if (disk.running) row.running = true
      if (disk.model && !row.model) {
        row.model = { provider: this.id, model: disk.model, reasoningEffort: '' }
      }
      if (disk.preview) {
        row.preview = disk.preview
      } else if (meta?.preview && !row.preview) {
        row.preview = meta.preview
      }

      activeRows.push(row)
    }

    activeRows.sort((a, b) => b.updatedAt - a.updatedAt)
    const sliced = activeRows.slice(0, limit)

    // 对前 8 条活跃会话读取增量磁盘转录，确保列表摘要始终展示最新一条消息而非首句
    let lazyReads = 0
    for (const row of sliced) {
      if (lazyReads >= 8) break
      const disk = probeAntigravityDiskActivity(row.rawId)
      if (disk.preview) {
        row.preview = disk.preview
        continue
      }
      const snap = readAntigravityTranscript(row.rawId)
      lazyReads += 1
      if (!snap) continue
      if (snap.preview) row.preview = snap.preview
      if (snap.running) row.running = true
      if (snap.model && !row.model) {
        row.model = { provider: this.id, model: snap.model, reasoningEffort: '' }
      }
      if (snap.updatedAt > row.updatedAt) {
        row.updatedAt = snap.updatedAt
      }
    }

    sliced.sort((a, b) => b.updatedAt - a.updatedAt)
    return sliced
  }

  override async getMessages(
    rawId: string,
    opts?: { limit?: number; offset?: number; compact?: boolean },
  ): Promise<BackendMessagesResult> {
    const cache = this.getOrCreateCache(rawId)
    const disk = readAntigravityTranscript(rawId)
    if (disk !== null && disk.messages.length > 0) {
      if (disk.model) cache.model = disk.model
      if (disk.updatedAt > cache.updatedAt) cache.updatedAt = disk.updatedAt
      cache.loaded = true

      // 若同时存在本机手机发起的流式回合，把未落盘的实时增量拼到末尾，避免闪回
      const merged = disk.messages.slice()
      const running = cache.running || disk.running
      if (cache.running && cache.activeAssistant) {
        const live = cache.activeAssistant
        const tail = merged[merged.length - 1]
        if (tail && tail.role === 'assistant') {
          if (live.text.length > tail.text.length) tail.text = live.text
          if ((live.thinking?.length ?? 0) > (tail.thinking?.length ?? 0)) tail.thinking = live.thinking
          if ((live.tools?.length ?? 0) > (tail.tools?.length ?? 0)) tail.tools = live.tools
        } else if (live.text || live.thinking || (live.tools && live.tools.length > 0)) {
          merged.push({ ...live, seq: merged.length + 1 })
        }
      }

      const lim = opts?.limit && opts.limit > 0 ? opts.limit : merged.length
      const start = Math.max(0, merged.length - lim)
      const tasks = cache.running && cache.tasks.length > 0
        ? cloneTaskSteps(cache.tasks)
        : (disk.tasks.length > 0 ? disk.tasks : cloneTaskSteps(cache.tasks))
      return {
        messages: merged.slice(start),
        total: merged.length,
        hasMore: start > 0,
        model: cache.model || disk.model || undefined,
        cwd: cache.cwd,
        running,
        asking: cache.pendingAsk !== null,
        tasks,
      }
    }
    return await super.getMessages(rawId, opts)
  }

  protected override async listModelsViaCliFallback(): Promise<BackendModelOption[]> {
    const spec = this.ensureSpec()
    if (!spec || spec.args[0] !== 'acp') return []
    return await new Promise<BackendModelOption[]>((resolveModels) => {
      let out = ''
      let done = false
      const finish = (items: BackendModelOption[]): void => {
        if (done) return
        done = true
        clearTimeout(timer)
        resolveModels(items)
      }
      const child = spawnCli(spec.cli, ['models'])
      const timer = setTimeout(() => {
        killProcessTree(child)
        finish([])
      }, 12_000)
      child.stdout?.on('data', (d: Buffer) => {
        out += d.toString('utf8')
      })
      child.on('error', () => finish([]))
      child.on('exit', () => {
        const parsed: BackendModelOption[] = []
        const seen = new Set<string>()
        for (const rawLine of out.split(/\r?\n/)) {
          const line = rawLine.trim()
          if (!line) continue
          const tabIdx = line.indexOf('\t')
          let id = ''
          let name = ''
          if (tabIdx > 0) {
            id = line.slice(0, tabIdx).trim()
            name = line.slice(tabIdx + 1).trim()
          } else if (/^[a-z0-9][a-z0-9._-]{2,}$/i.test(line)) {
            id = line
            name = line
          } else {
            continue
          }
          if (!id || seen.has(id)) continue
          seen.add(id)
          parsed.push({
            id,
            name: name || id,
            provider: this.id,
          })
        }
        finish(parsed)
      })
    })
  }

  private buildAcpArgs(): string[] {
    const args: string[] = ['acp']
    // 当本机存在桌面版 Antigravity 数据目录（~/.gemini/antigravity）时显式对齐该目录，
    // 避免 agy acp 默认使用 antigravity-cli 导致列出的桌面历史会话在 session/load 时报 Session not found (-32002)。
    const desktopDir = join(homedir(), '.gemini', 'antigravity')
    if (existsSync(desktopDir)) {
      args.push('--app-data-dir', 'antigravity')
    }
    args.push('--dangerously-skip-permissions')
    return args
  }

  protected resolveSpec(force = false): AcpCliSpec | null {
    const acpArgs = this.buildAcpArgs()
    const agy = resolveCliCommand('agy', force)
    if (agy) return { cli: agy, args: acpArgs }

    const antigravity = resolveCliCommand('antigravity', force)
    if (antigravity) return { cli: antigravity, args: acpArgs }

    const server = resolveCliCommand('agy_acp_server', force)
    if (server) return { cli: server, args: ['--dangerously-skip-permissions'] }

    const hyphenServer = resolveCliCommand('antigravity-acp', force)
    if (hyphenServer) return { cli: hyphenServer, args: ['--dangerously-skip-permissions'] }

    return null
  }

  protected missingCliMessage(): string {
    return '未检测到 agy 命令（安装 Antigravity CLI 并执行 agy acp --login 后可用）'
  }
}
