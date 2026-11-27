import { camera, cameraPicker } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import {
  Api,
  Catalog,
  CatalogGroup,
  ExportSignResp,
  GoalView,
  Message,
  MessagesResult,
  ModelRef,
  QueuedItem,
  SessionRow,
  SessionStats,
  TokenUsage,
  ToolStep
} from '../../common/Api';
import { buildSessionMarkdown } from '../../common/ExportMd';
import { FilePart, pickFiles, readFile } from '../../common/Files';
import { fromUris, ImagePart } from '../../common/Images';
import { Outbox, SeenImage as OutboxSeenImage, StashImage, StashItem } from '../../common/Outbox';
import { Saver } from '../../common/Saver';
import { Toast } from '../../common/Toast';
import { PendRow } from '../PendingBoard';

export const EMPTY_TOKENS: TokenUsage = {
  uncachedInputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0
};

export const EMPTY_STATS: SessionStats = {
  turns: 0,
  steps: 0,
  toolCalls: 0,
  tokens: EMPTY_TOKENS
};

export const EMPTY_GOAL: GoalView = {};

export interface ReorderOutcome {
  files: FilePart[];
  queueIds: string[];
  queueChanged: boolean;
}

export interface ResolvedModelState {
  groups: CatalogGroup[];
  modelId: string;
  modelLabel: string;
  effort: string;
}

/** 极简链路状态归一化（L3）：'lan' | 'wan' | 'offline'。 */
export function resolveLinkState(online: boolean, linkMode: string): string {
  if (!online || linkMode === 'offline') {
    return 'offline';
  }
  if (linkMode === 'lan') {
    return 'lan';
  }
  return 'wan';
}

/** 极简链路文案（L3）：局域网·加密 / 局域网 / 公网·加密 / 公网 / 离线。 */
export function formatLinkBadge(online: boolean, linkMode: string, linkEncrypted: boolean): string {
  const st: string = resolveLinkState(online, linkMode);
  if (st === 'offline') {
    return '离线';
  }
  if (st === 'lan') {
    return linkEncrypted ? '局域网·加密' : '局域网';
  }
  return linkEncrypted ? '公网·加密' : '公网';
}

/** 错误分类标题 */
export function errCategoryTitle(msg: string): string {
  const k: string = Api.kind(msg);
  if (k === 'net') return '网络';
  if (k === 'auth') return '访问令牌';
  if (k === 'parse') return '返回格式';
  if (k === 'nobase') return '未连接';
  if (k === 'http') return '电脑端';
  return '未知';
}

/** 根据目录把裸模型 id 映射为展示名。 */
export function modelLabelOf(groups: CatalogGroup[], id: string): string {
  for (let i = 0; i < groups.length; i++) {
    const g: CatalogGroup = groups[i];
    for (let k = 0; k < g.models.length; k++) {
      if (g.models[k].id === id) return g.models[k].name;
    }
  }
  return id;
}

/** 拉取会话模型目录并解析当前模型与推理强度。 */
export async function fetchResolvedModelState(api: Api, sessionId: string): Promise<ResolvedModelState> {
  const c: Catalog = await api.models(sessionId);
  const groups: CatalogGroup[] = c.groups ?? [];
  const cur: ModelRef | null = c.current;
  if (cur !== null && cur !== undefined && (cur.model ?? '') !== '') {
    const mid: string = cur.model ?? '';
    const direct: ResolvedModelState = {
      groups: groups,
      modelId: mid,
      modelLabel: modelLabelOf(groups, mid),
      effort: cur.reasoningEffort ?? ''
    };
    return direct;
  }
  try {
    const rows: SessionRow[] = await api.sessions();
    for (let i = 0; i < rows.length; i++) {
      const r: SessionRow = rows[i];
      if (r.id === sessionId && r.model !== undefined && r.model !== null) {
        const fromRow: ResolvedModelState = {
          groups: groups,
          modelId: r.model.model,
          modelLabel: modelLabelOf(groups, r.model.model),
          effort: r.model.reasoningEffort ?? ''
        };
        return fromRow;
      }
    }
  } catch (e) {
  }
  const fallback: ResolvedModelState = { groups: groups, modelId: '', modelLabel: '', effort: '' };
  return fallback;
}

/** 收敛双路键盘高度（以系统 avoidArea 为准，兜 65% 窗口高度上限与 16vp 手势条抵扣）。 */
export function resolveKeyboardHeightVp(
  kwRep: number,
  kwAvoid: number,
  kwAvoidSeen: boolean,
  winH: number
): number {
  let vp: number = kwRep;
  if (kwAvoidSeen) {
    vp = kwAvoid <= 0 ? 0 : Math.min(kwAvoid, kwRep > 0 ? kwRep : kwAvoid);
  }
  if (winH > 0 && vp > winH * 0.65) {
    vp = winH * 0.6;
  }
  if (vp > 0) {
    vp = vp > 16 ? vp - 16 : 0;
  }
  return vp < 0 ? 0 : vp;
}

