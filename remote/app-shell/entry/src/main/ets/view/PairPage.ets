import { deviceInfo } from '@kit.BasicServicesKit';
import { scanBarcode } from '@kit.ScanKit';
import http from '@ohos.net.http';
import { Api } from '../common/Api';
import { isLanUrl } from '../common/ApiUtil';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK } from '../common/AppIcon';
import { PageHeader, TopFade } from '../common/Chrome';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { PairClaim, PairError, PairInfo, Pairing, PairLink, RemotePairPollResp, RemotePairStartResp } from '../common/Pairing';
import { Tokens } from '../common/Tokens';
import { ConnectionStageCard, SheetHeader } from '../common/Widgets';

const PAIR_CMD: string = 'dsh plugin --profile desktop add agent-mobile-gateway';

const PAIR_STAGES: string[] = [
  '整理连接地址',
  '探测可达入口',
  '核验身份与密钥',
  '保存凭据完成配对'
];

interface ManualInfoResp {
  ok?: boolean;
  host?: string;
  hostId?: string;
  e2eePub?: string;
  port?: number;
  addresses?: string[];
}

/**
 * 原创两屏配对向导：
 * - prepare（第 1 步 · 电脑端准备）：三步极简引导、一键复制网关安装命令与顶部直达入口；
 * - connect（第 2 步 · 连接电脑）：扫码配对主卡 + [远程申请 | 口令 / 6位码 | 手动令牌] 分段切换 + 主机实时预览 + 排查抽屉。
 */
@Component
export struct PairPage {
  api: Api = new Api('', '');
  @Prop defaultBase: string = '';
  @Prop entry: string = '';
  @Prop mode: string = '';
  @Prop hasBack: boolean = false;
  @Prop popHeader: boolean = true;
  @Prop subPageDepth: number = 2;
  onExit: () => void = () => {};
  onGoOtherStep: () => void = () => {};
  onPaired: (b: string, t: string, host: string, lan: string[], hostId?: string, e2eePub?: string) => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private tab: string = 'remote';
  @State private entered: boolean = true;
  @State private code: string = '';
  @State private addr: string = '';
  @State private inviteText: string = '';
  @State private manualBase: string = '';
  @State private manualToken: string = '';
  @State private manualName: string = '';

  @State private busy: boolean = false;
  @State private err: string = '';
  @State private okMsg: string = '';
  @State private hint: string = '';

  @State private remoteReqId: string = '';
  @State private remoteSecret: string = '';
  @State private remoteVerifyCode: string = '';
  @State private remoteHost: string = '';
  @State private remoteBase: string = '';
  @State private remoteHostId: string = '';
  @State private remoteE2eePub: string = '';
  @State private remoteExpiresAt: number = 0;
  @State private remoteLeftSec: number = 0;
  @State private remoteBusy: boolean = false;

  @State private stageActive: boolean = false;
  @State private stageIdx: number = 0;
  @State private stageDetail: string = '';
  @State private stageErr: string = '';
  @State private elapsedSec: number = 0;
  @State private lastBases: string[] = [];
  @State private lastCode: string = '';

  @State private probing: boolean = false;
  @State private previewInfo: PairInfo | null = null;
  @State private previewErr: string = '';
  @State private helpSheet: boolean = false;

  private claimSeq: number = 0;
  private remoteSeq: number = 0;
  private remotePollTimer: number = -1;
  private remoteTickTimer: number = -1;
  private remotePollInFlight: boolean = false;
  private probeTimer: number = -1;
  private elapsedTimer: number = -1;
  private enterTimer: number = -1;
  private scroller: Scroller = new Scroller();
  private wave: BloomWaveTracker = new BloomWaveTracker();

  private isPrepareMode(): boolean {
    if (this.mode !== '') {
      return this.mode === 'prepare';
    }
    return this.entry === 'guide';
  }

