import { FilePart } from './Files';
import { ImagePart } from './Images';
import { ApiTransport } from './ApiTransport';
import { LinkLog } from './LinkLog';
import { AgentConfigApi } from './api/AgentConfigApi';
import { DeviceApi } from './api/DeviceApi';
import { HostFsApi } from './api/HostFsApi';
import { SessionApi } from './api/SessionApi';

import {
  AgentRef,
  AgentSummary,
  AnswerBody,
  ApiInfo,
  AskAnswer,
  AskOption,
  AskQuestion,
  AskState,
  BackendInfo,
  Catalog,
  CatalogGroup,
  CatalogModel,
  CommandExecResp,
  ContextUsage,
  EffortRef,
  ExportSignResp,
  FsEntry,
  FsFile,
  FsListing,
  FsMkdirBody,
  FsUploadBody,
  FsUploadItem,
  FsUploadResp,
  GitDiffResp,
  GitFileRow,
  GitStatusResp,
  GoalView,
  HostDirEntry,
  HostDirsResp,
  HostPluginGroup,
  HostPluginRow,
  HostTaskRow,
  ImageRef,
  LoopbackPortsResp,
  LoopbackSignBody,
  LoopbackSignResp,
  Message,
  MessagesResult,
  ModelRef,
  PendingAsk,
  PermRow,
  PermsResp,
  PlanState,
  PluginSettingField,
  PluginSettingsResp,
  PluginSettingsSaveBody,
  PresetRow,
  PresetsResp,
  PreviewRow,
  PushRegisterBody,
  PushRegisterResp,
  PushStatusResp,
  PushTestResp,
  QueueImage,
  QueueTextBody,
  QueuedItem,
  SessionRow,
  SessionStats,
  SlashCommandRow,
  StageCallback,
  StreamUpdate,
  TeamMemberRow,
  TeamResp,
  TeamTaskRow,
  TerminalInputBody,
  TerminalOpenResp,
  TerminalPollResp,
  TokenUsage,
  ToolStep,
  TurnErr,
  TurnInfo,
  WebConsoleGrantResp
} from './ApiTypes';

export {
  SessionRow,
  BackendCapabilities,
  BackendInfo,
  backendIdOfSession,
  backendLabelOf,
  defaultBackendCapabilities,
  PlanState,
  SlashCommandRow,
  CommandExecResp,
  ExportSignResp,
  WebConsoleGrantResp,
  TokenUsage,
  SessionStats,
  ImageRef,
  ToolStep,
  GoalView,
  TurnInfo,
  Message,
  ContextUsage,
  QueueTextBody,
  QueueImage,
  QueuedItem,
  AskOption,
  AskQuestion,
  PendingAsk,
  AskAnswer,
  AnswerBody,
  AskState,
  TurnErr,
  MessagesResult,
  StreamUpdate,
  ModelRef,
  AgentRef,
  AgentSummary,
  ApiInfo,
  PreviewRow,
  EffortRef,
  CatalogModel,
  CatalogGroup,
  Catalog,
  PresetRow,
  PermRow,
  PresetsResp,
  PermsResp,
  HostPluginRow,
  HostPluginGroup,
  PluginSettingField,
  PluginSettingsResp,
  PluginSettingsSaveBody,
  HostTaskRow,
  FsEntry,
  FsListing,
  HostDirEntry,
  HostDirsResp,
  FsMkdirBody,
  FsUploadItem,
  FsUploadBody,
  FsUploadResp,
  GitFileRow,
  GitStatusResp,
  GitDiffResp,
  TerminalOpenResp,
  TerminalPollResp,
  TerminalInputBody,
  LoopbackPortsResp,
  LoopbackSignBody,
  LoopbackSignResp,
  StageCallback,
  TeamMemberRow,
  TeamTaskRow,
  TeamResp,
  FsFile,
  PushRegisterBody,
  PushRegisterResp,
  PushStatusResp,
  PushTestResp
} from './ApiTypes';