/**
 * 几何级防双重避让兜底：
 * 若窗口总高 winH 已知，且聊天页根容器实际底边 (pageGlobalY + pageH) 已被系统 RESIZE / OFFSET
 * 压缩或上推超过 40vp，则扣减系统已避让的高度，杜绝键盘上方空白与输入框顶到标题栏。
 */
export function clampKeyboardByContainer(
  rawKb: number,
  winH: number,
  pageH: number,
  pageGlobalY: number
): number {
  if (rawKb <= 0) {
    return 0;
  }
  if (winH > 120 && pageH > 120) {
    const containerBottom: number = pageGlobalY + pageH;
    const osAvoided: number = winH - containerBottom;
    if (osAvoided > 40) {
      const remain: number = rawKb - osAvoided;
      return remain > 0 ? remain : 0;
    }
  }
  return rawKb;
}

/** 按 seq 增量合并或原地更新消息，保证流式推送与软刷新不重排旧项、不漏掉原地增长。 */
export function mergeMessageList(base: Message[], incoming: Message[]): Message[] {
  if (incoming.length === 0) return base;
  if (base.length === 0) return incoming.slice();
  const out: Message[] = base.slice();
  for (let i = 0; i < incoming.length; i++) {
    const n: Message = incoming[i];
    let replaced: boolean = false;
    for (let j = out.length - 1; j >= 0; j--) {
      if (out[j].seq === n.seq) {
        out[j] = n;
        replaced = true;
        break;
      }
      if (out[j].seq < n.seq) break;
    }
    if (!replaced) {
      if (out.length === 0 || n.seq > out[out.length - 1].seq) {
        out.push(n);
      } else {
        let ins: number = out.length;
        for (let k = 0; k < out.length; k++) {
          if (out[k].seq > n.seq) {
            ins = k;
            break;
          }
        }
        out.splice(ins, 0, n);
      }
    }
  }
  return out;
}

/** 提取消息数组中的图片附件 ID（上限 64），供短签名换取。 */
export function collectImageIds(msgs: Message[]): string[] {
  const ids: string[] = [];
  for (let i = 0; i < msgs.length && ids.length < 64; i++) {
    const imgs = msgs[i].images;
    if (imgs === undefined) continue;
    for (let k = 0; k < imgs.length && ids.length < 64; k++) {
      if (ids.indexOf(imgs[k].id) < 0) ids.push(imgs[k].id);
    }
  }
  return ids;
}

/**
 * 消息列表 ForEach 键（M3）：
 * 编入 m.seq、角色、m.text.length、m.thinking 长度、m.tools 长度与工具状态签名。
 */
export function buildMsgForEachKey(m: Message): string {
  const thinkLen: number = m.thinking !== undefined ? m.thinking.length : 0;
  const toolLen: number = m.tools !== undefined ? m.tools.length : 0;
  let toolSig: string = '';
  if (m.tools !== undefined && m.tools.length > 0) {
    const bits: string[] = [];
    for (let i = 0; i < m.tools.length; i++) {
      const s: ToolStep = m.tools[i];
      bits.push(s.status + ':' + String(s.summary.length));
    }
    toolSig = bits.join(',');
  }
  const turnSig: string = m.turn !== undefined ? (m.turn.status + ':' + String(m.turn.tokensOut)) : '';
  const imgLen: number = m.images !== undefined ? m.images.length : 0;
  return String(m.seq) + '_' + m.role + '_' + String(m.text.length) + '_' +
    String(thinkLen) + '_' + String(toolLen) + '_' + toolSig + '_' + turnSig + '_' + String(imgLen);
}

/** 构造待发送板行列表（本地待发文件 + 宿主排队消息）。 */
export function buildPendRows(pendFiles: FilePart[], queueItems: QueuedItem[]): PendRow[] {
  const out: PendRow[] = [];
  for (let i = 0; i < pendFiles.length; i++) {
    const it: FilePart = pendFiles[i];
    out.push({
      key: 'f' + String(i) + it.name,
      kind: 'file',
      idx: i,
      id: '',
      title: it.name,
      sub: '随下一条消息一起发出',
      thumb: ''
    });
  }
  for (let i = 0; i < queueItems.length; i++) {
    const q: QueuedItem = queueItems[i];
    const hasImg: boolean = q.images !== undefined && q.images.length > 0;
    let title: string = q.text;
    if (title === '') {
      title = hasImg ? ('图片 ' + String(q.images === undefined ? 0 : q.images.length) + ' 张') : '待发送';
    }
    out.push({
      key: 'q' + q.id,
      kind: 'queue',
      idx: i,
      id: q.id,
      title: title,
      sub: '',
      thumb: ''
    });
  }
  return out;
}

