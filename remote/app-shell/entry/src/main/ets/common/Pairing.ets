import http from '@ohos.net.http';
import { LinkLog } from './LinkLog';

/**
 * 配对客户端：直连一台还没配置过的电脑，用 6 位码换令牌。
 *
 * 和 Api 分开是有原因的：配对时手机还不知道该信任谁，端上是随机的，
 * 令牌也还没拿到，所以这里既不做局域网/公网择优，也不做重试与缓存。
 */
export interface PairInfo {
  ok: boolean;
  name: string;
  version: string;
  host: string;
  hostId?: string;
  e2eePub?: string;
  e2ee?: boolean;
  port: number;
  lan: string[];
  publicUrl: string;
  needCode: boolean;
}

export interface PairClaim {
  ok: boolean;
  token: string;
  base: string;
  host: string;
  hostId?: string;
  e2eePub?: string;
  e2ee?: boolean;
  version: string;
  port: number;
  qr: string;
  lan?: string[];
  /** 这次真正连上的地址，配对成功后用它保存。 */
  usedBase: string;
  error: string;
  code: string;
  left: number;
}

/** 二维码里装的东西：电脑地址 + 当前 6 位码。 */
export interface PairLink {
  base: string;
  code: string;
  /** 同一个二维码里附带的备选地址：首个连不上时依次再试。 */
  alts: string[];
}

export interface RemotePairStartResp {
  ok: boolean;
  requestId: string;
  secret: string;
  verifyCode: string;
  host: string;
  hostId?: string;
  e2eePub?: string;
  expiresAt: number;
  error?: string;
}

export interface RemotePairPollResp {
  ok: boolean;
  status: string;
  expiresAt?: number;
  token?: string;
  base?: string;
  host?: string;
  hostId?: string;
  e2eePub?: string;
  e2ee?: boolean;
  version?: string;
  port?: number;
  lan?: string[];
  error?: string;
}

interface RawResp {
  status: number;
  body: string;
}

interface RemoteReqBody {
  deviceName: string;
}

interface RemotePollBody {
  requestId: string;
  secret: string;
}

/**
 * 对面**答了**（码错 / 被拒 / 限流）时抛这个，和「根本没连上」区分开。
 * 只有没连上才值得换下一个地址；答过的服务器再拿同一个一次性码去撞别处没有意义。
 */
export class PairError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

interface CodeBody {
  code: string;
}

export class Pairing {
  /** 补协议、去尾斜杠：用户手输 "192.168.1.3:8901" 也能连。 */
  static normalizeBase(input: string): string {
    let b = input.trim();
    if (b === '') {
      return '';
    }
    if (b.indexOf('://') < 0) {
      b = 'http://' + b;
    }
    while (b.length > 0 && b.charAt(b.length - 1) === '/') {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  /** 解析 dshmobile://pair?b=<地址>&c=<码>（支持从分享口令文本中自动提取）。 */
  static parseLink(text: string): PairLink | null {
    const raw = text.trim();
    const start = raw.indexOf('dshmobile://pair?');
    if (start < 0) {
      return null;
    }
    let s = raw.substring(start);
    const spaceIdx = s.search(/\s/);
    if (spaceIdx > 0) {
      s = s.substring(0, spaceIdx);
    }
    const q = s.indexOf('?');
    if (q < 0) {
      return null;
    }
    const query = s.substring(q + 1);
    let base = '';
    let code = '';
    const alts: string[] = [];
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const eq = parts[i].indexOf('=');
      if (eq < 0) {
        continue;
      }
      const k = parts[i].substring(0, eq);
      let v = parts[i].substring(eq + 1);
      try {
        v = decodeURIComponent(v);
      } catch (e) {
        continue;
      }
      if (k === 'b') {
        base = v;
      } else if (k === 'c') {
        code = v;
      } else if (k === 'a' && v !== '') {
        alts.push(Pairing.normalizeBase(v));
      }
    }
    if (base === '' || !/^\d{6}$/.test(code)) {
      return null;
    }
    return { base: Pairing.normalizeBase(base), code: code, alts: alts };
  }

  private static async req(base: string, path: string, method: string, payload: string): Promise<RawResp> {
    const client = http.createHttp();
    const t0: number = Date.now();
    const isHttps: boolean = base.toLowerCase().startsWith('https://');
    try {
      const opts: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: { 'Content-Type': 'application/json' },
        connectTimeout: isHttps ? 4000 : 2200,
        readTimeout: 6000,
        expectDataType: http.HttpDataType.STRING
      };
      if (method === 'POST') {
        opts.extraData = payload;
      }
      const resp = await client.request(base + path, opts);
      const ms: number = Date.now() - t0;
      LinkLog.record('PAIR', method + ' ' + base + path + ' -> ' + String(resp.responseCode) + ' (' + String(ms) + 'ms)');
      return { status: resp.responseCode, body: resp.result as string };
    } catch (e) {
      const ms: number = Date.now() - t0;
      LinkLog.record('PAIR', method + ' ' + base + path + ' FAIL (' + String(ms) + 'ms) ' + ((e as Error).message ?? ''));
      throw new Error((e as Error).message ?? 'network error');
    } finally {
      client.destroy();
    }
  }