/**
 * dsh-mobile HTTP、Noise_IK 端到端加密与 SSE 客户端统一门面。
 *
 * 传输、择优与透明 E2EE 见 ApiTransport；业务接口按域分布在：
 * - DeviceApi（探活、心跳、回答归属、网页控制台免密授权）
 * - SessionApi（会话生命周期、消息与增量 SSE 流、队列、附件签名、计划模式、斜杠指令、日志导出）
 * - AgentConfigApi（模型路由、预设、权限、团队协作、Goal 创建与控制）
 * - HostFsApi（插件与插件配置、定时任务、目录浏览、文件系统读写、Git、终端、本机预览代理）
 */
export class Api extends ApiTransport {
  private static backendsCache: BackendInfo[] = [];

  static cachedBackends(): BackendInfo[] {
    return Api.backendsCache.slice();
  }

  static clearBackendsCache(): void {
    Api.backendsCache = [];
  }

  // ---------- 设备与网页控制台（DeviceApi） ----------

  async info(stageCb?: StageCallback): Promise<ApiInfo> {
    return await DeviceApi.info(this, stageCb);
  }

  async presence(online: boolean, sessionId: string = ''): Promise<void> {
    await DeviceApi.presence(this, online, sessionId);
  }

  async answerMode(): Promise<string> {
    return await DeviceApi.answerMode(this);
  }

  async setAnswerMode(mode: string): Promise<string> {
    return await DeviceApi.setAnswerMode(this, mode);
  }

  async webConsoleGrant(): Promise<WebConsoleGrantResp> {
    return await DeviceApi.webConsoleGrant(this);
  }

  async registerPush(body: PushRegisterBody): Promise<PushRegisterResp> {
    return await DeviceApi.registerPush(this, body);
  }

  async pushStatus(relayUrl: string = ''): Promise<PushStatusResp> {
    return await DeviceApi.pushStatus(this, relayUrl);
  }

  async testPush(deviceId: string = '', relayUrl: string = ''): Promise<PushTestResp> {
    return await DeviceApi.testPush(this, deviceId, relayUrl);
  }

  // ---------- 会话、消息流、队列、计划与指令（SessionApi） ----------

  async sessions(backend: string = ''): Promise<SessionRow[]> {
    return await SessionApi.sessions(this, backend);
  }

  async backends(refresh: boolean = false): Promise<BackendInfo[]> {
    const rows: BackendInfo[] = await SessionApi.backends(this, refresh);
    Api.backendsCache = rows.slice();
    LinkLog.record('ENGINE', 'backends count=' + String(rows.length) + ' refresh=' + (refresh ? '1' : '0'));
    return rows;
  }

  async toggleBackend(id: string, enabled: boolean): Promise<BackendInfo | null> {
    const updated: BackendInfo | null = await SessionApi.toggleBackend(this, id, enabled);
    if (updated !== null && Api.backendsCache.length > 0) {
      Api.backendsCache = Api.backendsCache.map((x: BackendInfo): BackendInfo => x.id === updated.id ? updated : x);
    }
    LinkLog.record('ENGINE', 'toggle ' + id + ' -> ' + (enabled ? 'on' : 'off'));
    return updated;
  }

  async previews(ids: string[]): Promise<PreviewRow[]> {
    return await SessionApi.previews(this, ids);
  }

  async messages(id: string, limit: number, compact: boolean = false): Promise<MessagesResult> {
    return await SessionApi.messages(this, id, limit, compact);
  }

  async messagesSince(id: string, since: number, compact: boolean = false): Promise<MessagesResult> {
    return await SessionApi.messagesSince(this, id, since, compact);
  }

  async messagesBefore(id: string, before: number, limit: number = 60,
    compact: boolean = false): Promise<MessagesResult> {
    return await SessionApi.messagesBefore(this, id, before, limit, compact);
  }

  streamSession(
    id: string,
    since: number,
    onUpdate: (update: StreamUpdate) => void,
    onFallback: (reason: string) => void,
    compact: boolean = false
  ): () => void {
    return SessionApi.streamSession(this, id, since, onUpdate, onFallback, compact);
  }