/** 待发送板拖拽排序计算（保留本地未发送图片 pendImgs 不受影响，I3）。 */
export function reorderPendList(
  pendFiles: FilePart[],
  queueItems: QueuedItem[],
  from: number,
  to: number
): ReorderOutcome | null {
  const rows: PendRow[] = buildPendRows(pendFiles, queueItems);
  if (from < 0 || from >= rows.length || to < 0 || to >= rows.length || from === to) return null;
  const moved: PendRow[] = rows.slice();
  const one: PendRow[] = moved.splice(from, 1);
  moved.splice(to, 0, one[0]);
  const files: FilePart[] = [];
  const ids: string[] = [];
  for (let i = 0; i < moved.length; i++) {
    const r: PendRow = moved[i];
    if (r.kind === 'file') {
      if (r.idx >= 0 && r.idx < pendFiles.length) files.push(pendFiles[r.idx]);
    } else if (r.kind === 'queue') {
      ids.push(r.id);
    }
  }
  const oldIds: string[] = queueItems.map((q: QueuedItem) => q.id);
  const outcome: ReorderOutcome = {
    files: files,
    queueIds: ids,
    queueChanged: ids.join(',') !== oldIds.join(',')
  };
  return outcome;
}

/** 将 ImagePart 数组转换为 Outbox 持久化图片数组。 */
export function toStashImages(imgs: ImagePart[]): StashImage[] {
  const stash: StashImage[] = [];
  for (let i = 0; i < imgs.length; i++) {
    stash.push({ mediaType: imgs[i].mediaType, name: imgs[i].name, data: imgs[i].data });
  }
  return stash;
}

/** 按原顺序逐条重发 Outbox 影子消息并逐条核销。 */
export async function replayOutboxItems(
  api: Api,
  sessionId: string,
  items: StashItem[],
  onStep: (left: StashItem[]) => void
): Promise<void> {
  for (let i = 0; i < items.length; i++) {
    const it: StashItem = items[i];
    const imgs: ImagePart[] = [];
    for (let k = 0; k < it.images.length; k++) {
      const im: StashImage = it.images[k];
      if (im.data !== '') imgs.push({ mediaType: im.mediaType, data: im.data, name: im.name });
    }
    const key: string = it.key !== undefined && it.key !== ''
      ? it.key
      : ('rescue-' + sessionId + '-' + String(it.t));
    if (it.kind === 'send' && imgs.length === 0) {
      await api.send(sessionId, it.text, 'queue', key);
    } else {
      await api.sendOutbox(sessionId, it.text, imgs, [], 'queue', key);
    }
    Outbox.drop(sessionId, [it]);
    onStep(Outbox.mine(sessionId));
  }
}

/** Outbox 本地影子与服务端真实消息/队列对账，返回仍需兜底重发的项。 */
export function reconcileOutboxItems(sessionId: string, r: MessagesResult): StashItem[] {
  try {
    Outbox.load();
    const seen: string[] = [];
    const seenImgs: OutboxSeenImage[] = [];
    for (let i = 0; i < r.messages.length; i++) {
      const m: Message = r.messages[i];
      if (m.role === 'user') {
        seen.push((m.text === undefined ? '' : m.text).trim());
        if (m.images !== undefined && m.images.length > 0) {
          seenImgs.push({ at: m.time, count: m.images.length });
        }
      }
    }
    Outbox.settle(sessionId, seen);
    Outbox.settleImages(sessionId, seenImgs);
    const q: QueuedItem[] = r.queue === undefined ? [] : r.queue;
    return q.length === 0 ? Outbox.mine(sessionId) : [];
  } catch (e) {
    return [];
  }
}

/** 选本地文件并读取为 FilePart 列表。 */
export async function pickLocalFileParts(room: number): Promise<FilePart[] | null> {
  const uris: string[] = await pickFiles(room);
  if (uris.length === 0) return null;
  const parts: FilePart[] = [];
  for (let i = 0; i < uris.length; i++) {
    const one: FilePart | undefined = await readFile(uris[i]);
    if (one !== undefined) parts.push(one);
  }
  return parts;
}

/** 调起系统相机拍照并转为 ImagePart 列表。 */
export async function captureCameraParts(ctx: common.UIAbilityContext): Promise<ImagePart[] | null> {
  const profile: cameraPicker.PickerProfile = {
    cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK
  };
  const res: cameraPicker.PickerResult = await cameraPicker.pick(
    ctx,
    [cameraPicker.PickerMediaType.PHOTO],
    profile
  );
  if (res.resultCode !== 0 || res.resultUri === '') return null;
  return await fromUris([res.resultUri]);
}