  /** 探一台电脑：拿到名字、版本与它对外的局域网地址。 */
  static async info(base: string): Promise<PairInfo> {
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/info', 'GET', '');
    if (r.status < 200 || r.status >= 300) {
      throw new Error('这台电脑没有开启手机连接（HTTP ' + r.status + '）');
    }
    let o: PairInfo;
    try {
      o = JSON.parse(r.body) as PairInfo;
    } catch (e) {
      throw new Error('连接地址返回的不是有效响应（HTTP ' + r.status + '），请核对端口或隧道');
    }
    if (o.ok !== true) {
      throw new Error('返回内容不是手机连接接口');
    }
    return o;
  }

  /**
   * 用 6 位码换令牌，按顺序试多个地址。
   *
   * 二维码里除了首个地址，还可能带几个备选（其它网卡、公网隧道）。只有当某个
   * 地址**真的连不上**时才换下一个；一旦对面答了（码错 / 被拒 / 限流），
   * 就说明路是通的，立刻把它的答复抛出去，别拿同一个码去撞别处的服务器。
   */
  static async claimAny(bases: readonly string[], code: string,
    onStage?: (stage: number, detail: string) => void): Promise<PairClaim> {
    const tried: string[] = [];
    let last: string = '';
    for (let i = 0; i < bases.length; i++) {
      const one = Pairing.normalizeBase(bases[i]);
      if (one === '' || tried.indexOf(one) >= 0) {
        continue;
      }
      tried.push(one);
      if (onStage !== undefined) {
        onStage(0, '正在尝试第 ' + String(tried.length) + ' / ' + String(bases.length) + ' 条通道…');
      }
      try {
        const res: PairClaim = await Pairing.claim(one, code);
        if (onStage !== undefined) {
          onStage(1, '通道已连通，正在校验安全身份…');
        }
        return res;
      } catch (e) {
        const msg = (e as Error).message;
        if (e instanceof PairError) {
          // 对面答了：说明路是通的，把这个答复原样交给界面，别去撞下一个地址
          console.info('DSH_PAIR reject ' + one + ' status=' + e.status);
          throw new PairError(e.status, e.message);
        }
        last = msg;
        console.info('DSH_PAIR unreachable ' + one + ' :: ' + msg);
      }
    }
    throw new Error(
      '暂时连不上电脑（已自动尝试 ' + tried.length + ' 条通道）。' +
        '请确认电脑上的 DSH 正在运行，网络畅通后点击下方「重新连接」即可。'
    );
  }

