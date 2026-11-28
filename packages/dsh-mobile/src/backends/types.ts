/**
 * 多 Agent 后端统一契约与能力矩阵（与 Cordis / DSH 解耦，未来可直接抽成独立常驻网关）。
 */
import type { TaskStep } from '../task-steps.ts'
import type { ChatMessage } from '../transcript.ts'
import type { SessionRow } from '../projections.ts'

export type BackendId = 'dsh' | 'codex' | 'claude' | 'opencode' | 'antigravity'

export const EXTERNAL_BACKEND_IDS: readonly BackendId[] = ['codex', 'claude', 'opencode', 'antigravity']
export const ALL_BACKEND_IDS: readonly BackendId[] = ['dsh', 'codex', 'claude', 'opencode', 'antigravity']

/** 各后端逐项声明的能力，客户端据此动态隐藏不支持的功能，绝不做硬编码猜测。 */
export interface BackendCapabilities {
  listExistingSessions: boolean
  historyReplay: boolean
  streamDelta: boolean
  approval: boolean
  abort: boolean
  images: boolean
  files: boolean
  modelSwitch: boolean
  reasoningEffort: boolean
  planMode: boolean
  goalMode: boolean
  compact: boolean
  fork: boolean
  archivePin: boolean
  webConsole: boolean
}

export interface BackendModelOption {
  id: string
  name: string
  provider: string
  description?: string
}

export interface BackendProbeResult {
  installed: boolean
  version: string
  binaryPath: string
  error?: string
}

export interface BackendInfo {
  id: BackendId
  label: string
  installed: boolean
  enabled: boolean
  version: string
  status: 'ready' | 'disabled' | 'unavailable' | 'error'
  sessionCount: number
  error?: string
  capabilities: BackendCapabilities
}

export interface BackendSessionRow {
  id: string
  rawId: string
  backend: BackendId
  title: string
  cwd: string
  updatedAt: number
  running: boolean
  asking: boolean
  archived?: boolean
  pinned?: boolean
  preview?: string
  model?: { provider: string; model: string; reasoningEffort: string } | null
  lastTurnId?: string
  lastTurnStatus?: string
  lastDoneAt?: number
}

export interface BackendImageInput {
  mime: string
  data: string
  name?: string
}

export interface BackendAskOption {
  label: string
  description?: string
  value?: string
}

export interface BackendAskQuestion {
  header: string
  question: string
  multiSelect?: boolean
  options: BackendAskOption[]
}

export interface BackendPendingAsk {
  askId: string
  sessionId: string
  questions: BackendAskQuestion[]
  createdAt: number
}

export interface BackendAskState {
  pending: BackendPendingAsk | null
}

export interface BackendNotifyEvent {
  sessionId: string
  title: string
  kind: 'done' | 'asking'
  status?: string
}

/** 推送给客户端 SSE 流的统一事件结构（兼容现有 ChatPage 增量消费）。 */
export interface BackendStreamEvent {
  type: 'snapshot' | 'delta' | 'thinking' | 'tool' | 'tasks' | 'status' | 'ask' | 'done' | 'error'
  text?: string
  thinking?: string
  toolName?: string
  toolId?: string
  toolInput?: string
  toolOutput?: string
  toolStatus?: 'running' | 'done' | 'error'
  tasks?: TaskStep[]
  running?: boolean
  asking?: boolean
  ask?: BackendPendingAsk | null
  error?: string
  message?: ChatMessage
}

export interface BackendMessagesResult {
  messages: ChatMessage[]
  total: number
  hasMore: boolean
  model?: string
  cwd?: string
  running: boolean
  asking: boolean
  tasks?: TaskStep[]
}

export interface AgentBackend {
  readonly id: BackendId
  readonly label: string
  readonly capabilities: BackendCapabilities

  probe(force?: boolean): Promise<BackendProbeResult>
  listSessions(limit?: number): Promise<BackendSessionRow[]>
  getMessages(rawId: string, opts?: { limit?: number; offset?: number; compact?: boolean }): Promise<BackendMessagesResult>
  createSession(cwd: string, opts?: { title?: string; model?: string }): Promise<BackendSessionRow>
  sendMessage(
    rawId: string,
    text: string,
    opts?: { images?: BackendImageInput[]; model?: string; cwd?: string },
  ): Promise<{ ok: boolean; runId?: string; status?: string }>
  abort(rawId: string): Promise<boolean>
  subscribe(rawId: string, listener: (ev: BackendStreamEvent) => void): () => void
  getAsk(rawId: string): BackendAskState
  answerAsk(rawId: string, askId: string, answers: Record<string, string>): Promise<boolean>
  listModels(): Promise<BackendModelOption[]>
  setModel?(rawId: string, model: string): Promise<boolean>
  setNotifyHook?(fn: ((ev: BackendNotifyEvent) => void) | null): void
  isRunning(rawId: string): boolean
  dispose(): void
}

const PREFIX_RE = /^(codex|claude|opencode|antigravity):(.+)$/

/** 解析带前缀的跨后端会话 ID；无已知前缀时默认归属 DSH，保证老路径 100% 兼容。 */
export function parseSessionId(sid: string): { backend: BackendId; rawId: string } {
  const m = PREFIX_RE.exec(sid)
  if (!m) {
    return { backend: 'dsh', rawId: sid }
  }
  return { backend: m[1] as BackendId, rawId: m[2] }
}

/** 生成对外统一的会话 ID：DSH 保持原样，外部后端使用 `<backend>:<rawId>`。 */
export function formatSessionId(backend: BackendId, rawId: string): string {
  if (backend === 'dsh') return rawId
  return `${backend}:${rawId}`
}

export const DSH_CAPABILITIES: BackendCapabilities = {
  listExistingSessions: true,
  historyReplay: true,
  streamDelta: true,
  approval: true,
  abort: true,
  images: true,
  files: true,
  modelSwitch: true,
  reasoningEffort: true,
  planMode: true,
  goalMode: true,
  compact: true,
  fork: true,
  archivePin: true,
  webConsole: true,
}
