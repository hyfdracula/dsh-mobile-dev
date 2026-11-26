/**
 * 多 Agent 后端注册表与调度中心（完全独立于 Cordis `ctx`）：
 * - 统一管理外部后端（Codex / Claude Code / OpenCode / Antigravity）的探测、开关、会话聚合与按 ID 前缀分发；
 * - 默认所有外部后端关闭（可通过持久化开关按需开启），确保安全边界与零破坏兼容。
 */
import { AntigravityBackend } from './antigravity-backend.ts'
import { ClaudeBackend } from './claude-backend.ts'
import { CodexBackend } from './codex-backend.ts'
import { OpenCodeBackend } from './opencode-backend.ts'
import {
  DSH_CAPABILITIES,
  EXTERNAL_BACKEND_IDS,
  parseSessionId,
  type AgentBackend,
  type BackendId,
  type BackendInfo,
  type BackendNotifyEvent,
  type BackendProbeResult,
  type BackendSessionRow,
} from './types.ts'

export interface RegistryDeps {
  getEnabledMap: () => Record<string, boolean>
  setEnabled: (id: BackendId, enabled: boolean) => void
  dshSessionCount?: () => number
  dshVersion?: string
}

export class BackendRegistry {
  private readonly deps: RegistryDeps
  private readonly backends = new Map<BackendId, AgentBackend>()
  private readonly probeCache = new Map<BackendId, BackendProbeResult>()
  private readonly countCache = new Map<BackendId, number>()

  constructor(deps: RegistryDeps) {
    this.deps = deps
    const codex = new CodexBackend()
    const claude = new ClaudeBackend()
    const opencode = new OpenCodeBackend()
    const antigravity = new AntigravityBackend()
    this.backends.set(codex.id, codex)
    this.backends.set(claude.id, claude)
    this.backends.set(opencode.id, opencode)
    this.backends.set(antigravity.id, antigravity)
  }

  setNotifyListener(fn: ((ev: BackendNotifyEvent) => void) | null): void {
    for (const driver of this.backends.values()) {
      driver.setNotifyHook?.(fn)
    }
  }

  getExternal(id: BackendId): AgentBackend | null {
    if (id === 'dsh') return null
    return this.backends.get(id) ?? null
  }

  resolveBySessionId(sid: string): { backend: BackendId; rawId: string; driver: AgentBackend | null } {
    const parsed = parseSessionId(sid)
    return {
      backend: parsed.backend,
      rawId: parsed.rawId,
      driver: this.getExternal(parsed.backend),
    }
  }

  isEnabled(id: BackendId): boolean {
    if (id === 'dsh') return true
    const map = this.deps.getEnabledMap()
    return map[id] === true
  }

  async toggle(id: BackendId, enabled: boolean): Promise<BackendInfo> {
    if (id === 'dsh') {
      throw new Error('DSH 为默认内置后端，不可关闭')
    }
    const driver = this.backends.get(id)
    if (!driver) {
      throw new Error(`未知后端: ${id}`)
    }
    const probe = await driver.probe(false)
    if (enabled && !probe.installed) {
      throw new Error(`${driver.label} 未安装或不在 PATH 中`)
    }
    this.deps.setEnabled(id, enabled)
    if (!enabled) {
      driver.dispose()
    }
    return await this.infoOf(id, false)
  }

  async infoOf(id: BackendId, forceProbe = false): Promise<BackendInfo> {
    if (id === 'dsh') {
      return {
        id: 'dsh',
        label: 'DSH',
        installed: true,
        enabled: true,
        version: this.deps.dshVersion || 'builtin',
        status: 'ready',
        sessionCount: this.deps.dshSessionCount ? this.deps.dshSessionCount() : 0,
        capabilities: DSH_CAPABILITIES,
      }
    }
    const driver = this.backends.get(id)
    if (!driver) {
      return {
        id,
        label: id,
        installed: false,
        enabled: false,
        version: '',
        status: 'unavailable',
        sessionCount: 0,
        capabilities: DSH_CAPABILITIES,
      }
    }
    let probe = this.probeCache.get(id)
    if (forceProbe || !probe) {
      probe = await driver.probe(forceProbe)
      this.probeCache.set(id, probe)
    }
    const enabled = this.isEnabled(id)
    const status: BackendInfo['status'] = !probe.installed
      ? 'unavailable'
      : enabled
        ? 'ready'
        : 'disabled'
    return {
      id: driver.id,
      label: driver.label,
      installed: probe.installed,
      enabled: probe.installed && enabled,
      version: probe.version,
      status,
      sessionCount: this.countCache.get(id) ?? 0,
      error: probe.error,
      capabilities: driver.capabilities,
    }
  }

  async listBackendInfos(forceProbe = false): Promise<BackendInfo[]> {
    const ids: BackendId[] = ['dsh', ...EXTERNAL_BACKEND_IDS]
    return await Promise.all(ids.map((id) => this.infoOf(id, forceProbe)))
  }

  /** 拉取已启用外部后端的会话（支持单个指定或全部聚合，单后端失败不拖垮整体列表）。 */
  async listExternalSessions(filter: BackendId | 'all' = 'all', limitPerBackend = 30): Promise<BackendSessionRow[]> {
    const targets: BackendId[] =
      filter === 'all'
        ? [...EXTERNAL_BACKEND_IDS]
        : filter === 'dsh'
          ? []
          : [filter]

    const activeTargets = targets.filter((id) => this.isEnabled(id))
    if (activeTargets.length === 0) return []

    const chunks = await Promise.all(
      activeTargets.map(async (id) => {
        const driver = this.backends.get(id)
        if (!driver) return []
        try {
          const rows = await driver.listSessions(limitPerBackend)
          this.countCache.set(id, rows.length)
          return rows
        } catch {
          return []
        }
      }),
    )
    return chunks.flat()
  }

  dispose(): void {
    for (const driver of this.backends.values()) {
      driver.dispose()
    }
  }
}
