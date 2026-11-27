/**
 * 反馈（工单）客户端：直连 Cloudflare Worker，不经过配对的电脑。
 *
 * 为什么单独写一套而不是复用 `Api`：
 * - `Api` 的每条请求都要电脑在线（地址 + 令牌）；反馈的价值恰恰是「电脑没开也能提」。
 * - 反馈只需要 6 条固定接口，Worker 侧是我们自己的代码（`remote/feedback-worker`）。
 *
 * 设备身份：`installId` 是手机本地生成的 32 位 hex，存在 preferences 里，
 * 卸载重装会变。它只用来「列出我这台手机的工单」，不含任何硬件标识。
 */

import { http } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppCtx } from './AppCtx';
import { bytes, stamp } from './Format';

/** 反馈后端域名（Cloudflare Worker + D1 + R2，仅在用户主动提交反馈工单时直连）。 */
export const FEEDBACK_BASE: string = 'https://feedback.juo.de5.net';

export function isFeedbackEnabled(): boolean {
  return FEEDBACK_BASE.trim() !== '';
}

/** 反馈类型。 */
export interface FeedbackKind {
  id: string;
  name: string;
}

export const FEEDBACK_KINDS: FeedbackKind[] = [
  { id: 'bug', name: '问题反馈' },
  { id: 'feature', name: '功能建议' },
  { id: 'ux', name: '体验问题' },
  { id: 'other', name: '其他' }
];

/** 一条工单（列表与详情共用）。 */
export interface Ticket {
  id: string;
  kind: string;
  title: string;
  body: string;
  status: string;
  app_version: string;
  env: string;
  contact: string;
  notify: boolean;
  created_at: number;
  updated_at: number;
  replies: TicketReply[];
  files: TicketFile[];
}

export interface TicketReply {
  ticket: string;
  author: string;
  text: string;
  at: number;
}

export interface TicketFile {
  name: string;
  kind: string;
  size: number;
  at: number;
}

/** 新建工单的入参。 */
export interface NewTicket {
  kind: string;
  body: string;
  env: string;
  contact: string;
  notify: boolean;
}

/** 上传附件的类别（与 Worker 的限额一一对应）。 */
export interface UploadSpec {
  kind: string;
  label: string;
  limit: number;
  count: number;
  mime: string;
}

export const UPLOADS: UploadSpec[] = [
  { kind: 'screenshot', label: '截图', limit: 10 * 1024 * 1024, count: 3, mime: 'image/png' },
  { kind: 'video', label: '录屏', limit: 30 * 1024 * 1024, count: 1, mime: 'video/mp4' },
  { kind: 'log', label: '日志与样本', limit: 20 * 1024 * 1024, count: 1, mime: 'application/octet-stream' }
];

/** 本机一直用的存储桶（和草稿、状态标记同一套 preferences）。 */
const STORE: string = 'dsh_mobile_fb';
const KEY_INSTALL: string = 'install';
const KEY_NOTIFY: string = 'notify';
const KEY_CONTACT: string = 'contact';

/** 状态的中文名与色调。 */
export function statusText(s: string): string {
  if (s === 'open') {
    return '待处理';
  }
  if (s === 'doing') {
    return '处理中';
  }
  if (s === 'done') {
    return '已完成';
  }
  if (s === 'wontfix') {
    return '不修了';
  }
  return s;
}

/** KB / MB 的人类可读写法。 */
/** 与消息附件、文件面板共用一套单位（Format.bytes），避免 MiB/MB 混用。 */
export function sizeText(n: number): string {
  return bytes(n);
}

/** 日期：`11-23 14:05`，统一委托 Format.stamp。 */
export function timeText(ms: number): string {
  return stamp(ms);
}

function store(): preferences.Preferences {
  const opts: preferences.Options = { name: STORE };
  return preferences.getPreferencesSync(AppCtx.ability(), opts);
}

/** 本机的匿名设备号（32 位 hex）。 */
export function installId(): string {
  const p: preferences.Preferences = store();
  const saved: string = p.getSync(KEY_INSTALL, '') as string;
  if (saved.length === 32) {
    return saved;
  }
  const bytes: Uint8Array = cryptoFramework.createRandom().generateRandomSync(16).data;
  let out: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const one: string = bytes[i].toString(16);
    out += one.length === 1 ? '0' + one : one;
  }
  p.putSync(KEY_INSTALL, out);
  p.flushSync();
  return out;
}

/** 上报新工单时的默认开关（用户上次的选择）。 */
export function notifyPref(): boolean {
  return store().getSync(KEY_NOTIFY, true) as boolean;
}

export function setNotifyPref(on: boolean): void {
  const p: preferences.Preferences = store();
  p.putSync(KEY_NOTIFY, on);
  p.flushSync();
}

/** 上次填的联系方式，下次自动带出来。 */
export function contactPref(): string {
  return store().getSync(KEY_CONTACT, '') as string;
}

export function setContactPref(v: string): void {
  const p: preferences.Preferences = store();
  p.putSync(KEY_CONTACT, v);
  p.flushSync();
}

