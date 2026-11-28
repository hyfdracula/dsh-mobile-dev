/**
 * Api 的请求/响应与领域类型。
 *
 * 从 Api.ets 拆出来：实现与类型分开，Api 重新显式导出全部公开类型以保持消费方兼容。
 */
import { ImagePart } from './Images';
import { FilePart } from './Files';

/** 连接阶段进度回调（stage 从 0 递增，detail 为当前阶段可读说明）。 */
export type StageCallback = (stage: number, detail: string) => void;

/** 会话行（对应 GET /api/sessions 的 sessions[]） */
export interface SessionRow {
  id: string;
  title: string;
  updatedAt: number;
  cwd: string;
  running: boolean;
  /** 宿主有挂起的提问/审批：会话卡片标「等你回答」。 */
  asking?: boolean;
  archived?: boolean;
  pinned?: boolean;
  agents?: AgentSummary;
  model?: ModelRef;
  context?: ContextUsage | null;
  plan?: PlanState;
  /** 所属后端引擎：'dsh' | 'codex' | 'claude' | 'opencode' | 'antigravity' */
  backend?: string;
  preview?: string;
  /** 最近一次已完成回合的唯一标识与状态，用于精准通知去重。 */
  lastTurnId?: string;
  lastTurnStatus?: string;
  lastDoneAt?: number;
}

/** 电脑端多 Agent 引擎能力声明（客户端按能力动态裁剪界面，零硬编码）。 */
export interface BackendCapabilities {
  listExistingSessions: boolean;
  historyReplay: boolean;
  streamDelta: boolean;
  approval: boolean;
  abort: boolean;
  images: boolean;
  files: boolean;
  modelSwitch: boolean;
  reasoningEffort: boolean;
  planMode: boolean;
  goalMode: boolean;
  compact: boolean;
  fork: boolean;
  archivePin: boolean;
  webConsole: boolean;
}

/** 电脑端单个 Agent 后端状态描述（对应 GET /api/backends）。 */
export interface BackendInfo {
  id: string;
  label: string;
  installed: boolean;
  enabled: boolean;
  version: string;
  status: string;
  sessionCount: number;
  error?: string;
  capabilities: BackendCapabilities;
}

export interface BackendsResp {
  ok?: boolean;
  backends?: BackendInfo[];
}

export interface BackendToggleBody {
  enabled: boolean;
}

export interface BackendToggleResp {
  ok?: boolean;
  backend?: BackendInfo;
}

export function backendIdOfSession(id: string): string {
  if (id.startsWith('codex:')) {
    return 'codex';
  }
  if (id.startsWith('claude:')) {
    return 'claude';
  }
  if (id.startsWith('opencode:')) {
    return 'opencode';
  }
  if (id.startsWith('antigravity:')) {
    return 'antigravity';
  }
  return 'dsh';
}

export function backendLabelOf(id: string): string {
  if (id === 'codex') {
    return 'Codex';
  }
  if (id === 'claude') {
    return 'Claude';
  }
  if (id === 'opencode') {
    return 'OpenCode';
  }
  if (id === 'antigravity') {
    return 'Antigravity';
  }
  return 'DSH';
}

export function defaultBackendCapabilities(backend: string): BackendCapabilities {
  if (backend === 'dsh' || backend === '') {
    return {
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
      webConsole: true
    };
  }
  return {
    listExistingSessions: true,
    historyReplay: true,
    streamDelta: true,
    approval: backend === 'codex' || backend === 'opencode' || backend === 'antigravity',
    abort: true,
    images: backend === 'codex' || backend === 'opencode' || backend === 'antigravity',
    files: false,
    modelSwitch: backend === 'codex' || backend === 'claude' || backend === 'antigravity',
    reasoningEffort: backend === 'codex',
    planMode: false,
    goalMode: false,
    compact: false,
    fork: false,
    archivePin: false,
    webConsole: false
  };
}

/** 计划模式状态（F09）。 */
export interface PlanState {
  active: boolean;
  pending: boolean;
}

export interface PlanBody {
  active: boolean;
}

export interface PlanResp {
  ok?: boolean;
  active?: boolean;
  pending?: boolean;
  status?: string;
}

