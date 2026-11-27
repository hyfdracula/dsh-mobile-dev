import http from '@ohos.net.http';
import { util } from '@kit.ArkTS';
import { classifyError, friendlyError, httpMethodOf, isLanUrl, newIdemKey, sleep } from './ApiUtil';
import { RawResult, SessionRow, StageCallback } from './ApiTypes';
import { LinkLog } from './LinkLog';
import { Net } from './Net';
import { E2eeClient, E2eeHttpCaller, E2eeRawHttpResp, E2eeRpcResult } from './crypto/E2ee';

/** SSE 静默超时阈值：服务端每 15 秒发一次 `: ping`，超过 42 秒无任何字节视作断流回退轮询。 */
const SSE_IDLE_TIMEOUT_MS: number = 42000;

interface InfoProbeResp {
  ok?: boolean;
  hostId?: string;
}

/**
 * HTTP 与 SSE 传输底座：
 * 承载局域网/公网双入口自动择优、并发局域网探活、连接阶段回调、LinkLog 脱敏诊断埋点、
 * 短签名缓存以及基于 http.createHttp() requestInStream 的增量 SSE 客户端。
 */
export class ApiTransport {
  /** 最近几次请求失败：反馈页「复制诊断信息」带上它，复现问题不用再让用户翻日志。 */
  protected static errRing: string[] = [];
  /** 外壳巡检拉到的最新会话列表内存缓存，供 SessionList 直接复用。 */
  protected static sharedRows: SessionRow[] = [];
  protected static sharedRowsAt: number = 0;

  static noteError(msg: string): void {
    const t: Date = new Date();
    const hh: string = (t.getHours() < 10 ? '0' : '') + t.getHours();
    const mm: string = (t.getMinutes() < 10 ? '0' : '') + t.getMinutes();
    ApiTransport.errRing.push(hh + ':' + mm + ' ' + LinkLog.sanitize(msg));
    while (ApiTransport.errRing.length > 8) {
      ApiTransport.errRing.shift();
    }
  }

  static recentErrors(): string[] {
    return ApiTransport.errRing.slice();
  }

  static newIdemKey(): string {
    return newIdemKey();
  }

  static kind(msg: string): string {
    return classifyError(msg);
  }

  static sharedSessions(): SessionRow[] {
    return ApiTransport.sharedRows.slice();
  }

  static sharedSessionsUpdatedAt(): number {
    return ApiTransport.sharedRowsAt;
  }

  token: string;
  /** true 时跳过局域网探测，强制走隧道入口。 */
  forceWan: boolean = false;
  /** 仅局域网：探不到也不回退隧道。 */
  lanOnly: boolean = false;
  /** 同一个 Wi-Fi 下自动改走局域网直连。 */
  autoLan: boolean = true;
  /** 是否启用端到端加密（L6 Noise_IK 信封），默认开启；旧宿主返回 404 自动回退直连。 */
  e2eeEnabled: boolean = true;
  /** 可选的连接阶段观察者（供重连面板展示分阶段进度）。 */
  onStage?: StageCallback;

  protected lanBase: string;
  protected wanBase: string;
  protected chosen: string = '';
  protected nextLanProbe: number = 0;
  protected lanDownUntil: number = 0;
  protected lanFailStreak: number = 0;
  protected offlineFailStreak: number = 0;
  protected lanCands: string[] = [];
  protected inflightProbe: Promise<string> | null = null;
  protected inflightBase: Promise<string> | null = null;
  protected bgLanProbeGen: number = -1;
  protected rebaseGen: number = 0;
  protected pinnedHostId: string = '';
  protected e2ee: E2eeClient = new E2eeClient();

  /** 图片附件短签名缓存：id -> "e=...&sig=..." 与过期秒。 */
  readonly attSig: Map<string, string> = new Map<string, string>();
  readonly attExp: Map<string, number> = new Map<string, number>();
  /** 工作区原图短签名缓存：`sid|path` -> "e=...&sig=..." 与过期秒。 */
  readonly rawSig: Map<string, string> = new Map<string, string>();
  readonly rawExp: Map<string, number> = new Map<string, number>();
  /** 本机开发服端口短签名缓存：port -> "e=...&sig=..." 与过期秒。 */
  readonly lbSig: Map<number, string> = new Map<number, string>();
  readonly lbExp: Map<number, number> = new Map<number, number>();

  constructor(wanBase: string, token: string, lanBase: string = '') {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.token = token;
    if (this.lanBase !== '') {
      this.lanCands.push(this.lanBase);
    }
  }

  /** 更新共享会话缓存并通知订阅方（ShellPage 巡检成功后调用）。 */
  cacheSessions(rows: SessionRow[]): void {
    ApiTransport.sharedRows = rows.slice();
    ApiTransport.sharedRowsAt = Date.now();
    AppStorage.setOrCreate('sharedSessionsTick', ApiTransport.sharedRowsAt);
  }