  async send(id: string, text: string, mode: string = '', idem: string = ''): Promise<void> {
    await SessionApi.send(this, id, text, mode, idem);
  }

  async sendOutbox(id: string, text: string, images: ImagePart[], files: FilePart[],
    mode: string = '', idem: string = ''): Promise<number> {
    return await SessionApi.sendOutbox(this, id, text, images, files, mode, idem);
  }

  async stop(id: string): Promise<boolean> {
    return await SessionApi.stop(this, id);
  }

  async createSession(cwd: string, backend: string = 'dsh'): Promise<string> {
    return await SessionApi.createSession(this, cwd, backend);
  }

  async rename(id: string, title: string): Promise<void> {
    await SessionApi.rename(this, id, title);
  }

  async archive(id: string): Promise<boolean> {
    return await SessionApi.archive(this, id);
  }

  async unarchive(id: string): Promise<boolean> {
    return await SessionApi.unarchive(this, id);
  }

  async pin(id: string, pinned: boolean): Promise<boolean> {
    return await SessionApi.pin(this, id, pinned);
  }

  async fork(id: string, atSeq: number = -1): Promise<string> {
    return await SessionApi.fork(this, id, atSeq);
  }

  async queueDrop(id: string, itemId: string): Promise<void> {
    await SessionApi.queueDrop(this, id, itemId);
  }

  async queueReorder(id: string, ids: string[]): Promise<void> {
    await SessionApi.queueReorder(this, id, ids);
  }

  async queueEdit(id: string, itemId: string, text: string): Promise<void> {
    await SessionApi.queueEdit(this, id, itemId, text);
  }

  async queueFire(id: string, itemId: string): Promise<void> {
    await SessionApi.queueFire(this, id, itemId);
  }

  async answerQuestions(id: string, callId: string, answers: AskAnswer[]): Promise<void> {
    await SessionApi.answerQuestions(this, id, callId, answers);
  }

  async signAttachments(ids: string[]): Promise<void> {
    await SessionApi.signAttachments(this, ids);
  }

  attachmentUrl(img: ImageRef): string {
    return SessionApi.attachmentUrl(this, img);
  }

  async plan(id: string): Promise<PlanState> {
    return await SessionApi.plan(this, id);
  }

  async setPlan(id: string, active: boolean): Promise<PlanState> {
    return await SessionApi.setPlan(this, id, active);
  }

  async commands(id: string): Promise<SlashCommandRow[]> {
    return await SessionApi.commands(this, id);
  }

  async execCommand(id: string, line: string): Promise<CommandExecResp> {
    return await SessionApi.execCommand(this, id, line);
  }

  async exportSessionUrl(id: string, format: string): Promise<ExportSignResp> {
    return await SessionApi.exportSessionUrl(this, id, format);
  }

  // ---------- 模型、预设、权限、团队与目标（AgentConfigApi） ----------

  async models(id: string): Promise<Catalog> {
    return await AgentConfigApi.models(this, id);
  }

  async selectModel(id: string, provider: string, model: string, effort: string): Promise<void> {
    await AgentConfigApi.selectModel(this, id, provider, model, effort);
  }

  async presets(): Promise<PresetsResp> {
    return await AgentConfigApi.presets(this);
  }

  async permissions(id: string): Promise<PermsResp> {
    return await AgentConfigApi.permissions(this, id);
  }

  async selectPreset(id: string, presetId: string): Promise<string> {
    return await AgentConfigApi.selectPreset(this, id, presetId);
  }

  async setPermission(id: string, permission: string): Promise<string> {
    return await AgentConfigApi.setPermission(this, id, permission);
  }

  async team(id: string): Promise<TeamResp> {
    return await AgentConfigApi.team(this, id);
  }

  async teamMode(id: string, enabled: boolean): Promise<boolean> {
    return await AgentConfigApi.teamMode(this, id, enabled);
  }