  aboutToAppear(): void {
    if (this.defaultBase !== '') {
      this.addr = this.defaultBase;
      this.manualBase = this.defaultBase;
    }
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 24);
    } else {
      this.entered = true;
    }
  }

  aboutToDisappear(): void {
    this.stopTimer();
    this.remoteSeq++;
    this.stopRemoteTimers();
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private startTimer(): void {
    this.stopTimer();
    this.elapsedSec = 0;
    this.elapsedTimer = setInterval(() => {
      this.elapsedSec++;
    }, 1000);
  }

  private stopTimer(): void {
    if (this.elapsedTimer >= 0) {
      clearInterval(this.elapsedTimer);
      this.elapsedTimer = -1;
    }
  }

  private cancelClaim(): void {
    this.claimSeq++;
    this.stopTimer();
    this.busy = false;
    this.stageActive = false;
    this.stageErr = '';
    this.hint = '已取消本次连接，可修改参数后重试';
  }

  private isValidHostUrl(norm: string): boolean {
    return /^https?:\/\/([a-z0-9_-]+(\.[a-z0-9_-]+)*|\[[0-9a-f:]+\])(:\d{1,5})?(\/[^\s]*)?$/i.test(norm);
  }

  private scheduleProbe(rawAddr: string): void {
    if (this.probeTimer >= 0) {
      clearTimeout(this.probeTimer);
      this.probeTimer = -1;
    }
    const clean: string = rawAddr.trim();
    if (clean === '') {
      this.previewInfo = null;
      this.previewErr = '';
      this.probing = false;
      return;
    }
    const norm: string = Pairing.normalizeBase(clean);
    if (!this.isValidHostUrl(norm)) {
      this.previewInfo = null;
      return;
    }
    this.probeTimer = setTimeout(() => {
      this.probeTimer = -1;
      void this.probeHost(norm);
    }, 380);
  }

  private async probeHost(normBase: string): Promise<void> {
    if (normBase === '' || !this.isValidHostUrl(normBase)) {
      return;
    }
    this.probing = true;
    this.previewErr = '';
    try {
      const info: PairInfo = await Pairing.info(normBase);
      if (Pairing.normalizeBase(this.addr) === normBase) {
        this.previewInfo = info;
      }
    } catch (e) {
      if (Pairing.normalizeBase(this.addr) === normBase) {
        this.previewInfo = null;
        this.previewErr = (e as Error).message ?? '无法识别此地址';
      }
    } finally {
      this.probing = false;
    }
  }

  private hasInsecureWanHttp(bases: readonly string[]): string {
    for (let i = 0; i < bases.length; i++) {
      const n: string = Pairing.normalizeBase(bases[i]);
      if (n.toLowerCase().startsWith('http://') && !isLanUrl(n)) {
        return n;
      }
    }
    return '';
  }

  private confirmIfInsecureWan(bases: readonly string[], proceed: () => void): void {
    const insecureUrl: string = this.hasInsecureWanHttp(bases);
    if (insecureUrl === '') {
      proceed();
      return;
    }
    AppCtx.confirm(
      '非局域网明文连接提醒',
      '检测到公网地址 ' + insecureUrl + ' 使用了未加密的 http:// 传输。外网访问强烈建议配置 HTTPS 或 Cloudflare 隧道，确认继续连接吗？',
      '仍然连接',
      proceed,
      false,
      '取消'
    );
  }

  private async runClaim(bases: readonly string[], codeStr: string): Promise<void> {
    if (this.busy) {
      return;
    }
    const list: string[] = [];
    for (let i = 0; i < bases.length; i++) {
      const n: string = Pairing.normalizeBase(bases[i]);
      if (n !== '' && list.indexOf(n) < 0) {
        list.push(n);
      }
    }
    if (list.length === 0) {
      this.stageActive = false;
      this.err = '请填写电脑服务地址，或在电脑面板直接扫二维码。';
      return;
    }
    const c: string = codeStr.trim();
    if (c.length !== 6) {
      this.stageActive = false;
      this.err = '请输入电脑面板显示的 6 位数字配对码。';
      return;
    }

    const seq: number = ++this.claimSeq;
    this.lastBases = list.slice();
    this.lastCode = c;
    this.busy = true;
    this.err = '';
    this.okMsg = '';
    this.hint = '';
    this.stageErr = '';
    this.stageActive = true;
    this.stageIdx = 0;
    this.stageDetail = '已准备 ' + String(list.length) + ' 个连接入口';
    this.startTimer();

    try {
      await new Promise<void>((r: () => void) => setTimeout(r, 60));
      if (seq !== this.claimSeq) {
        return;
      }
      this.stageIdx = 1;
      this.stageDetail = '正在连通 ' + list[0];

      const res: PairClaim = await Pairing.claimAny(list, c, (st: number, detail: string) => {
        if (seq !== this.claimSeq) {
          return;
        }
        this.stageIdx = st <= 0 ? 1 : 2;
        this.stageDetail = detail;
      });
      if (seq !== this.claimSeq) {
        return;
      }

      const used: string = res.usedBase !== undefined && res.usedBase !== '' ? res.usedBase : list[0];
      const hostLabel: string = res.host !== undefined && res.host !== '' ? res.host : used;
      const hostId: string = res.hostId !== undefined && res.hostId !== ''
        ? res.hostId
        : (this.previewInfo !== null && this.previewInfo.hostId !== undefined ? this.previewInfo.hostId : '');
      const e2eePub: string = res.e2eePub !== undefined && res.e2eePub !== ''
        ? res.e2eePub
        : (this.previewInfo !== null && this.previewInfo.e2eePub !== undefined ? this.previewInfo.e2eePub : '');

      this.stageIdx = 3;
      this.stageDetail = '正在写入本机加密凭据 · ' + hostLabel;
      this.okMsg = '已连接 · ' + hostLabel;
      Haptics.success();
      await new Promise<void>((r: () => void) => setTimeout(r, 240));
      if (seq !== this.claimSeq) {
        return;
      }
      this.onPaired(used, res.token, hostLabel, res.lan !== undefined ? res.lan : [], hostId, e2eePub);
    } catch (e) {
      if (seq !== this.claimSeq) {
        return;
      }
      const msg: string = (e as Error).message !== undefined && (e as Error).message !== ''
        ? (e as Error).message
        : '连接未成功，请确认电脑端网关正在运行';
      this.stageIdx = e instanceof PairError ? 2 : 1;
      this.stageErr = msg;
      this.err = msg;
    } finally {
      if (seq === this.claimSeq) {
        this.stopTimer();
        this.busy = false;
      }
    }
  }

  private startManualConnect(): void {
    const rawBase: string = this.manualBase.trim();
    const rawToken: string = this.manualToken.trim();
    if (rawBase === '') {
      this.stageActive = false;
      this.stageErr = '';
      this.err = '请填写电脑连接地址。';
      return;
    }
    const norm: string = Pairing.normalizeBase(rawBase);
    if (!this.isValidHostUrl(norm)) {
      this.stageActive = false;
      this.stageErr = '';
      this.err = '地址格式无效，例如 192.168.1.10:8901 或 https://example.com';
      return;
    }
    if (rawToken === '') {
      this.stageActive = false;
      this.stageErr = '';
      this.err = '请填写访问令牌。';
      return;
    }
    this.confirmIfInsecureWan([norm], () => {
      void this.runManualVerifyAndSave(norm, rawToken, this.manualName.trim());
    });
  }

  private async runManualVerifyAndSave(normBase: string, rawToken: string, customName: string): Promise<void> {
    if (this.busy) {
      return;
    }
    const seq: number = ++this.claimSeq;
    this.busy = true;
    this.err = '';
    this.okMsg = '';
    this.stageErr = '';
    this.stageActive = true;
    this.stageIdx = 1;
    this.stageDetail = '正在校验令牌与主机指纹 · ' + normBase;
    this.startTimer();

    await new Promise<void>((r: () => void) => setTimeout(r, 32));
    if (seq !== this.claimSeq) {
      this.stopTimer();
      this.busy = false;
      return;
    }

    const client: http.HttpRequest = http.createHttp();
    try {
      const resp = await client.request(normBase + '/api/info', {
        method: http.RequestMethod.GET,
        header: { 'Authorization': 'Bearer ' + rawToken },
        connectTimeout: 4500,
        readTimeout: 7000,
        expectDataType: http.HttpDataType.STRING
      });
      if (seq !== this.claimSeq) {
        return;
      }
      if (resp.responseCode === 401 || resp.responseCode === 403) {
        throw new PairError(resp.responseCode, '电脑拒绝了该访问令牌，请核对后重试');
      }
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error('电脑返回异常状态（HTTP ' + String(resp.responseCode) + '）');
      }
      let info: ManualInfoResp = {};
      try {
        info = JSON.parse(resp.result as string) as ManualInfoResp;
      } catch (e) {
        throw new Error('返回内容格式异常，请确认地址指向 Agent Mobile 网关');
      }
      const hostName: string = customName !== ''
        ? customName
        : (info.host !== undefined && info.host !== '' ? info.host : normBase);
      const hid: string = info.hostId !== undefined ? info.hostId : '';
      const pub: string = info.e2eePub !== undefined ? info.e2eePub : '';
      const lanList: string[] = [];
      if (isLanUrl(normBase)) {
        lanList.push(normBase);
      }
      if (info.addresses !== undefined && info.port !== undefined) {
        for (let i = 0; i < info.addresses.length; i++) {
          const ip: string = info.addresses[i];
          if (ip !== '' && ip !== '127.0.0.1' && ip.indexOf(':') < 0) {
            const url: string = 'http://' + ip + ':' + String(info.port);
            if (lanList.indexOf(url) < 0) {
              lanList.push(url);
            }
          }
        }
      }
      this.stageIdx = 3;
      this.stageDetail = '正在写入本机加密凭据 · ' + hostName;
      this.okMsg = '已验证 · ' + hostName;
      Haptics.success();
      await new Promise<void>((r: () => void) => setTimeout(r, 200));
      if (seq !== this.claimSeq) {
        return;
      }
      this.onPaired(normBase, rawToken, hostName, lanList, hid, pub);
    } catch (e) {
      if (seq !== this.claimSeq) {
        return;
      }
      const msg: string = (e as Error).message !== undefined && (e as Error).message !== ''
        ? (e as Error).message
        : '连不上指定地址';
      this.stageIdx = e instanceof PairError ? 2 : 1;
      this.stageErr = msg;
      this.err = msg;
    } finally {
      client.destroy();
      if (seq === this.claimSeq) {
        this.stopTimer();
        this.busy = false;
      }
    }
  }

  private async scan(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.err = '';
    this.stageErr = '';
    Haptics.soft();
    try {
      const res = await scanBarcode.startScanForResult(AppCtx.ability());
      const raw: string = res.originalValue;
      const link: PairLink | null = Pairing.parseLink(raw);
      if (link === null) {
        this.stageActive = false;
        this.err = '未能识别该二维码，请扫描电脑端「Agent Mobile」面板中的配对二维码。';
        return;
      }
      this.hint = '已识别入口 ' + link.base;
      const bases: string[] = [link.base];
      for (let i = 0; i < link.alts.length; i++) {
        bases.push(link.alts[i]);
      }
      this.confirmIfInsecureWan(bases, () => {
        void this.runClaim(bases, link.code);
      });
    } catch (e) {
      const msg: string = (e as Error).message !== undefined ? (e as Error).message : '';
      if (msg.indexOf('cancel') >= 0 || msg.indexOf('Cancel') >= 0 || msg.indexOf('1000500002') >= 0) {
        return;
      }
      this.stageActive = false;
      this.err = '无法调起扫码：' + (msg !== '' ? msg : '请直接使用下方远程配对或 6 位配对码连接');
    }
  }

  private deviceLabel(): string {
    try {
      const market: string = deviceInfo.marketName !== undefined ? deviceInfo.marketName.trim() : '';
      if (market !== '') {
        return market;
      }
      const model: string = deviceInfo.productModel !== undefined ? deviceInfo.productModel.trim() : '';
      if (model !== '') {
        return model;
      }
    } catch (e) {
    }
    return '鸿蒙设备';
  }

  private tryApplyInviteLink(raw: string): boolean {
    const link: PairLink | null = Pairing.parseLink(raw);
    if (link === null) {
      return false;
    }
    this.inviteText = '';
    this.err = '';
    this.stageErr = '';
    this.hint = '已识别一次性配对口令 · ' + link.base;
    Haptics.confirm();
    const bases: string[] = [link.base];
    for (let i = 0; i < link.alts.length; i++) {
      if (bases.indexOf(link.alts[i]) < 0) {
        bases.push(link.alts[i]);
      }
    }
    this.confirmIfInsecureWan(bases, () => {
      void this.runClaim(bases, link.code);
    });
    return true;
  }

  private stopRemoteTimers(): void {
    if (this.remotePollTimer >= 0) {
      clearInterval(this.remotePollTimer);
      this.remotePollTimer = -1;
    }
    if (this.remoteTickTimer >= 0) {
      clearInterval(this.remoteTickTimer);
      this.remoteTickTimer = -1;
    }
  }

  private cancelRemoteRequest(msg: string = ''): void {
    this.remoteSeq++;
    this.stopRemoteTimers();
    this.remotePollInFlight = false;
    this.remoteBusy = false;
    this.remoteReqId = '';
    this.remoteSecret = '';
    this.remoteVerifyCode = '';
    this.remoteHost = '';
    this.remoteBase = '';
    this.remoteHostId = '';
    this.remoteE2eePub = '';
    this.remoteExpiresAt = 0;
    this.remoteLeftSec = 0;
    if (msg !== '') {
      this.hint = msg;
    }
  }

  private spacedVerifyCode(): string {
    const s: string = this.remoteVerifyCode;
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      if (i > 0) {
        out += '  ';
      }
      out += s.charAt(i);
    }
    return out;
  }

  private startRemoteRequest(): void {
    const raw: string = this.addr.trim();
    if (raw === '') {
      this.err = '请先输入电脑公网地址或局域网 IP:端口。';
      return;
    }
    if (raw.indexOf('dshmobile://pair?') >= 0 && this.tryApplyInviteLink(raw)) {
      return;
    }
    const norm: string = Pairing.normalizeBase(raw);
    if (!this.isValidHostUrl(norm)) {
      this.err = '地址格式无效，例如 https://dsh.example.com 或 192.168.1.10:8901';
      return;
    }
    this.confirmIfInsecureWan([norm], () => {
      void this.runRemoteRequest(norm);
    });
  }

  private async runRemoteRequest(normBase: string): Promise<void> {
    if (this.busy || this.remoteBusy) {
      return;
    }
    const seq: number = ++this.remoteSeq;
    this.stopRemoteTimers();
    this.remotePollInFlight = false;
    this.remoteBusy = true;
    this.err = '';
    this.okMsg = '';
    this.hint = '';
    this.stageActive = false;
    this.stageErr = '';
    try {
      const res: RemotePairStartResp = await Pairing.requestRemotePair(normBase, this.deviceLabel());
      if (seq !== this.remoteSeq) {
        return;
      }
      this.remoteReqId = res.requestId;
      this.remoteSecret = res.secret;
      this.remoteVerifyCode = res.verifyCode;
      this.remoteHost = res.host !== '' ? res.host : normBase;
      this.remoteBase = normBase;
      this.remoteHostId = res.hostId !== undefined ? res.hostId : '';
      this.remoteE2eePub = res.e2eePub !== undefined ? res.e2eePub : '';
      this.remoteExpiresAt = res.expiresAt;
      this.remoteLeftSec = Math.max(1, Math.ceil((res.expiresAt - Date.now()) / 1000));
      this.remoteBusy = false;
      Haptics.confirm();

      this.remoteTickTimer = setInterval(() => {
        if (seq !== this.remoteSeq || this.remoteReqId === '') {
          this.stopRemoteTimers();
          return;
        }
        const left: number = Math.max(0, Math.ceil((this.remoteExpiresAt - Date.now()) / 1000));
        this.remoteLeftSec = left;
        if (left <= 0) {
          this.cancelRemoteRequest('');
          this.err = '远程配对申请已过期，请重新发起。';
        }
      }, 1000);

      this.remotePollTimer = setInterval(() => {
        void this.pollRemoteOnce(seq);
      }, 1500);
    } catch (e) {
      if (seq !== this.remoteSeq) {
        return;
      }
      this.remoteBusy = false;
      const msg: string = (e as Error).message !== undefined && (e as Error).message !== ''
        ? (e as Error).message
        : '无法发起远程配对申请，请检查电脑地址与网关版本';
      this.err = msg;
      Haptics.error();
    }
  }

  private async pollRemoteOnce(seq: number): Promise<void> {
    if (seq !== this.remoteSeq || this.remoteReqId === '' || this.remotePollInFlight) {
      return;
    }
    this.remotePollInFlight = true;
    try {
      const r: RemotePairPollResp = await Pairing.pollRemotePair(this.remoteBase, this.remoteReqId, this.remoteSecret);
      if (seq !== this.remoteSeq) {
        return;
      }
      if (r.status === 'approved' && r.token !== undefined && r.token !== '') {
        const used: string = this.remoteBase !== ''
          ? this.remoteBase
          : (r.base !== undefined && r.base !== '' ? r.base : '');
        const hostLabel: string = r.host !== undefined && r.host !== ''
          ? r.host
          : (this.remoteHost !== '' ? this.remoteHost : used);
        const hostId: string = r.hostId !== undefined && r.hostId !== '' ? r.hostId : this.remoteHostId;
        const e2eePub: string = r.e2eePub !== undefined && r.e2eePub !== '' ? r.e2eePub : this.remoteE2eePub;
        const lan: string[] = r.lan !== undefined ? r.lan : [];
        const tok: string = r.token;

        this.cancelRemoteRequest('');
        this.okMsg = '远程配对已批准 · ' + hostLabel;
        Haptics.success();
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 240));
        this.onPaired(used, tok, hostLabel, lan, hostId, e2eePub);
        return;
      }
      if (r.status === 'rejected') {
        this.cancelRemoteRequest('');
        this.err = '电脑端或已配对设备已拒绝本次配对申请。';
        Haptics.error();
        return;
      }
      if (r.status === 'expired') {
        this.cancelRemoteRequest('');
        this.err = '远程配对申请已过期，请重新发起。';
        return;
      }
      if (r.expiresAt !== undefined && r.expiresAt > 0) {
        this.remoteExpiresAt = r.expiresAt;
      }
    } catch (e) {
      // 单次轮询网络抖动不中断等待，倒计时到期或用户取消时停止
    } finally {
      this.remotePollInFlight = false;
    }
  }

  private digitAt(idx: number): string {
    return idx < this.code.length ? this.code.charAt(idx) : '';
  }

  @Builder
  digitBoxes() {
    Stack({ alignContent: Alignment.Center }) {
      Row({ space: 8 }) {
        ForEach([0, 1, 2, 3, 4, 5], (i: number) => {
          Stack({ alignContent: Alignment.Center }) {
            Text(this.digitAt(i))
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
          }
          .layoutWeight(1)
          .height(50)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rSm)
          .border({
            width: this.code.length === i || (i === 5 && this.code.length === 6) ? 1.5 : 1,
            color: this.code.length === i ? Tokens.accent : Tokens.lineSoft
          })
        }, (i: number) => 'box-' + String(i))
      }
      .width('100%')

      TextInput({ text: this.code })
        .id('pairCodeInput')
        .type(InputType.Number)
        .maxLength(6)
        .caretColor(Color.Transparent)
        .fontColor(Color.Transparent)
        .backgroundColor(Color.Transparent)
        .width('100%')
        .height(54)
        .onChange((v: string) => {
          this.code = v.replace(/\D/g, '').slice(0, 6);
          if (this.err !== '') {
            this.err = '';
          }
        })
    }
    .width('100%')
    .onClick(() => {
      try {
        this.getUIContext().getFocusController().requestFocus('pairCodeInput');
      } catch (e) {
      }
    })
  }

  @Builder
  heroScanCard() {
    Column({ space: 14 }) {
      Row({ space: 12 }) {
        Image(AppIcon.res(this.appIconStyle))
          .width(46)
          .height(46)
          .borderRadius(12)
          .border({ width: 0.5, color: Tokens.line })
        Column({ space: 3 }) {
          Row({ space: 8 }) {
            Text('Agent Mobile 快速连接')
              .fontSize(Tokens.fsTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.fg)
          }
          Text('同 Wi-Fi 可扫码直连；异地支持下方远程配对申请或粘贴一次性口令')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Image($r('app.media.ic_scan'))
          .width(18)
          .height(18)
          .fillColor(Tokens.accentInk)
          .objectFit(ImageFit.Contain)
        Text(this.busy ? '正在建立连接…' : '扫一扫配对二维码')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .width('100%')
      .height(48)
      .backgroundColor(Tokens.accent)
      .borderRadius(Tokens.rPill)
      .opacity(this.busy ? 0.65 : 1)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        if (!this.busy) {
          void this.scan();
        }
      })
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rXl)
    .border({ width: 1, color: this.hdsOn ? Mat.cardBorderColor(true) : Tokens.accentGlass })
    .shadow(Mat.cardShadow(this.hdsOn))
  }

  @Builder
  hostPreviewBadge() {
    if (this.probing) {
      Row({ space: 8 }) {
        LoadingProgress().width(14).height(14).color(Tokens.accent)
        Text('正在识别电脑主机信息…')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor(Tokens.surface2)
      .borderRadius(Tokens.rSm)
    } else if (this.previewInfo !== null) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Row()
            .width(7)
            .height(7)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.ok)
          Text(this.previewInfo.name !== '' ? this.previewInfo.name : this.previewInfo.host)
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.previewInfo.e2ee !== false ? '支持 E2EE' : '直连')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.doneInk)
            .backgroundColor(Tokens.doneBg)
            .borderRadius(Tokens.rPill)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
        .width('100%')

        Text('v' + this.previewInfo.version +
          (this.previewInfo.hostId !== undefined && this.previewInfo.hostId !== ''
            ? ' · 指纹 ' + this.previewInfo.hostId.slice(0, 10)
            : ''))
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .fontFamily('monospace')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor(Tokens.doneBg)
      .borderRadius(Tokens.rSm)
      .alignItems(HorizontalAlign.Start)
    } else if (this.previewErr !== '') {
      Text(this.previewErr)
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .lineHeight(16)
        .width('100%')
    }
  }

  @Builder
  segmentedTabs() {
    Row({ space: 4 }) {
      Text('远程申请')
        .fontSize(Tokens.fsFoot)
        .fontWeight(this.tab === 'remote' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === 'remote' ? Tokens.fg : Tokens.dim2)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor(this.tab === 'remote' ? Tokens.surface : Color.Transparent)
        .borderRadius(Tokens.rSm)
        .onClick(() => {
          if (this.tab !== 'remote') {
            Haptics.tap();
            this.err = '';
            this.tab = 'remote';
          }
        })

      Text('口令 / 6位码')
        .fontSize(Tokens.fsFoot)
        .fontWeight(this.tab === 'code' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === 'code' ? Tokens.fg : Tokens.dim2)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor(this.tab === 'code' ? Tokens.surface : Color.Transparent)
        .borderRadius(Tokens.rSm)
        .onClick(() => {
          if (this.tab !== 'code') {
            Haptics.tap();
            this.err = '';
            this.tab = 'code';
          }
        })

      Text('手动令牌')
        .fontSize(Tokens.fsFoot)
        .fontWeight(this.tab === 'manual' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.tab === 'manual' ? Tokens.fg : Tokens.dim2)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 9, bottom: 9 })
        .backgroundColor(this.tab === 'manual' ? Tokens.surface : Color.Transparent)
        .borderRadius(Tokens.rSm)
        .onClick(() => {
          if (this.tab !== 'manual') {
            Haptics.tap();
            this.err = '';
            this.tab = 'manual';
          }
        })
    }
    .width('100%')
    .padding(4)
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rMd)
    .margin({ top: 14 })
  }

  @Builder
  modeContentCard() {
    Column({ space: 12 }) {
      if (this.tab === 'remote') {
        Text('输入电脑公网地址（或局域网 IP:端口）发起远程配对，电脑端或已配对手机批准后自动连通')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .width('100%')

        Row({ space: 8 }) {
          TextInput({ text: this.addr, placeholder: 'https://dsh.example.com 或 192.168.1.10:8901' })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .height(44)
            .layoutWeight(1)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rInput)
            .enabled(this.remoteReqId === '')
            .onChange((v: string) => {
              if (v.indexOf('dshmobile://pair?') >= 0 && this.tryApplyInviteLink(v)) {
                return;
              }
              this.addr = v;
              if (this.err !== '') {
                this.err = '';
              }
              this.scheduleProbe(v);
            })

          Text('探测')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.accent)
            .padding({ left: 12, right: 12, top: 11, bottom: 11 })
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rInput)
            .opacity(this.remoteReqId === '' ? 1 : 0.45)
            .onClick(() => {
              if (this.remoteReqId !== '') {
                return;
              }
              Haptics.tap();
              void this.probeHost(Pairing.normalizeBase(this.addr));
            })
        }
        .width('100%')

        this.hostPreviewBadge()

        if (this.remoteReqId !== '') {
          Column({ space: 10 }) {
            Row({ space: 8 }) {
              LoadingProgress().width(16).height(16).color(Tokens.accent)
              Text('等待电脑端或已配对手机批准…')
                .fontSize(Tokens.fsBody)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.fg)
                .layoutWeight(1)
              Text(String(this.remoteLeftSec) + 's')
                .fontSize(Tokens.fsCaption)
                .fontFamily('monospace')
                .fontColor(Tokens.accent)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Column({ space: 4 }) {
              Text('核对 4 位安全验证码')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
              Text(this.spacedVerifyCode())
                .fontSize(30)
                .fontWeight(FontWeight.Bold)
                .fontFamily('monospace')
                .fontColor(Tokens.accent)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .backgroundColor(Tokens.surface)
            .borderRadius(Tokens.rMd)
            .border({ width: 1, color: Tokens.accentGlass })
            .alignItems(HorizontalAlign.Center)

            Text('目标主机：' + this.remoteHost + '。请在电脑 DSH 面板弹窗或已配对手机的「设置 → 连接与设备」中核对验证码一致后点击「批准配对」。')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .lineHeight(17)
              .width('100%')

            Text('取消远程申请')
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.dim)
              .textAlign(TextAlign.Center)
              .width('100%')
              .height(42)
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rPill)
              .border({ width: 1, color: Tokens.lineSoft })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
              .onClick(() => {
                Haptics.soft();
                this.cancelRemoteRequest('已取消远程配对申请');
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rMd)
          .border({ width: 1, color: Tokens.accentGlass })
          .alignItems(HorizontalAlign.Start)
        } else {
          Text(this.remoteBusy ? '正在提交远程配对申请…' : '发起远程配对申请')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(!this.remoteBusy && !this.busy && this.addr.trim() !== '' ? Tokens.accentInk : Tokens.dim)
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(46)
            .backgroundColor(!this.remoteBusy && !this.busy && this.addr.trim() !== '' ? Tokens.accentStrong : Tokens.surface3)
            .borderRadius(Tokens.rPill)
            .opacity(!this.remoteBusy && !this.busy && this.addr.trim() !== '' ? 1 : 0.6)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
            .onClick(() => {
              if (!this.remoteBusy && !this.busy && this.addr.trim() !== '') {
                this.startRemoteRequest();
              }
            })
        }
      } else if (this.tab === 'code') {
        Column({ space: 8 }) {
          Text('一次性远程配对口令（推荐异地直接粘贴）')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .width('100%')

          Row({ space: 8 }) {
            TextInput({ text: this.inviteText, placeholder: '粘贴 dshmobile://pair?... 口令自动连接' })
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.fg)
              .placeholderColor(Tokens.dim2)
              .height(42)
              .layoutWeight(1)
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rInput)
              .onChange((v: string) => {
                this.inviteText = v;
                if (this.err !== '') {
                  this.err = '';
                }
                if (v.indexOf('dshmobile://pair?') >= 0) {
                  this.tryApplyInviteLink(v);
                }
              })

            Text('识别')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.accent)
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rInput)
              .onClick(() => {
                Haptics.tap();
                if (!this.tryApplyInviteLink(this.inviteText)) {
                  this.err = '未识别到有效配对口令，请完整粘贴以 dshmobile://pair? 开头的文本。';
                }
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rMd)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 8 }) {
          TextInput({ text: this.addr, placeholder: '电脑地址（IP:端口 或公网域名）' })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .height(44)
            .layoutWeight(1)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rInput)
            .onChange((v: string) => {
              if (v.indexOf('dshmobile://pair?') >= 0 && this.tryApplyInviteLink(v)) {
                return;
              }
              this.addr = v;
              if (this.err !== '') {
                this.err = '';
              }
              this.scheduleProbe(v);
            })

          Text('探测')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.accent)
            .padding({ left: 12, right: 12, top: 11, bottom: 11 })
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rInput)
            .onClick(() => {
              Haptics.tap();
              void this.probeHost(Pairing.normalizeBase(this.addr));
            })
        }
        .width('100%')

        this.hostPreviewBadge()

        Text('输入电脑面板显示的 6 位一次性配对码')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .width('100%')

        this.digitBoxes()

        Text(this.busy ? '正在连接…' : '验证配对码并连接')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(!this.busy && this.code.length === 6 && this.addr.trim() !== '' ? Tokens.accentInk : Tokens.dim)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(46)
          .backgroundColor(!this.busy && this.code.length === 6 && this.addr.trim() !== '' ? Tokens.accentStrong : Tokens.surface3)
          .borderRadius(Tokens.rPill)
          .opacity(!this.busy && this.code.length === 6 && this.addr.trim() !== '' ? 1 : 0.6)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            const target: string = this.addr.trim();
            if (this.busy || target === '' || this.code.length !== 6) {
              return;
            }
            const cands: string[] = [target];
            if (this.previewInfo !== null && this.previewInfo.lan !== undefined) {
              for (let i = 0; i < this.previewInfo.lan.length; i++) {
                if (cands.indexOf(this.previewInfo.lan[i]) < 0) {
                  cands.push(this.previewInfo.lan[i]);
                }
              }
            }
            this.confirmIfInsecureWan(cands, () => {
              void this.runClaim(cands, this.code);
            });
          })
      } else {
        TextInput({ text: this.manualName, placeholder: '电脑备注名称（可选）' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .height(44)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .onChange((v: string) => {
            this.manualName = v;
          })

        TextInput({ text: this.manualBase, placeholder: '服务地址，如 https://am.example.com 或 192.168.1.10:8901' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .height(44)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .onChange((v: string) => {
            this.manualBase = v;
            if (this.err !== '') {
              this.err = '';
            }
          })

        TextInput({ text: this.manualToken, placeholder: '访问令牌（在电脑端面板复制）' })
          .type(InputType.Password)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .height(44)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .onChange((v: string) => {
            this.manualToken = v;
            if (this.err !== '') {
              this.err = '';
            }
          })

        Text(this.busy ? '正在校验令牌…' : '校验并连接')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(!this.busy && this.manualBase.trim() !== '' && this.manualToken.trim() !== '' ? Tokens.accentInk : Tokens.dim)
          .textAlign(TextAlign.Center)
          .width('100%')
          .height(46)
          .backgroundColor(!this.busy && this.manualBase.trim() !== '' && this.manualToken.trim() !== ''
            ? Tokens.accentStrong : Tokens.surface3)
          .borderRadius(Tokens.rPill)
          .opacity(!this.busy && this.manualBase.trim() !== '' && this.manualToken.trim() !== '' ? 1 : 0.6)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            if (!this.busy) {
              this.startManualConnect();
            }
          })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rCard)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .margin({ top: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  feedbackBlock() {
    if (this.busy && this.stageActive) {
      Column() {
        ConnectionStageCard({
          stages: PAIR_STAGES,
          currentStage: this.stageIdx,
          elapsedSec: this.elapsedSec,
          detail: this.stageDetail,
          errorText: '',
          onCancel: (): void => {
            this.cancelClaim();
          }
        })
      }
      .width('100%')
      .margin({ top: 12 })
    } else if (this.err !== '') {
      Column({ space: 10 }) {
        if (this.stageActive && this.stageErr !== '') {
          ConnectionStageCard({
            stages: PAIR_STAGES,
            currentStage: this.stageIdx,
            elapsedSec: this.elapsedSec,
            detail: this.stageDetail,
            errorText: this.stageErr
          })
        } else {
          Column({ space: 6 }) {
            Text('连接未成功')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.err)
            Text(this.err)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.err)
              .lineHeight(18)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Tokens.intrBg)
          .border({ width: 1, color: Tokens.err })
          .borderRadius(Tokens.rCard)
          .alignItems(HorizontalAlign.Start)
        }

        Row({ space: 8 }) {
          if (this.tab === 'code' && this.lastBases.length > 0 && this.lastCode.length === 6) {
            Text('重试')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .onClick(() => {
                void this.runClaim(this.lastBases, this.lastCode);
              })
          }
          Text(this.tab === 'remote' ? '改用配对口令 / 6位码' : (this.tab === 'code' ? '改用远程申请' : '改用远程申请'))
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.fg)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => {
              Haptics.tap();
              this.err = '';
              this.stageActive = false;
              this.tab = this.tab === 'remote' ? 'code' : 'remote';
            })
        }
        .width('100%')
      }
      .width('100%')
      .margin({ top: 12 })
    } else if (this.okMsg !== '') {
      Text(this.okMsg)
        .fontSize(Tokens.fsBody)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.doneInk)
        .width('100%')
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Tokens.doneBg)
        .borderRadius(Tokens.rMd)
        .margin({ top: 12 })
    } else if (this.hint !== '') {
      Text(this.hint)
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 10 })
    }
  }

  @Builder
  helpSheetContent() {
    Column({ space: 12 }) {
      SheetHeader({
        title: '无法连接电脑排查清单',
        subtitle: 'Agent Mobile 连接诊断建议',
        onClose: () => {
          this.helpSheet = false;
        }
      })

      Column({ space: 10 }) {
        Text('1. 确认手机与电脑处于同一 Wi-Fi（未开启访客网络或 AP 隔离），且系统防火墙放行 8901 端口。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(20)
        Text('2. 确认电脑端已启动 agent-mobile-gateway，且「允许新设备配对」处于开启状态；6 位配对码仅单次有效。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(20)
        Text('3. 若当前在 4G/5G 外网环境，请确认电脑端已开启公网访问并配置 HTTPS / Cloudflare 隧道，可通过「远程申请」等待电脑或已配对手机审批，或直接粘贴一次性配对口令连接。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(20)
        Text('4. 若扫码或远程申请不便使用，也可切到「手动令牌」直接粘贴服务地址与访问令牌验证。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(20)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Tokens.surface2)
      .borderRadius(Tokens.rCard)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 16, bottom: this.bottomInset + 22 })
  }

  @Builder
  prepareStepCard(num: string, title: string, desc: string) {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Text(num)
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.accent)
      }
      .width(28)
      .height(28)
      .borderRadius(Tokens.rPill)
      .backgroundColor(Tokens.accentSoft)

      Column({ space: 4 }) {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
        Text(desc)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(15)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rCard)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  connectScreen() {
    Column() {
      Row({ space: 8 }) {
        Text('第 2 步 / 共 2 步')
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
        Text('扫码、远程申请或粘贴配对口令连接')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .margin({ bottom: 10 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:hdr', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('conn:hdr', 0), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('conn:hdr', 0), this.motionMode)
        : null)

      Column() {
        this.heroScanCard()
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:hero', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:hero', 96), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:hero', 96), this.motionMode)
        : null)

      Column() {
        this.segmentedTabs()
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:tabs', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:tabs', 216), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:tabs', 216), this.motionMode)
        : null)

      Column() {
        this.modeContentCard()
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:mode', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:mode', 356), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:mode', 356), this.motionMode)
        : null)

      this.feedbackBlock()

      Row({ space: 10 }) {
        Text('电脑端安装与启用引导 ›')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.onGoOtherStep();
          })

        Blank()

        Text('连不上排查')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.helpSheet = true;
          })
      }
      .width('100%')
      .margin({ top: 16 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:foot', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:foot', 496), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:foot', 496), this.motionMode)
        : null)
      .bindSheet($$this.helpSheet, this.helpSheetContent(),
        Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
          this.helpSheet = false;
        }))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  prepareScreen() {
    Column({ space: 10 }) {
      Column({ space: 4 }) {
        Row({ space: 8 }) {
          Text('第 1 步 / 共 2 步')
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          Text('先完成电脑端准备')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
          Blank()
          Text('直接连接 ›')
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              Haptics.tap();
              this.onGoOtherStep();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 4 })

        Text('在电脑上准备 Agent Mobile 网关')
          .fontSize(Tokens.fsDisplay)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
        Text('完成以下三步后，回到快速连接页扫码或输入 6 位码即可控制电脑上的多个智能体。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim2)
          .lineHeight(19)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 6 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:hdr', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('prep:hdr', 0), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('prep:hdr', 0), this.motionMode)
        : null)

      Column() {
        this.prepareStepCard('1', '安装并启用 agent-mobile-gateway',
          '在电脑终端添加网关插件后重启服务，保持网关监听在本地端口（默认 8901）。')
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:step1', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:step1', 120), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:step1', 120), this.motionMode)
        : null)

      Row({ space: 8 }) {
        Text(PAIR_CMD)
          .fontSize(Tokens.fsFoot)
          .fontFamily('monospace')
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('复制')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .onClick(() => {
            Haptics.tap();
            void copyText(PAIR_CMD, '已复制安装命令');
          })
      }
      .width('100%')
      .padding({ left: 14, right: 10, top: 12, bottom: 12 })
      .backgroundColor(Tokens.bgEl)
      .borderRadius(Tokens.rMd)
      .border({ width: 1, color: Tokens.lineSoft })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:cmd', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:cmd', 216), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:cmd', 216), this.motionMode)
        : null)

      Column() {
        this.prepareStepCard('2', '打开电脑端「Agent Mobile」面板',
          '在桌面侧栏打开 Agent Mobile 面板，页面上方会展示配对二维码、6 位配对码与入口地址。')
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:step2', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:step2', 310), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:step2', 310), this.motionMode)
        : null)

      Column() {
        this.prepareStepCard('3', '外网与远程配对准备（可选）',
          '同 Wi-Fi 下可直接扫码连接；配置公网地址或隧道后，支持异地远程配对申请或粘贴一次性配对口令。')
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:step3', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:step3', 416), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:step3', 416), this.motionMode)
        : null)

      Text('我已准备好，前往连接')
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.accentInk)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(48)
        .backgroundColor(Tokens.accent)
        .borderRadius(Tokens.rPill)
        .margin({ top: 10 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('prep:go', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:go', 512), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:go', 512), this.motionMode)
          : null)
        .onClick(() => {
          Haptics.confirm();
          this.onGoOtherStep();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Scroll(this.scroller) {
        Column() {
          Column() {
            if (this.isPrepareMode()) {
              this.prepareScreen()
            } else {
              this.connectScreen()
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: this.wideScreen ? 560 : 520 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({
          left: 16,
          right: 16,
          top: this.topInset + 68,
          bottom: this.bottomInset + 36
        })
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)

      TopFade({ fadeHeight: this.topInset + 68 })
      Column() {
        PageHeader({
          title: this.isPrepareMode() ? '电脑端准备' : '连接电脑',
          hasBack: this.hasBack,
          padTop: true,
          popIn: this.popHeader,
          subPageDepth: this.subPageDepth,
          onBack: () => {
            this.onExit();
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