  /** 读取最近一次缓存的会话列表副本。 */
  cachedSessions(): SessionRow[] {
    return ApiTransport.sharedRows.slice();
  }

  cachedSessionsUpdatedAt(): number {
    return ApiTransport.sharedRowsAt;
  }

  /** 当前实际使用的入口，供界面展示。 */
  currentBase(): string {
    return this.chosen !== '' ? this.chosen : this.wanBase;
  }

  /** 给 Saver 用的 bearer 值；只用于请求头，绝不拼入 URL。 */
  bearer(): string {
    return 'Bearer ' + this.token;
  }

  setForceWan(v: boolean): void {
    this.forceWan = v;
    this.chosen = '';
  }

  setAutoLan(v: boolean): void {
    this.autoLan = v;
    this.chosen = '';
  }

  setLanOnly(v: boolean): void {
    this.lanOnly = v;
    this.chosen = '';
  }

  isLan(): boolean {
    if (this.chosen === '') {
      return false;
    }
    if (this.chosen !== this.wanBase) {
      return true;
    }
    return isLanUrl(this.wanBase);
  }

  lanCandidates(): string[] {
    const out: string[] = [];
    if (this.lanBase !== '') {
      out.push(this.lanBase);
    }
    for (let i = 0; i < this.lanCands.length; i++) {
      if (out.indexOf(this.lanCands[i]) < 0) {
        out.push(this.lanCands[i]);
      }
    }
    return out;
  }

  onWan(): boolean {
    if (this.chosen === '') {
      return true;
    }
    return !this.isLan();
  }

  /** 检查新接收的主机公钥是否与当前已钉扎的身份一致，防止静默换钥。 */
  canAcceptE2eeMeta(hostId: string, hostPubB64: string): boolean {
    const cleanHid: string = hostId.trim();
    const cleanPub: string = hostPubB64.trim();
    if (cleanHid === '' || cleanPub === '') {
      return false;
    }
    if (this.pinnedHostId !== '' && cleanHid !== this.pinnedHostId) {
      return false;
    }
    const existingHid: string = this.e2ee.configuredHostId();
    const existingPub: string = this.e2ee.configuredPub();
    if (existingPub !== '' && existingPub !== cleanPub &&
      (existingHid === '' || existingHid === cleanHid)) {
      return false;
    }
    return true;
  }

  /** 配置当前主机的端到端加密身份（hostId + X25519 公钥）。 */
  configureE2ee(hostId: string, hostPubB64: string): void {
    const cleanHid: string = hostId.trim();
    const cleanPub: string = hostPubB64.trim();
    if (cleanHid === '' || cleanPub === '') {
      return;
    }
    if (!this.canAcceptE2eeMeta(cleanHid, cleanPub)) {
      LinkLog.record('E2EE', 'host pubkey or hostId mismatch ignored');
      AppStorage.setOrCreate('e2eeKeyMismatch', cleanHid);
      return;
    }
    if (this.pinnedHostId === '') {
      this.pinnedHostId = cleanHid;
    }
    this.e2ee.configure(cleanHid, cleanPub);
  }

  setE2eeEnabled(v: boolean): void {
    this.e2eeEnabled = v;
    if (!v) {
      this.e2ee.reset(false);
    }
    this.syncLinkStatus(this.wanBase === '');
  }

  isEncrypted(): boolean {
    return this.e2eeEnabled && this.e2ee.isActive();
  }

  /** 将当前链路形态与加密状态同步到 AppStorage，供顶栏状态徽标实时渲染（L3）。 */
  syncLinkStatus(offline: boolean = false): void {
    let mode: string = 'offline';
    if (!offline && this.wanBase !== '') {
      mode = this.isLan() ? 'lan' : 'wan';
    }
    AppStorage.setOrCreate('linkMode', mode);
    AppStorage.setOrCreate('linkEncrypted', !offline && this.isEncrypted());
  }