  async goal(id: string): Promise<GoalView | null> {
    return await AgentConfigApi.goal(this, id);
  }

  async goalCreate(id: string, objective: string, maxRounds?: number): Promise<GoalView | null> {
    return await AgentConfigApi.goalCreate(this, id, objective, maxRounds);
  }

  async goalAction(id: string, action: string, patch: string = ''): Promise<GoalView | null> {
    return await AgentConfigApi.goalAction(this, id, action, patch);
  }

  // ---------- 宿主扩展、工作区文件、Git、终端与预览代理（HostFsApi） ----------

  async hostPlugins(): Promise<HostPluginGroup[]> {
    return await HostFsApi.hostPlugins(this);
  }

  async pluginToggle(profile: string, name: string, enabled: boolean): Promise<boolean> {
    return await HostFsApi.pluginToggle(this, profile, name, enabled);
  }

  async pluginSettings(profile: string, name: string): Promise<PluginSettingsResp> {
    return await HostFsApi.pluginSettings(this, profile, name);
  }

  async savePluginSettings(profile: string, name: string, fields: PluginSettingField[]): Promise<PluginSettingsResp> {
    return await HostFsApi.savePluginSettings(this, profile, name, fields);
  }

  async hostSchedules(): Promise<HostTaskRow[]> {
    return await HostFsApi.hostSchedules(this);
  }

  async scheduleAction(id: string, action: string): Promise<void> {
    await HostFsApi.scheduleAction(this, id, action);
  }

  async hostDirs(path: string = ''): Promise<HostDirsResp> {
    return await HostFsApi.hostDirs(this, path);
  }

  async fsList(id: string, path: string, offset: number = 0, limit: number = 400): Promise<FsListing> {
    return await HostFsApi.fsList(this, id, path, offset, limit);
  }

  async fsFile(id: string, path: string): Promise<FsFile> {
    return await HostFsApi.fsFile(this, id, path);
  }

  async fsMkdir(id: string, path: string): Promise<void> {
    await HostFsApi.fsMkdir(this, id, path);
  }

  async fsUpload(id: string, dir: string, files: FsUploadItem[]): Promise<FsUploadResp> {
    return await HostFsApi.fsUpload(this, id, dir, files);
  }

  async fsRename(id: string, path: string, to: string): Promise<void> {
    await HostFsApi.fsRename(this, id, path, to);
  }

  async fsDelete(id: string, path: string): Promise<void> {
    await HostFsApi.fsDelete(this, id, path);
  }

  async signFsRaw(id: string, path: string): Promise<void> {
    await HostFsApi.signFsRaw(this, id, path);
  }

  fsRawUrl(id: string, path: string): string {
    return HostFsApi.fsRawUrl(this, id, path);
  }

  fsDownloadUrl(id: string, path: string): string {
    return HostFsApi.fsDownloadUrl(this, id, path);
  }

  async gitStatus(id: string): Promise<GitStatusResp> {
    return await HostFsApi.gitStatus(this, id);
  }

  async gitDiff(id: string, path: string, staged: boolean = false): Promise<GitDiffResp> {
    return await HostFsApi.gitDiff(this, id, path, staged);
  }

  async terminalOpen(id: string): Promise<TerminalOpenResp> {
    return await HostFsApi.terminalOpen(this, id);
  }

  async terminalPoll(id: string, since: number = 0): Promise<TerminalPollResp> {
    return await HostFsApi.terminalPoll(this, id, since);
  }

  async terminalInput(id: string, data: string, action: string = '', raw: boolean = false): Promise<TerminalPollResp> {
    return await HostFsApi.terminalInput(this, id, data, action, raw);
  }

  async loopbackPorts(): Promise<number[]> {
    return await HostFsApi.loopbackPorts(this);
  }

  async signLoopback(port: number): Promise<boolean> {
    return await HostFsApi.signLoopback(this, port);
  }

  loopbackUrl(port: number, subPath: string = '/'): string {
    return HostFsApi.loopbackUrl(this, port, subPath);
  }
}