/** App 版本，例如 `1.1.18`。 */
export function appVersion(): string {
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    return info.versionName;
  } catch (e) {
    return '';
  }
}

/** 网络类型：wifi+cellular / wifi / cellular / ethernet / vpn / offline / other。 */
function netText(): string {
  try {
    const bearers: number[] = [];
    const addCaps = (caps?: connection.NetCapabilities): void => {
      if (caps === undefined || caps.bearerTypes === undefined) {
        return;
      }
      for (let i = 0; i < caps.bearerTypes.length; i++) {
        const b: number = caps.bearerTypes[i];
        if (bearers.indexOf(b) < 0) {
          bearers.push(b);
        }
      }
    };
    try {
      const all: connection.NetHandle[] = connection.getAllNetsSync();
      if (all !== undefined) {
        for (let i = 0; i < all.length; i++) {
          const h: connection.NetHandle = all[i];
          if (h !== undefined && h.netId !== 0) {
            try {
              addCaps(connection.getNetCapabilitiesSync(h));
            } catch (_e) {
            }
          }
        }
      }
    } catch (_e) {
    }
    try {
      const net: connection.NetHandle | undefined = connection.getDefaultNetSync();
      if (net !== undefined && net.netId !== 0) {
        addCaps(connection.getNetCapabilitiesSync(net));
      }
    } catch (_e) {
    }
    if (bearers.length === 0) {
      return 'offline';
    }
    const hasWifi: boolean = bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
    const hasCell: boolean = bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
    const hasEth: boolean = bearers.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0;
    const hasVpn: boolean = bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0;
    if (hasWifi && hasCell) {
      return 'wifi+cellular';
    }
    if (hasWifi) {
      return 'wifi';
    }
    if (hasEth) {
      return 'ethernet';
    }
    if (hasCell) {
      return 'cellular';
    }
    if (hasVpn) {
      return 'vpn';
    }
    return 'other';
  } catch (e) {
    return 'unknown';
  }
}

/**
 * 「运行环境」一行，形如
 * `1.1.18 (1000280) · OpenHarmony 6.0.0.1 (API 26) - SCA-AL00 · wifi`。
 * 只有版本、机型与网络类型，不含账号、对话内容、密钥与本地文件。
 */
export function envLine(): string {
  let code: string = '';
  try {
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    code = '' + info.versionCode;
  } catch (e) {
    code = '';
  }
  const ver: string = appVersion();
  const sys: string = deviceInfo.osFullName !== undefined ? deviceInfo.osFullName : '';
  const api: string = '' + deviceInfo.sdkApiVersion;
  const model: string = deviceInfo.marketName !== undefined && deviceInfo.marketName !== ''
    ? deviceInfo.marketName : deviceInfo.productModel;
  const head: string = code !== '' ? ver + ' (' + code + ')' : ver;
  return head + ' · ' + sys + ' (API ' + api + ') - ' + model + ' · ' + netText();
}

/** 一条错误响应的可读文案。 */
interface FailBody {
  code?: string;
  message?: string;
}

function reasonOf(code: number, body: string): string {
  let msg: string = '';
  if (body.startsWith('{')) {
    try {
      const j: FailBody = JSON.parse(body) as FailBody;
      msg = j.message !== undefined ? j.message : '';
    } catch (e) {
      msg = '';
    }
  }
  if (code === 429) {
    return '今天提交次数过多，请明天再试。';
  }
  if (code === 413) {
    return msg !== '' ? '文件太大：' + msg : '文件太大。';
  }
  if (msg !== '') {
    return msg;
  }
  return '请求失败（HTTP ' + code + '）。';
}

/** 发一次请求，返回响应正文；非 2xx 抛带文案的 Error。 */
async function send(method: http.RequestMethod, path: string, install: string,
  body: string, extra: Record<string, string>, bin?: ArrayBuffer): Promise<string> {
  if (!isFeedbackEnabled()) {
    throw new Error('当前版本未启用在线反馈服务');
  }
  const req: http.HttpRequest = http.createHttp();
  const header: Record<string, string> = { 'x-install': install };
  const keys: string[] = Object.keys(extra);
  for (let i = 0; i < keys.length; i++) {
    header[keys[i]] = extra[keys[i]];
  }
  console.info('DSH_FB ' + method + ' ' + path + ' install=' + install.slice(0, 6));
  try {
    const res: http.HttpResponse = await req.request(FEEDBACK_BASE + path, {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 8000,
      readTimeout: 20000,
      extraData: bin !== undefined ? bin : (body !== '' ? body : undefined)
    });
    const text: string = typeof res.result === 'string' ? res.result as string : '';
    console.info('DSH_FB ' + path + ' -> ' + res.responseCode + ' len=' + text.length);
    if (res.responseCode < 200 || res.responseCode >= 300) {
      console.info('DSH_FB fail body=' + text.slice(0, 160));
      throw new Error(reasonOf(res.responseCode, text));
    }
    return text;
  } catch (e) {
    const err = e as BusinessError;
    console.info('DSH_FB thrown code=' + (err === undefined ? '?' : err.code) + ' msg=' +
      (err === undefined ? '?' : err.message));
    if (err !== undefined && err.message !== undefined && err.message !== '') {
      throw new Error(err.message);
    }
    throw new Error('连不上反馈服务，检查一下网络。');
  } finally {
    req.destroy();
  }
}