/** 斜杠指令项（F09）。 */
export interface SlashCommandRow {
  name: string;
  description: string;
  hint?: string;
  section: string;
}

export interface CommandsResp {
  ok?: boolean;
  commands?: SlashCommandRow[];
}

export interface CommandExecBody {
  line: string;
}

export interface CommandExecResp {
  ok?: boolean;
  commandId: string;
  kind: string;
  text: string;
}

export interface GoalCreateBody {
  action: string;
  objective: string;
  maxGoalRounds?: number;
}

export interface ExportSignBody {
  format: string;
}

export interface ExportSignRawResp {
  ok?: boolean;
  e?: string;
  sig?: string;
  filename?: string;
}

/** 会话导出短签名结果（F09）。 */
export interface ExportSignResp {
  ok: boolean;
  url: string;
  filename: string;
  e: string;
  sig: string;
}

export interface WebConsoleGrantRawResp {
  ok?: boolean;
  grant?: string;
  path?: string;
  expiresIn?: number;
}

/** 免密网页控制台一次性授权结果（L5）。 */
export interface WebConsoleGrantResp {
  ok: boolean;
  grant: string;
  path: string;
  enterUrl: string;
  expiresIn: number;
}

export interface TokenUsage {
  uncachedInputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
}

export interface SessionStats {
  turns: number;
  steps: number;
  toolCalls: number;
  tokens: TokenUsage;
}

/** 消息里的一张图片：只带摘要，字节由 /api/attachments 单独取 */
export interface ImageRef {
  id: string;
  mediaType: string;
  width: number;
  height: number;
  name: string;
}

/** 工具调用轨迹（G4）：status 为 run / ok / err */
export interface ToolStep {
  id: string;
  name: string;
  summary: string;
  status: string;
}

/** 会话目标视图 */
export interface GoalView {
  id?: string;
  objective?: string;
  phase?: string;
  revision?: number;
  roundsStarted?: number;
  maxGoalRounds?: number;
  activation?: string;
}

export interface GoalResp {
  ok?: boolean;
  sessionId?: string;
  goal?: GoalView | null;
}

export interface TurnInfo {
  status: string;
  ms: number;
  tokensIn: number;
  tokensOut: number;
  atSeq: number;
  finishedAt?: number;
  errCode?: string;
  errText?: string;
}

export interface Message {
  role: string;
  text: string;
  time: number;
  seq: number;
  images?: ImageRef[];
  turn?: TurnInfo;
  thinking?: string;
  tools?: ToolStep[];
}

/** 上下文占用：宿主 token-meter 投影（used 为下一次请求的 prompt 估算，window 为路由容量）。 */
export interface ContextUsage {
  used: number;
  window: number;
}

/** 电脑端待发送队列里的一条 */
export interface QueueTextBody {
  text: string;
}

/** 宿主队列里一条消息内的图片（只有元信息）。 */
export interface QueueImage {
  mediaType: string;
  name?: string;
}

export interface QueuedItem {
  id: string;
  text: string;
  at: number;
  index: number;
  images?: QueueImage[];
}

export interface AskOption {
  label: string;
  description?: string;
}

export interface AskQuestion {
  id: string;
  prompt?: string;
  header?: string;
  detail?: string;
  options?: AskOption[];
  multiSelect?: boolean;
}

export interface PendingAsk {
  callId: string;
  questions: AskQuestion[];
  state: string;
  /** 题卡编号由手机网关合成（宿主这次提问没有带 callId），回答时原样回传即可。 */
  synthetic?: boolean;
}

export interface AskAnswer {
  id: string;
  selected: string[];
  custom?: string;
}

export interface AnswerBody {
  callId: string;
  answers: AskAnswer[];
}

export interface AskState {
  active: PendingAsk[];
  settled: Object[];
}

/** 最后一轮失败的原因（插件从会话日志的 turn/end 里抠出来的）。 */
export interface TurnErr {
  code: string;
  text: string;
  time: number;
}