/** 导出会话 Markdown 到系统文件保存器（本地兜底构建）。 */
export async function saveSessionMarkdown(
  ctx: common.UIAbilityContext,
  title: string,
  sessionId: string,
  msgs: Message[]
): Promise<boolean> {
  const safeTitle: string = title !== '' ? title : '会话';
  const d: Date = new Date();
  const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  const stamp: string = String(d.getFullYear()) + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes());
  const text: string = buildSessionMarkdown(safeTitle, sessionId, msgs, stamp);
  return await Saver.saveText(ctx, text, safeTitle + '.md');
}

/**
 * 导出会话日志（F09 /export）：
 * - format === 'markdown'：优先调用服务端短签名导出，旧宿主不支持时自动回退本地 Markdown 构建；
 * - format === 'zip'：调用服务端完整会话包签名并通过 Saver 下载保存到手机。
 */
export async function exportSessionByFormat(
  api: Api,
  ctx: common.UIAbilityContext,
  sessionId: string,
  title: string,
  msgs: Message[],
  format: string
): Promise<boolean> {
  const fmt: string = format === 'zip' ? 'zip' : 'markdown';
  try {
    const signed: ExportSignResp = await api.exportSessionUrl(sessionId, fmt);
    if (signed.ok && signed.url !== '') {
      return await Saver.save(ctx, signed.url, signed.filename, api.bearer());
    }
  } catch (e) {
    if (fmt === 'zip') {
      throw new Error((e as Error).message);
    }
  }
  if (fmt === 'zip') {
    throw new Error('电脑端暂不支持下载完整 ZIP 会话包，请更新宿主后重试');
  }
  return await saveSessionMarkdown(ctx, title, sessionId, msgs);
}

/** 会话置顶切换并标记列表需刷新。 */
export async function toggleSessionPinState(api: Api, sessionId: string, nextPinned: boolean): Promise<boolean> {
  try {
    await api.pin(sessionId, nextPinned);
    AppStorage.setOrCreate('listDirty', Date.now());
    Toast.ok(nextPinned ? '已置顶会话' : '已取消置顶');
    return true;
  } catch (e) {
    Toast.err('操作失败：' + (e as Error).message);
    return false;
  }
}

/** 归档当前会话并标记列表需刷新。 */
export async function archiveSessionNow(api: Api, sessionId: string): Promise<boolean> {
  try {
    await api.archive(sessionId);
    AppStorage.setOrCreate('listDirty', Date.now());
    Toast.ok('已归档此会话');
    return true;
  } catch (e) {
    Toast.err('归档失败：' + (e as Error).message);
    return false;
  }
}

/** 分支会话（整段或指定轮次）并弹提示。 */
export async function forkSessionNow(api: Api, sessionId: string, atSeq: number, okText: string): Promise<boolean> {
  try {
    const id: string = atSeq >= 0 ? await api.fork(sessionId, atSeq) : await api.fork(sessionId);
    if (id === '') {
      Toast.err('分支失败');
      return false;
    }
    AppStorage.setOrCreate('listDirty', Date.now());
    Toast.ok(okText);
    return true;
  } catch (e) {
    Toast.err('分支失败：' + (e as Error).message);
    return false;
  }
}

/** 执行在线消息或附件发送请求，并在运行态下记录 Outbox 影子。 */
export async function dispatchOnlineSend(
  api: Api,
  sessionId: string,
  text: string,
  imgs: ImagePart[],
  files: FilePart[],
  mode: string,
  idem: string,
  runningNow: boolean
): Promise<void> {
  const route: string = (imgs.length > 0 || files.length > 0) ? 'outbox' : 'send';
  if (imgs.length > 0 || files.length > 0) {
    await api.sendOutbox(sessionId, text, imgs, files, mode, idem);
    const bits: string[] = [];
    if (imgs.length > 0) bits.push(String(imgs.length) + ' 张图片');
    if (files.length > 0) bits.push(String(files.length) + ' 个文件');
    Toast.ok('已发送 ' + bits.join(' + '));
  } else {
    await api.send(sessionId, text, mode, idem);
  }
  if (runningNow) {
    Outbox.remember(sessionId, text, toStashImages(imgs), idem, route);
  }
}

/** 离线时将待发文本与图片存入 Outbox。 */
export function stashOfflineSend(
  sessionId: string,
  text: string,
  imgs: ImagePart[],
  files: FilePart[],
  idem: string
): boolean {
  if (files.length > 0) {
    Toast.err('离线时不能发送文件，联网后再试');
    return false;
  }
  const route: string = imgs.length > 0 ? 'outbox' : 'send';
  if (!Outbox.remember(sessionId, text, toStashImages(imgs), idem, route)) {
    Toast.err('存不进本地，先别发：检查手机存储空间');
    return false;
  }
  Toast.ok('当前离线，消息已存在手机上');
  return true;
}