  rebase(
    wanBase: string,
    token: string,
    lanBase: string = '',
    lanList: string[] = [],
    hostId: string = '',
    e2eePub: string = ''
  ): void {
    this.wanBase = wanBase.replace(/\/+$/, '');
    this.lanBase = lanBase.replace(/\/+$/, '');
    this.lanCands = [];
    if (this.lanBase !== '') {
      this.lanCands.push(this.lanBase);
    }
    for (let i = 0; i < lanList.length; i++) {
      const one: string = lanList[i].replace(/\/+$/, '');
      if (one !== '' && this.lanCands.indexOf(one) < 0) {
        this.lanCands.push(one);
      }
    }
    this.rebaseGen++;
    this.pinnedHostId = hostId.trim();
    this.token = token;
    this.chosen = '';
    this.lanDownUntil = 0;
    this.lanFailStreak = 0;
    this.offlineFailStreak = 0;
    this.nextLanProbe = 0;
    this.inflightProbe = null;
    this.inflightBase = null;
    this.e2ee.reset(true);
    if (hostId !== '' && e2eePub !== '') {
      this.e2ee.configure(hostId, e2eePub);
    }
    this.attSig.clear();
    this.attExp.clear();
    this.rawSig.clear();
    this.rawExp.clear();
    this.lbSig.clear();
    this.lbExp.clear();
    ApiTransport.sharedRows = [];
    ApiTransport.sharedRowsAt = 0;
    this.syncLinkStatus(this.wanBase === '');
    LinkLog.record('NET', 'rebase wan=' + (this.wanBase !== '' ? this.wanBase : '-') +
      ' lan=' + (this.lanBase !== '' ? this.lanBase : '-'));
    console.info('DSH_BASE rebase ' + this.wanBase + ' lan=' + (this.lanBase !== '' ? this.lanBase : '-'));
  }

  private emitStage(cb: StageCallback | undefined, stage: number, detail: string): void {
    if (cb !== undefined) {
      cb(stage, detail);
    } else if (this.onStage !== undefined) {
      this.onStage(stage, detail);
    }
  }