export interface MessagesResult {
  total: number;
  messages: Message[];
  context?: ContextUsage | null;
  stats?: SessionStats;
  firstSeq?: number;
  running?: boolean;
  /** 最后一轮的结束原因（completed / aborted / interrupted / error …） */
  lastTurn?: string;
  /** 最后一轮失败时的原始报错 */
  lastErr?: TurnErr | null;
  queue?: QueuedItem[];
  questions?: AskState;
  plan?: PlanState;
}

/** SSE 增量推送帧（R4：对应 GET /api/sessions/:id/stream 的 event: update） */
export interface StreamUpdate {
  ok?: boolean;
  type?: string;
  sessionId?: string;
  total: number;
  firstSeq?: number;
  messages: Message[];
  lastTurn?: string;
  lastErr?: TurnErr | null;
  running?: boolean;
  context?: ContextUsage | null;
  stats?: SessionStats;
  queue?: QueuedItem[];
  questions?: AskState;
  plan?: PlanState;
}

export interface ModelRef {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface AgentRef {
  id: string;
  label: string;
  mode: string;
  createdAt: number;
}

/** 会话携带的智能体概况（子智能体 + 团队任务数） */
export interface AgentSummary {
  enabled: number;
  tasks: number;
  subagents: AgentRef[];
}

export interface ApiInfo {
  ok: boolean;
  version: string;
  host: string;
  port: number;
  hostId?: string;
  e2ee?: boolean;
  e2eePub?: string;
  plan?: boolean;
  commands?: boolean;
  webConsole?: boolean;
}

export interface SessionsResp {
  ok: boolean;
  sessions: SessionRow[];
}

export interface PreviewRow {
  id: string;
  preview: string;
  count: number;
}

export interface PreviewsResp {
  ok: boolean;
  previews: PreviewRow[];
}

export interface MessagesResp {
  ok: boolean;
  sessionId: string;
  total: number;
  messages: Message[];
  stats?: SessionStats;
  context?: ContextUsage | null;
  running?: boolean;
  firstSeq?: number;
  lastTurn?: string;
  lastErr?: TurnErr;
  queue?: QueuedItem[];
  questions?: AskState;
  plan?: PlanState;
}

export interface PresenceBody {
  online: boolean;
  sessionId?: string;
}

export interface PresenceResp {
  ok?: boolean;
  online?: boolean;
  ttlMs?: number;
}

export interface PushRegisterBody {
  deviceId: string;
  pushToken: string;
  relayUrl: string;
  relaySecret?: string;
  enabled: boolean;
  bgOnly: boolean;
  showTitle: boolean;
}

export interface PushRegisterResp {
  ok?: boolean;
  count?: number;
  error?: string;
}

export interface PushStatusResp {
  ok?: boolean;
  registeredCount?: number;
  enabledCount?: number;
  boundCount?: number;
  relayOk?: boolean;
  relayConfigured?: boolean;
  category?: string;
  testMode?: boolean;
  relayError?: string;
}

export interface PushTestBody {
  deviceId?: string;
  relayUrl?: string;
}

export interface PushTestResp {
  ok?: boolean;
  code?: string;
  hwCode?: string;
  requestId?: string;
  message?: string;
}

export interface PairInviteResp {
  ok?: boolean;
  payload?: string;
  code?: string;
  expiresAt?: number;
  base?: string;
  alts?: string[];
  host?: string;
  allowRemote?: boolean;
  publicUrl?: string;
  error?: string;
}

export interface RemotePairPendingItem {
  id: string;
  verifyCode: string;
  deviceName: string;
  source: string;
  createdAt: number;
  expiresAt: number;
}

export interface RemotePairListResp {
  ok?: boolean;
  requests?: RemotePairPendingItem[];
}

export interface RemotePairDecideBody {
  id: string;
  approve: boolean;
}

export interface RemotePairDecideResp {
  ok?: boolean;
  status?: string;
  requests?: RemotePairPendingItem[];
  error?: string;
}

export interface InfoResp {
  ok: boolean;
  version: string;
  host: string;
  port: number;
  addresses?: string[];
  hostId?: string;
  e2ee?: boolean;
  e2eePub?: string;
  plan?: boolean;
  commands?: boolean;
  webConsole?: boolean;
}

export interface RawResult {
  code: number;
  text: string;
}

export interface QueueOrderBody {
  ids: string[];
}

export interface QueueOrderResp {
  ok?: boolean;
  moved?: number;
}

export interface ErrBody {
  error?: string;
}

export interface FsWriteBody {
  path: string;
  to: string;
}

export interface FsDeleteBody {
  path: string;
}

export interface RawSignBody {
  path: string;
}

export interface RawSignResp {
  e?: string;
  sig?: string;
}

export interface SignBody {
  ids: string[];
}

export interface SignItem {
  id: string;
  e: string;
  sig: string;
}

export interface SignResp {
  items?: SignItem[];
}

export interface ForkBody {
  atSeq?: number;
}

export interface ForkResp {
  ok?: boolean;
  sessionId?: string;
}

export interface FilesBody {
  text: string;
  files: FilePart[];
  mode?: string;
}

export interface FilesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

export interface OutboxBody {
  text: string;
  images: ImagePart[];
  files: FilePart[];
  mode?: string;
}

export interface OutboxResp {
  ok: boolean;
  parts: number;
  queued?: boolean;
}

export interface ImagesBody {
  text: string;
  images: ImagePart[];
  mode?: string;
}

export interface ImagesResp {
  ok: boolean;
  count: number;
  bytes: number;
}

export interface StopResp {
  ok: boolean;
  accepted: boolean;
}

export interface CreateBody {
  cwd: string;
  backend?: string;
}

export interface CreateResp {
  ok: boolean;
  sessionId?: string;
}

export interface RenameBody {
  title: string;
}

export interface ModelBody {
  provider: string;
  model: string;
  reasoningEffort?: string;
}

export interface EffortRef {
  id: string;
  name: string;
}

export interface CatalogModel {
  id: string;
  name: string;
  description: string;
  efforts: EffortRef[];
  defaultEffort: string;
}

export interface CatalogGroup {
  id: string;
  name: string;
  models: CatalogModel[];
}

export interface Catalog {
  current: ModelRef | null;
  routable: boolean;
  groups: CatalogGroup[];
}

export interface ModelsResp {
  ok: boolean;
  sessionId: string;
  catalog: Catalog;
}

export interface PresetRow {
  id: string;
  name: string;
  description: string;
  isDefault: boolean;
  broken: string;
}

export interface PermRow {
  value: string;
  name: string;
  description: string;
}

export interface PresetsResp {
  ok: boolean;
  presets: PresetRow[];
  current: string;
  unavailable: boolean;
}

export interface PermsResp {
  ok: boolean;
  presets: PermRow[];
  current: string;
  defaultPreset: string;
  unavailable: boolean;
}

export interface PresetBody {
  presetId: string;
}

export interface PresetResp {
  ok: boolean;
  selected?: string;
  scope?: string;
}

export interface PermBody {
  permission: string;
}

export interface PermResp {
  ok: boolean;
  preset?: string;
  current?: string;
}

export interface ArchiveResp {
  ok: boolean;
  sessionId?: string;
  archived?: boolean;
  cancelledFirst?: boolean;
  via?: string;
}

export interface PinBody {
  pinned: boolean;
}

export interface PinResp {
  ok: boolean;
  sessionId?: string;
  pinned?: boolean;
  via?: string;
}

export interface SendBody {
  text: string;
  mode?: string;
}

export interface HostPluginRow {
  name: string;
  version: string;
  enabled: boolean;
  local: boolean;
}

export interface HostPluginGroup {
  profile: string;
  items: HostPluginRow[];
}

export interface HostPluginsResp {
  ok?: boolean;
  groups?: HostPluginGroup[];
}

export interface HostTaskRow {
  id: string;
  title: string;
  kind: string;
  when: string;
  active: boolean;
  sessionId: string;
}

export interface HostSchedulesResp {
  ok?: boolean;
  source?: string;
  items?: HostTaskRow[];
}

/** 任务动作的请求体：action 只认 pause / resume / run / delete。 */
export interface HostTaskActionBody {
  action: string;
}

/** 插件开关的请求体。 */
export interface HostPluginToggleBody {
  profile: string;
  name: string;
  enabled: boolean;
}

export interface HostPluginToggleResp {
  ok?: boolean;
  profile?: string;
  name?: string;
  enabled?: boolean;
  changed?: boolean;
  restartRequired?: boolean;
}

/** 插件配置项（R5：扁平安全标量 boolean / number / string）。 */
export interface PluginSettingField {
  key: string;
  kind: string;
  value: string;
}

export interface PluginSettingsResp {
  ok?: boolean;
  writable: boolean;
  restartRequired?: boolean;
  fields: PluginSettingField[];
}

export interface PluginSettingsSaveBody {
  profile: string;
  name: string;
  fields?: PluginSettingField[];
  values?: Record<string, string | number | boolean>;
}

export interface FsEntry {
  name: string;
  dir: boolean;
  size: number;
  mtime: number;
}

export interface FsListing {
  root: string;
  path: string;
  entries: FsEntry[];
  more: boolean;
  /** 会话没有工作目录时，宿主退回了它自己的当前目录 */
  fallback?: boolean;
  total?: number;
  offset?: number;
  nextOffset?: number;
}

export interface FsResp {
  ok?: boolean;
  root?: string;
  path?: string;
  entries?: FsEntry[];
  more?: boolean;
  fallback?: boolean;
  total?: number;
  offset?: number;
  nextOffset?: number;
}

/** 宿主文件夹浏览（G6：新建会话选择任意目录）。 */
export interface HostDirEntry {
  name: string;
  path: string;
}

export interface HostDirsResp {
  ok?: boolean;
  path: string;
  parent: string;
  roots?: HostDirEntry[];
  dirs: HostDirEntry[];
  recent: string[];
}

export interface FsMkdirBody {
  path: string;
}

export interface FsUploadItem {
  name: string;
  data: string;
}

export interface FsUploadBody {
  dir: string;
  files: FsUploadItem[];
}

export interface FsUploadResp {
  ok?: boolean;
  saved: string[];
  bytes: number;
}

/** Git 变更文件行与 Diff 响应（G5）。 */
export interface GitFileRow {
  path: string;
  status: string;
  staged: boolean;
}

export interface GitStatusResp {
  ok?: boolean;
  isRepo: boolean;
  branch: string;
  ahead: number;
  behind: number;
  files: GitFileRow[];
}

export interface GitDiffResp {
  ok?: boolean;
  path: string;
  diff: string;
  truncated: boolean;
}

/** 受控工作区终端（R6）。 */
export interface TerminalOpenResp {
  ok?: boolean;
  cwd: string;
  running: boolean;
  exitCode: number | null;
  output: string;
  seq: number;
}

export interface TerminalPollResp {
  ok?: boolean;
  cwd?: string;
  running: boolean;
  exitCode: number | null;
  output?: string;
  seq: number;
}

export interface TerminalInputBody {
  data?: string;
  raw?: boolean;
  action?: string;
}

/** 已授权本机开发服预览代理（R9）。 */
export interface LoopbackPortsResp {
  ok?: boolean;
  ports?: number[];
}

export interface LoopbackSignBody {
  port: number;
}

export interface LoopbackSignResp {
  ok?: boolean;
  port?: number;
  e?: string;
  sig?: string;
}

export interface TeamMemberRow {
  id: string;
  name: string;
  description: string;
  phase: string;
  error: string;
}

export interface TeamTaskRow {
  id: string;
  revision: number;
  subject: string;
  description: string;
  status: string;
  ownerName: string;
  ownerId: string;
}

export interface TeamResp {
  ok?: boolean;
  sessionId?: string;
  enabled?: boolean;
  sawMode?: boolean;
  members?: TeamMemberRow[];
  tasks?: TeamTaskRow[];
}

export interface TeamModeBody {
  enabled: boolean;
}

export interface TeamModeResp {
  ok?: boolean;
  enabled?: boolean;
}

export interface FsFile {
  name: string;
  size: number;
  text: string;
}

export interface FsFileResp {
  ok?: boolean;
  name?: string;
  size?: number;
  text?: string;
}

export interface AnswerModeBody {
  mode: string;
}

export interface AnswerModeResp {
  ok?: boolean;
  mode?: string;
}