/** GET，带上匿名设备号。 */
export async function getJson(path: string): Promise<string> {
  return await send(http.RequestMethod.GET, path, installId(), '', {});
}

/** 提交工单，返回工单号。 */
export async function submit(t: NewTicket): Promise<string> {
  const payload: string = JSON.stringify({
    kind: t.kind,
    body: t.body,
    env: t.env,
    contact: t.contact,
    notify: t.notify,
    appVersion: appVersion()
  });
  const text: string = await send(http.RequestMethod.POST, '/v1/tickets', installId(), payload,
    { 'content-type': 'application/json; charset=utf-8' });
  const j = JSON.parse(text) as Record<string, string>;
  return j.id;
}

/** 我提过的工单（新的在前）。 */
export async function mine(): Promise<Ticket[]> {
  const text: string = await getJson('/v1/mine?install=' + installId());
  const j = JSON.parse(text) as Record<string, Object>;
  const rows = j.tickets as Ticket[];
  return rows === undefined ? [] : rows;
}

/** 一条工单的详情（含回复与附件清单）。 */
export async function detail(id: string): Promise<Ticket> {
  const text: string = await getJson('/v1/tickets/' + encodeURIComponent(id));
  const j = JSON.parse(text) as Record<string, Object>;
  return j.ticket as Ticket;
}

/** 上传一个附件（原始字节，不做 base64）。 */
export async function upload(id: string, spec: UploadSpec, path: string, name: string): Promise<void> {
  console.info('DSH_FB up open ' + spec.kind + ' path=' + path.slice(0, 64) + ' name=' + name);
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  } catch (e) {
    const pe = e as BusinessError;
    console.info('DSH_FB up openfail code=' + (pe === undefined ? '?' : pe.code) + ' msg=' +
      (pe === undefined ? '?' : pe.message));
    throw new Error(spec.label + '打不开：' + (pe === undefined ? '未知原因' : pe.message));
  }
  try {
    const st = fileIo.statSync(file.fd);
    console.info('DSH_FB up size=' + st.size);
    if (st.size <= 0) {
      throw new Error(spec.label + '是空文件。');
    }
    if (st.size > spec.limit) {
      throw new Error(spec.label + '不能超过 ' + sizeText(spec.limit) + '。');
    }
    const buf = new ArrayBuffer(st.size);
    const read = fileIo.readSync(file.fd, buf);
    console.info('DSH_FB up read=' + read);
    if (read <= 0) {
      throw new Error(spec.label + '读不出来。');
    }
    await send(http.RequestMethod.POST, '/v1/tickets/' + encodeURIComponent(id) + '/files?kind=' + spec.kind,
      installId(), '', { 'content-type': spec.mime, 'x-name': encodeURIComponent(name) },
      buf.slice(0, read));
    console.info('DSH_FB up done ' + spec.kind);
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (e) {
        console.info('DSH_FB up closefail');
      }
    }
  }
}

/** base64 上传（截图从相册读出来时已经是字节，这里给的是 uri → 直接读文件）。 */
export function uploadText(id: string, spec: UploadSpec, text: string, name: string): Promise<void> {
  const encoded: Uint8Array | undefined = util.TextEncoder.create('utf-8').encodeInto(text);
  const data: Uint8Array = encoded !== undefined ? encoded : new Uint8Array(0);
  const buf: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
  return send(http.RequestMethod.POST, '/v1/tickets/' + encodeURIComponent(id) + '/files?kind=' + spec.kind,
    installId(), '', { 'content-type': spec.mime, 'x-name': encodeURIComponent(name) }, buf).then(() => {});
}

/** 复制用的工单全文：工单号、内容、设备信息、附件清单。 */
export function ticketText(t: Ticket): string {
  const lines: string[] = [];
  lines.push('【' + t.id + '】' + statusText(t.status));
  lines.push(t.title);
  lines.push('');
  lines.push(t.body);
  lines.push('');
  lines.push('运行环境：' + (t.env !== '' ? t.env : '（未采集）'));
  if (t.contact !== '') {
    lines.push('联系方式：' + t.contact);
  }
  lines.push('提交时间：' + timeText(t.created_at));
  if (t.files !== undefined && t.files.length > 0) {
    const parts: string[] = [];
    for (let i = 0; i < t.files.length; i++) {
      parts.push(t.files[i].name + ' (' + sizeText(t.files[i].size) + ')');
    }
    lines.push('附件：' + parts.join('、'));
  }
  if (t.replies !== undefined && t.replies.length > 0) {
    lines.push('');
    lines.push('— 处理记录 —');
    for (let i = 0; i < t.replies.length; i++) {
      const r: TicketReply = t.replies[i];
      lines.push(timeText(r.at) + ' ' + (r.author === 'admin' ? '开发者' : '我') + '：' + r.text);
    }
  }
  return lines.join('\n');
}