  async rawGet(url: string, timeoutMs: number, auth: boolean): Promise<RawResult> {
    const req = http.createHttp();
    const t0: number = Date.now();
    try {
      const header: Record<string, string> = { 'Content-Type': 'application/json; charset=utf-8' };
      if (auth) {
        header['Authorization'] = 'Bearer ' + this.token;
      }
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs + 4000
      };
      const res = await req.request(url, opts);
      const code: number = res.responseCode as number;
      const ms: number = Date.now() - t0;
      LinkLog.record('PROBE', 'GET ' + url + ' -> ' + String(code) + ' (' + String(ms) + 'ms)');
      return { code: code, text: (res.result as string) ?? '' };
    } catch (e) {
      const ms: number = Date.now() - t0;
      LinkLog.record('PROBE', 'GET ' + url + ' FAIL (' + String(ms) + 'ms)');
      throw new Error((e as Error).message ?? 'probe failed');
    } finally {
      req.destroy();
    }
  }

  /** 把 /api/info 自报的地址合进候选（只取 IPv4，跳过回环） */
  seedLan(addresses: string[] | undefined, port: number): void {
    if (addresses === undefined || addresses.length === 0 || port <= 0) {
      return;
    }
    for (let i = 0; i < addresses.length; i++) {
      const a: string = addresses[i];
      if (a.indexOf(':') >= 0 || a === '127.0.0.1' || a === '') {
        continue;
      }
      const base: string = 'http://' + a + ':' + String(port);
      if (this.lanCands.indexOf(base) < 0) {
        this.lanCands.push(base);
      }
    }
    if (this.lanBase !== '') {
      const at: number = this.lanCands.indexOf(this.lanBase);
      if (at > 0) {
        this.lanCands.splice(at, 1);
        this.lanCands.unshift(this.lanBase);
      }
    }
  }

  /** 并发探测全部局域网候选地址，首个响应即返回；仅接受 200 且核对 pinnedHostId（防止同端口不同电脑串连）。 */
  async probeLan(timeoutMs: number, stageCb?: StageCallback): Promise<string> {
    if (this.inflightProbe !== null) {
      return await this.inflightProbe;
    }
    const list: string[] = this.lanCandidates();
    if (list.length === 0) {
      return '';
    }
    const myGen: number = this.rebaseGen;
    const expectedHostId: string = this.pinnedHostId;
    const run = async (): Promise<string> => {
      this.emitStage(stageCb, 0, '探测局域网候选 (' + String(list.length) + ' 个地址)');
      let settle: (hit: string) => void = (hit: string): void => {};
      const firstHit: Promise<string> = new Promise<string>((resolve: (hit: string) => void): void => {
        settle = resolve;
      });
      let left: number = list.length;
      let done: boolean = false;
      const finish = (hit: string): void => {
        if (!done) {
          done = true;
          settle(hit);
        }
      };
      const leave = (): void => {
        left--;
        if (left === 0) {
          finish('');
        }
      };
      for (let i = 0; i < list.length; i++) {
        const one: string = list[i];
        this.rawGet(one + '/api/info', timeoutMs, true)
          .then((r: RawResult): void => {
            if (r.code === 200) {
              let hostMatches: boolean = true;
              if (expectedHostId !== '') {
                hostMatches = false;
                try {
                  const info = JSON.parse(r.text) as InfoProbeResp;
                  const gotHid: string = info.hostId !== undefined ? info.hostId.trim() : '';
                  if (info.ok === true && gotHid === expectedHostId) {
                    hostMatches = true;
                  }
                } catch (e) {
                  hostMatches = false;
                }
              }
              if (hostMatches) {
                finish(one);
              }
            }
            leave();
          })
          .catch((): void => {
            leave();
          });
      }
      const hit: string = await firstHit;
      if (this.rebaseGen !== myGen) {
        return '';
      }
      if (hit !== '') {
        this.lanBase = hit;
        this.lanDownUntil = 0;
        const at: number = this.lanCands.indexOf(hit);
        if (at > 0) {
          this.lanCands.splice(at, 1);
          this.lanCands.unshift(hit);
        }
        LinkLog.record('PROBE', 'hit lan=' + hit);
        console.info('DSH_BASE lan ' + hit);
        return hit;
      }
      LinkLog.record('PROBE', 'miss all lan n=' + String(list.length));
      console.info('DSH_BASE lan miss all n=' + String(list.length));
      return '';
    };
    const p: Promise<string> = run();
    this.inflightProbe = p;
    try {
      return await p;
    } finally {
      if (this.inflightProbe === p) {
        this.inflightProbe = null;
      }
    }
  }

  protected async ensureBase(stageCb?: StageCallback): Promise<string> {
    if (this.chosen !== '') {
      return this.chosen;
    }
    if (this.inflightBase !== null) {
      return await this.inflightBase;
    }
    const myGen: number = this.rebaseGen;
    const resolveBase = async (): Promise<string> => {
      if (this.rebaseGen !== myGen) {
        throw new Error('连接已切换');
      }
      if (this.chosen !== '') {
        return this.chosen;
      }
      if (this.lanOnly) {
        if (Date.now() >= this.lanDownUntil) {
          const hit: string = await this.probeLan(2500, stageCb);
          if (this.rebaseGen !== myGen) {
            throw new Error('连接已切换');
          }
          if (hit !== '') {
            this.chosen = hit;
            this.lanFailStreak = 0;
            console.info('DSH_BASE lan-only ' + hit);
            return this.chosen;
          }
          this.lanDownUntil = Date.now() + 15000;
          this.nextLanProbe = Date.now() + 15000;
        }
        this.chosen = this.lanBase !== '' ? this.lanBase : (this.lanCands.length > 0 ? this.lanCands[0] : '');
        if (this.chosen === '') {
          throw new Error('现在是「仅局域网」模式，但这台电脑没有可用的局域网地址；到「连接」里切回自动，或先在同一 Wi-Fi 下配对');
        }
        return this.chosen;
      }
      if (this.forceWan || !this.autoLan) {
        this.chosen = this.wanBase;
        console.info('DSH_BASE wan (forced) ' + this.wanBase);
        return this.chosen;
      }
      // 纯蜂窝网络下零等待先走公网隧道；若配置了局域网候选，仍异步非阻塞探一次兜底（兼容双网加速/系统瞬时隐藏 Wi-Fi 句柄）
      if (Net.isCellularOnly()) {
        this.chosen = this.wanBase;
        this.lanDownUntil = Date.now() + 90000;
        this.nextLanProbe = Date.now() + 90000;
        this.emitStage(stageCb, 1, '蜂窝网络直连公网 ' + this.wanBase);
        LinkLog.record('NET', 'cellular fast-path -> wan ' + this.wanBase + ' bearers=' + Net.describeBearers());
        console.info('DSH_BASE cellular -> wan ' + this.wanBase);
        if (this.lanCands.length > 0) {
          this.triggerBgLanProbe(1200);
        }
        return this.chosen;
      }
      if (Date.now() >= this.lanDownUntil) {
        const hit: string = await this.probeLan(2500, stageCb);
        if (this.rebaseGen !== myGen) {
          throw new Error('连接已切换');
        }
        if (hit !== '') {
          this.chosen = hit;
          this.lanFailStreak = 0;
          return this.chosen;
        }
        const cool: number = Date.now() + 60000;
        this.lanDownUntil = cool;
        this.nextLanProbe = cool;
      }
      if (this.rebaseGen !== myGen) {
        throw new Error('连接已切换');
      }
      this.chosen = this.wanBase;
      this.emitStage(stageCb, 1, '切换公网隧道 ' + this.wanBase);
      console.info('DSH_BASE wan ' + this.wanBase);
      return this.chosen;
    };
    const p: Promise<string> = resolveBase();
    this.inflightBase = p;
    try {
      return await p;
    } finally {
      if (this.inflightBase === p) {
        this.inflightBase = null;
      }
    }
  }

  async poke(stageCb?: StageCallback): Promise<void> {
    if (this.wanBase === '') {
      return;
    }
    const myGen: number = this.rebaseGen;
    const prevChosen: string = this.chosen;
    this.lanDownUntil = 0;
    this.nextLanProbe = 0;
    if (this.lanOnly) {
      const hit: string = await this.probeLan(2500, stageCb);
      if (this.rebaseGen !== myGen) {
        return;
      }
      if (hit !== '') {
        this.chosen = hit;
        this.lanFailStreak = 0;
      } else if (prevChosen === '') {
        this.chosen = this.lanBase !== '' ? this.lanBase : (this.lanCands.length > 0 ? this.lanCands[0] : '');
      }
      this.nextLanProbe = Date.now() + 15000;
      console.info('DSH_BASE poke lan-only ' + (this.chosen !== '' ? this.chosen : '-'));
      return;
    }
    const cellOnly: boolean = Net.isCellularOnly();
    if (this.autoLan && !this.forceWan && !cellOnly) {
      const hit: string = await this.probeLan(2500, stageCb);
      if (this.rebaseGen !== myGen) {
        return;
      }
      if (hit !== '') {
        this.chosen = hit;
        this.lanFailStreak = 0;
        this.syncLinkStatus(false);
        this.emitStage(stageCb, 1, '已命中局域网直连 ' + hit);
        console.info('DSH_BASE poke lan ' + hit);
        return;
      }
    }
    if (this.rebaseGen !== myGen) {
      return;
    }
    this.chosen = this.wanBase;
    const cool: number = Date.now() + (cellOnly ? 90000 : 60000);
    this.lanDownUntil = cool;
    this.nextLanProbe = cool;
    this.emitStage(stageCb, 1, '使用公网入口 ' + this.wanBase);
    console.info('DSH_BASE poke wan ' + this.wanBase);
    if (this.autoLan && !this.forceWan && cellOnly && this.lanCands.length > 0) {
      this.triggerBgLanProbe(1200);
    }
  }

  /** 非阻塞后台局域网探测：不拖慢当前公网首包，命中即无缝升级为局域网直连。 */
  protected triggerBgLanProbe(timeoutMs: number): void {
    if (!this.autoLan || this.forceWan || this.lanOnly || this.lanCands.length === 0) {
      return;
    }
    const myGen: number = this.rebaseGen;
    if (this.bgLanProbeGen === myGen) {
      return;
    }
    this.bgLanProbeGen = myGen;
    this.probeLan(timeoutMs).then((hit: string) => {
      if (this.rebaseGen !== myGen) {
        return;
      }
      if (hit !== '') {
        this.chosen = hit;
        this.lanDownUntil = 0;
        this.lanFailStreak = 0;
        this.syncLinkStatus(false);
        LinkLog.record('NET', 'bg-probe -> lan ' + hit);
        console.info('DSH_BASE bg-probe lan ' + hit);
      }
    }).catch(() => {
    }).finally(() => {
      if (this.bgLanProbeGen === myGen) {
        this.bgLanProbeGen = -1;
      }
    });
  }

  protected scheduleLanProbe(): void {
    if (!this.autoLan || this.forceWan || this.lanCands.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (now < this.nextLanProbe || now < this.lanDownUntil) {
      return;
    }
    const cellOnly: boolean = Net.isCellularOnly();
    const myGen: number = this.rebaseGen;
    const gapMs: number = cellOnly ? 90000 : 30000;
    const coolMs: number = cellOnly ? 90000 : 60000;
    const timeoutMs: number = cellOnly ? 1200 : 2500;
    this.nextLanProbe = now + gapMs;
    this.probeLan(timeoutMs).then((hit: string) => {
      if (this.rebaseGen !== myGen) {
        return;
      }
      if (hit !== '') {
        this.chosen = hit;
        this.lanDownUntil = 0;
        this.lanFailStreak = 0;
        this.syncLinkStatus(false);
        LinkLog.record('NET', 'auto switch -> lan ' + hit);
        console.info('DSH_BASE switch lan ' + hit);
      } else {
        this.lanDownUntil = Date.now() + coolMs;
      }
    }).catch(() => {
      if (this.rebaseGen !== myGen) {
        return;
      }
      this.lanDownUntil = Date.now() + coolMs;
    });
  }

  /** 底层直连 JSON POST（专供 E2EE 握手与密文信封使用，不递归走加密包装）。 */
  protected async rawPostJsonOn(base: string, path: string, payload: string,
    extraReadMs: number = 8000): Promise<E2eeRawHttpResp> {
    const req = http.createHttp();
    const isLanReq: boolean = isLanUrl(base);
    const connectMs: number = isLanReq ? 5000 : 18000;
    const readMs: number = isLanReq ? Math.max(20000, connectMs + extraReadMs) : (connectMs + extraReadMs);
    try {
      const header: Record<string, string> = {
        'Authorization': 'Bearer ' + this.token,
        'Content-Type': 'application/json; charset=utf-8'
      };
      const opts: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: connectMs,
        readTimeout: readMs,
        extraData: payload
      };
      const res = await req.request(base + path, opts);
      const code: number = res.responseCode as number;
      const text: string = (res.result as string) ?? '';
      return { code: code, text: text };
    } catch (e) {
      throw new Error((e as Error).message ?? 'network error');
    } finally {
      req.destroy();
    }
  }

  async once<T>(path: string, method: string, payload?: string, idem?: string,
    stageCb?: StageCallback, extraReadMs: number = 8000): Promise<T> {
    const myGen: number = this.rebaseGen;
    for (let i = 0; i < 15 && this.wanBase === ''; i++) {
      await sleep(100);
      if (this.rebaseGen !== myGen) {
        throw new Error('连接已切换');
      }
    }
    if (this.wanBase === '') {
      this.syncLinkStatus(true);
      throw new Error('还没连上电脑：先在「连接」里配对或填写地址');
    }
    const base: string = await this.ensureBase(stageCb);
    if (this.rebaseGen !== myGen) {
      throw new Error('连接已切换');
    }
    this.emitStage(stageCb, 2, '请求 ' + base + LinkLog.sanitize(path));
    const t0: number = Date.now();

    // 透明端到端加密通道（L6）：已知主机公钥且未禁用时，普通 JSON /api/* 请求自动走 Noise_IK 加密信封
    if (this.e2eeEnabled && this.e2ee.isConfigured() && !this.e2ee.isUnsupported() &&
      path.startsWith('/api/') && !path.startsWith('/api/e2ee/')) {
      const caller: E2eeHttpCaller = {
        rawPostJson: (p: string, pl: string, readMs?: number): Promise<E2eeRawHttpResp> => {
          return this.rawPostJsonOn(base, p, pl, readMs !== undefined ? readMs : extraReadMs);
        }
      };
      let rpc: E2eeRpcResult | null = null;
      try {
        rpc = await this.e2ee.callRpc(caller, path, method, payload, idem, extraReadMs);
      } catch (e) {
        const msg: string = (e as Error).message ?? '';
        // 设备被电脑端撤销或公钥不匹配属于明确拒绝，禁止静默降级明文
        if (msg.startsWith('这台电脑拒绝') || msg === '连接已切换') {
          throw new Error(msg);
        }
        LinkLog.record('E2EE', 'rpc error on ' + path + ': ' + msg);
        throw new Error(msg !== '' ? msg : 'network error');
      }
      if (this.rebaseGen !== myGen) {
        throw new Error('连接已切换');
      }
      if (rpc !== null && !rpc.fallback) {
        const ms: number = Date.now() - t0;
        LinkLog.record('API', method + ' ' + path + ' [E2EE] -> ' + String(rpc.status) + ' (' + String(ms) + 'ms)');
        this.syncLinkStatus(false);
        if (rpc.status < 200 || rpc.status >= 300) {
          throw new Error(friendlyError(rpc.status, rpc.text, path));
        }
        try {
          return JSON.parse(rpc.text) as T;
        } catch (e) {
          throw new Error('响应格式不对（HTTP ' + String(rpc.status) + '）：加密负载解析失败');
        }
      }
      if (!this.e2ee.isUnsupported()) {
        throw new Error('端到端加密通道暂未就绪，已阻止明文回退');
      }
    }

    const req = http.createHttp();
    const isLanReq: boolean = isLanUrl(base);
    const connectMs: number = isLanReq ? 5000 : 18000;
    const readMs: number = isLanReq ? Math.max(20000, connectMs + extraReadMs) : (connectMs + extraReadMs);
    try {
      const header: Record<string, string> = {
        'Authorization': 'Bearer ' + this.token,
        'Content-Type': 'application/json; charset=utf-8'
      };
      if (idem !== undefined && idem !== '') {
        header['Idempotency-Key'] = idem;
      }
      const opts: http.HttpRequestOptions = {
        method: httpMethodOf(method),
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: connectMs,
        readTimeout: readMs,
        extraData: payload
      };
      const res = await req.request(base + path, opts);
      if (this.rebaseGen !== myGen) {
        throw new Error('连接已切换');
      }
      const code: number = res.responseCode as number;
      const text: string = res.result as string;
      const ms: number = Date.now() - t0;
      LinkLog.record('API', method + ' ' + path + ' -> ' + String(code) + ' (' + String(ms) + 'ms)');
      console.info('DSH_API ' + method + ' ' + LinkLog.sanitize(path) + ' -> ' + code + ' len=' + (text ? text.length : 0));
      this.syncLinkStatus(false);
      if (code < 200 || code >= 300) {
        throw new Error(friendlyError(code, text, path));
      }
      let parsed: T;
      try {
        parsed = JSON.parse(text) as T;
      } catch (e) {
        throw new Error('响应格式不对（HTTP ' + String(code) + '）：可能被网络劫持或隧道返回了错误页');
      }
      return parsed;
    } catch (e) {
      const errMsg: string = (e as Error).message ?? 'network error';
      if (errMsg.indexOf('HTTP ') < 0 && !errMsg.startsWith('这台电脑')) {
        const ms: number = Date.now() - t0;
        LinkLog.record('API', method + ' ' + path + ' ERR (' + String(ms) + 'ms) ' + errMsg);
      }
      throw new Error(errMsg);
    } finally {
      req.destroy();
    }
  }

  async call<T>(path: string, method: string, payload?: string, idem?: string,
    stageCb?: StageCallback, extraReadMs: number = 8000): Promise<T> {
    const canRetryPost: boolean = idem !== undefined && idem !== '';
    const attempts: number = method === 'GET' ? 3 : (canRetryPost ? 2 : 1);
    let last: Error = new Error('unknown');
    for (let i = 1; i <= attempts; i++) {
      try {
        const res: T = await this.once<T>(path, method, payload, idem, stageCb, extraReadMs);
        this.lanFailStreak = 0;
        this.offlineFailStreak = 0;
        return res;
      } catch (e) {
        last = e as Error;
        const msg: string = last.message ?? '';
        console.error('DSH_API_FAIL ' + method + ' ' + LinkLog.sanitize(path) + ' try=' + i + ' :: ' + msg);
        ApiTransport.noteError(method + ' ' + path + ' :: ' + msg);
        if (msg.startsWith('连不上电脑') || msg.startsWith('电脑端出错')) {
          if (i < attempts) {
            await sleep(450 * i * i + Math.floor(Math.random() * 120));
            continue;
          }
          this.offlineFailStreak++;
          if (this.offlineFailStreak >= 2) {
            this.syncLinkStatus(true);
          }
          break;
        }
        if (msg.startsWith('请求') || msg.startsWith('这台电脑') || msg.startsWith('响应格式') || msg.startsWith('还没连上')) {
          break;
        }
        if (this.lanOnly) {
          this.lanFailStreak++;
          if (this.lanFailStreak >= 2) {
            this.chosen = '';
            this.lanDownUntil = 0;
          }
        } else if (this.isLan()) {
          this.lanFailStreak++;
          // 局域网首次瞬时抖动（如 Wi-Fi 休眠唤醒）先在局域网原址重试 1 次；连续 2 次失败再降级公网
          const hardUnreachable: boolean = msg.indexOf('ECONNREFUSED') >= 0 || msg.indexOf('ENETUNREACH') >= 0 ||
            msg.indexOf('Couldn\'t connect') >= 0;
          if (this.lanFailStreak >= 2 || (hardUnreachable && i >= 2)) {
            this.lanFailStreak = 0;
            this.lanDownUntil = Date.now() + 45000;
            this.chosen = this.wanBase;
            LinkLog.record('NET', 'demote lan -> wan after ' + msg);
            console.info('DSH_BASE demote lan -> wan after ' + msg);
          }
        } else if (i === attempts && !Net.isCellularOnly()) {
          this.chosen = '';
        }
        if (i === attempts) {
          this.offlineFailStreak++;
          if (this.offlineFailStreak >= 2) {
            this.syncLinkStatus(true);
          }
          break;
        }
        await sleep(i === 1 ? 250 : 400 * i);
      }
    }
    throw last;
  }

  /**
   * 打开一条 SSE 增量事件流（基于 http.createHttp().requestInStream + dataReceive）。
   * 按 `\n\n` 帧切分解析 `event:` 与 `data:`，返回取消/关闭函数。
   * 遇到 404（旧宿主）、网络断流或心跳超时时自动回调一次 onError 触发轮询回退。
   */
  openSseStream(
    path: string,
    onEvent: (event: string, data: string) => void,
    onError: (reason: string) => void
  ): () => void {
    let cancelled: boolean = false;
    let failed: boolean = false;
    let activeReq: http.HttpRequest | null = null;
    let idleTimer: number = -1;
    let nonEventStream: boolean = false;
    let sseBuffer: string = '';
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');

    const clearIdle = (): void => {
      if (idleTimer >= 0) {
        clearTimeout(idleTimer);
        idleTimer = -1;
      }
    };

    const disposeReq = (): void => {
      clearIdle();
      const r: http.HttpRequest | null = activeReq;
      activeReq = null;
      if (r !== null) {
        try {
          r.off('headersReceive');
          r.off('dataReceive');
          r.off('dataEnd');
        } catch (e) {
        }
        try {
          r.destroy();
        } catch (e) {
        }
      }
    };

    const failOnce = (reason: string): void => {
      if (cancelled || failed) {
        return;
      }
      failed = true;
      LinkLog.record('SSE', 'FALLBACK ' + path + ' :: ' + reason);
      disposeReq();
      onError(reason);
    };

    const resetIdle = (): void => {
      clearIdle();
      if (cancelled || failed) {
        return;
      }
      idleTimer = setTimeout(() => {
        idleTimer = -1;
        failOnce('idle timeout');
      }, SSE_IDLE_TIMEOUT_MS);
    };

    const consumeSseText = (chunkText: string): void => {
      if (chunkText === '' || nonEventStream) {
        return;
      }
      sseBuffer += chunkText.replace(/\r\n/g, '\n');
      let sepIdx: number = sseBuffer.indexOf('\n\n');
      while (sepIdx >= 0) {
        const frame: string = sseBuffer.substring(0, sepIdx);
        sseBuffer = sseBuffer.substring(sepIdx + 2);
        sepIdx = sseBuffer.indexOf('\n\n');
        if (frame.trim() === '') {
          continue;
        }
        const lines: string[] = frame.split('\n');
        let evName: string = '';
        const dataLines: string[] = [];
        for (let i = 0; i < lines.length; i++) {
          const line: string = lines[i];
          if (line.startsWith(':')) {
            continue;
          }
          if (line.startsWith('event:')) {
            evName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            const rawData: string = line.substring(5);
            dataLines.push(rawData.startsWith(' ') ? rawData.substring(1) : rawData);
          }
        }
        if (dataLines.length > 0 && !cancelled && !failed) {
          onEvent(evName !== '' ? evName : 'message', dataLines.join('\n'));
        }
      }
    };

    const startAsync = async (): Promise<void> => {
      try {
        for (let i = 0; i < 15 && this.wanBase === '' && !cancelled; i++) {
          await sleep(100);
        }
        if (cancelled) {
          return;
        }
        if (this.wanBase === '') {
          failOnce('no base');
          return;
        }
        const base: string = await this.ensureBase();
        if (cancelled) {
          return;
        }
        const req: http.HttpRequest = http.createHttp();
        activeReq = req;
        const connectMs: number = this.isLan() ? 3000 : 18000;
        LinkLog.record('SSE', 'OPEN ' + path);

        req.on('headersReceive', (hdrObj: Object) => {
          resetIdle();
          try {
            const hdr = hdrObj as Record<string, Object>;
            const keys: string[] = Object.keys(hdr);
            for (let i = 0; i < keys.length; i++) {
              const lk: string = keys[i].toLowerCase();
              if (lk === ':status' || lk === 'status') {
                const sc: number = Number(String(hdr[keys[i]]));
                if (Number.isFinite(sc) && sc >= 400) {
                  nonEventStream = true;
                  failOnce('nonEventStream HTTP ' + String(sc));
                  return;
                }
              }
              if (lk === 'content-type') {
                const ct: string = String(hdr[keys[i]]).toLowerCase();
                if (ct.indexOf('text/event-stream') < 0) {
                  nonEventStream = true;
                  failOnce('nonEventStream ct=' + ct);
                  return;
                }
              }
            }
          } catch (e) {
          }
        });

        req.on('dataReceive', (buf: ArrayBuffer) => {
          if (cancelled || failed) {
            return;
          }
          resetIdle();
          if (nonEventStream || buf.byteLength <= 0) {
            return;
          }
          try {
            const part: string = decoder.decodeToString(new Uint8Array(buf), { stream: true });
            consumeSseText(part);
          } catch (e) {
            console.info('DSH_SSE decode error: ' + JSON.stringify(e));
          }
        });

        req.on('dataEnd', () => {
          if (!cancelled && !failed) {
            failOnce('stream ended');
          }
        });

        resetIdle();
        const sseHeader: Record<string, string> = {
          'Authorization': 'Bearer ' + this.token,
          'Accept': 'text/event-stream',
          'Cache-Control': 'no-cache'
        };
        const opts: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: sseHeader,
          usingCache: false,
          connectTimeout: connectMs,
          readTimeout: 0,
          maxLimit: 100 * 1024 * 1024
        };
        const statusCode: number = await req.requestInStream(base + path, opts);
        if (!cancelled && !failed) {
          failOnce('HTTP ' + String(statusCode));
        }
      } catch (e) {
        failOnce((e as Error).message ?? 'stream error');
      }
    };

    void startAsync();

    return (): void => {
      if (cancelled) {
        return;
      }
      cancelled = true;
      LinkLog.record('SSE', 'CLOSE ' + path);
      disposeReq();
    };
  }
}