  /** 用 6 位码换令牌。仅在网关明确返回 JSON 业务拒答（401/403/429）时抛 PairError 终止回退；530/5xx/非 JSON 均抛普通 Error 以便继续尝试其余候选地址。 */
  static async claim(base: string, code: string): Promise<PairClaim> {
    const body: CodeBody = { code: code.trim() };
    const r = await Pairing.req(Pairing.normalizeBase(base), '/api/pair/claim', 'POST', JSON.stringify(body));
    let o: PairClaim;
    try {
      o = JSON.parse(r.body) as PairClaim;
    } catch (e) {
      if (r.status === 530 || r.status === 502 || r.status === 503 || r.status === 504) {
        throw new Error('公网隧道暂时离线（HTTP ' + String(r.status) + '），请确认电脑端隧道运行中或稍后重试');
      }
      throw new Error('无法解析该入口返回（HTTP ' + String(r.status) + '），隧道或端口可能未就绪');
    }
    if (r.status >= 200 && r.status < 300 && o.ok === true) {
      o.usedBase = Pairing.normalizeBase(base);
      return o;
    }
    if (r.status === 401) {
      const left = typeof o.left === 'number' ? o.left : 0;
      throw new PairError(r.status, left > 0 ? ('配对码不对，还能试 ' + left + ' 次') : '配对码不对');
    }
    if (r.status === 403) {
      throw new PairError(r.status, '电脑上关掉了允许连接，先打开再配对');
    }
    if (r.status === 429) {
      throw new PairError(r.status, '试错太多次，等 5 分钟再试');
    }
    if (r.status >= 500 || r.status === 404) {
      throw new Error('该入口暂时不可用（HTTP ' + String(r.status) + '）');
    }
    throw new PairError(r.status, '配对失败（HTTP ' + r.status + '）');
  }

  /** 向电脑端发起远程配对申请：返回 4 位人工核对码及轮询凭据。 */
  static async requestRemotePair(base: string, deviceName: string): Promise<RemotePairStartResp> {
    const norm: string = Pairing.normalizeBase(base);
    const body: RemoteReqBody = { deviceName: deviceName };
    const r: RawResp = await Pairing.req(norm, '/api/pair/remote/request', 'POST', JSON.stringify(body));
    let o: RemotePairStartResp;
    try {
      o = JSON.parse(r.body) as RemotePairStartResp;
    } catch (e) {
      if (r.status === 530 || r.status === 502 || r.status === 503 || r.status === 504) {
        throw new PairError(r.status, '公网隧道暂时离线（HTTP ' + String(r.status) + '），请确认电脑端 Cloudflare 隧道正在运行并稍后重试');
      }
      throw new PairError(r.status, '无法解析电脑返回（HTTP ' + String(r.status) + '），请确认地址正确且电脑网关已更新');
    }
    if (r.status >= 200 && r.status < 300 && o.ok === true && o.requestId !== '' && o.secret !== '') {
      return o;
    }
    if (r.status === 404) {
      throw new PairError(r.status, '电脑端网关版本较旧，暂不支持远程申请审批，请更新电脑端插件或使用配对口令/6 位码');
    }
    const errMsg: string = o.error !== undefined && o.error !== ''
      ? o.error
      : ('远程配对申请被拒绝（HTTP ' + String(r.status) + '）');
    throw new PairError(r.status, errMsg);
  }

  /** 轮询远程配对审批结果；批准后单次返回令牌与端到端加密公钥。 */
  static async pollRemotePair(base: string, requestId: string, secret: string): Promise<RemotePairPollResp> {
    const norm: string = Pairing.normalizeBase(base);
    const body: RemotePollBody = { requestId: requestId, secret: secret };
    const r: RawResp = await Pairing.req(norm, '/api/pair/remote/poll', 'POST', JSON.stringify(body));
    let o: RemotePairPollResp;
    try {
      o = JSON.parse(r.body) as RemotePairPollResp;
    } catch (e) {
      throw new Error('响应格式异常（HTTP ' + String(r.status) + '）');
    }
    if (r.status === 404 || o.status === 'expired') {
      throw new PairError(404, o.error !== undefined && o.error !== '' ? o.error : '远程配对申请已过期，请重新发起');
    }
    if (o.status === 'rejected') {
      throw new PairError(403, o.error !== undefined && o.error !== '' ? o.error : '对方拒绝了本次远程配对申请');
    }
    return o;
  }
}
