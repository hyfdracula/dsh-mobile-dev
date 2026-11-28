import { scanBarcode } from '@kit.ScanKit';
import http from '@ohos.net.http';
import { Api } from '../common/Api';
import { isLanUrl } from '../common/ApiUtil';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK } from '../common/AppIcon';
import { CardIcon } from '../common/CardIcon';
import { PageHeader, TopFade } from '../common/Chrome';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { PairClaim, PairError, Pairing, PairLink } from '../common/Pairing';
import { Tokens } from '../common/Tokens';
import { ConnectionStageCard, SheetHeader } from '../common/Widgets';

const PAIR_CMD: string = 'dsh plugin --profile desktop add dsh-mobile-connect';

const PAIR_STAGES: string[] = [
  '读取配对信息',
  '自动寻找最快通道',
  '校验安全加密身份',
  '完成连接并保存'
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
 * 极简两步配对向导（面向零基础新手）：
 * - prepare（第 1 步 · 电脑端准备）：详细 2 步安装与开启指南 + 一键复制命令 + 底部唯一「下一步」入口；
 * - connect（第 2 步 · 连接电脑）：仅保留「扫一扫」与「连接令牌」两种方式，局域网与外网自动适配，不区分远程/非远程。
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

  @State private entered: boolean = true;
  @State private inviteText: string = '';
  @State private manualOpen: boolean = false;
  @State private manualBase: string = '';
  @State private manualToken: string = '';
  @State private manualName: string = '';

  @State private busy: boolean = false;
  @State private err: string = '';
  @State private okMsg: string = '';
  @State private hint: string = '';

  @State private stageActive: boolean = false;
  @State private stageIdx: number = 0;
  @State private stageDetail: string = '';
  @State private stageErr: string = '';
  @State private elapsedSec: number = 0;
  @State private lastBases: string[] = [];
  @State private lastCode: string = '';

  @State private helpSheet: boolean = false;

  private claimSeq: number = 0;
  private elapsedTimer: number = -1;
  private enterTimer: number = -1;
  private autoParseTimer: number = -1;
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
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.autoParseTimer >= 0) {
      clearTimeout(this.autoParseTimer);
      this.autoParseTimer = -1;
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

  private scrollToFeedback(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
      }
    }, 60);
  }

  private cancelClaim(): void {
    this.claimSeq++;
    this.stopTimer();
    this.busy = false;
    this.stageActive = false;
    this.stageErr = '';
    this.hint = '已取消本次连接，可重新扫码或粘贴令牌。';
  }

  private isValidHostUrl(norm: string): boolean {
    return /^https?:\/\/([a-z0-9_-]+(\.[a-z0-9_-]+)*|\[[0-9a-f:]+\])(:\d{1,5})?(\/[^\s]*)?$/i.test(norm);
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
      '检测到外网地址 ' + insecureUrl + ' 未启用 HTTPS，建议改用加密隧道后连接。是否仍要继续？',
      '仍然连接',
      proceed,
      false,
      '取消'
    );
  }

  private tryApplyInviteLink(raw: string): boolean {
    const link: PairLink | null = Pairing.parseLink(raw);
    if (link === null) {
      return false;
    }
    this.inviteText = '';
    this.err = '';
    this.stageErr = '';
    this.hint = '已识别连接令牌，正在自动连接电脑…';
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

  private clearAutoParse(): void {
    if (this.autoParseTimer >= 0) {
      clearTimeout(this.autoParseTimer);
      this.autoParseTimer = -1;
    }
  }

  private scheduleAutoParse(v: string): void {
    this.clearAutoParse();
    if (this.busy || v.indexOf('dshmobile://pair?') < 0) {
      return;
    }
    this.autoParseTimer = setTimeout(() => {
      this.autoParseTimer = -1;
      if (!this.busy && this.inviteText === v) {
        this.tryApplyInviteLink(v);
      }
    }, 240);
  }

  private submitTokenInput(): void {
    this.clearAutoParse();
    const raw: string = this.inviteText.trim();
    if (raw === '') {
      this.stageActive = false;
      this.err = '请先粘贴电脑端或已连接手机复制的连接令牌（以 dshmobile:// 开头）。';
      this.scrollToFeedback();
      return;
    }
    if (this.tryApplyInviteLink(raw)) {
      return;
    }
    // 兼容用户误把长期访问令牌粘贴到此处：引导展开下方地址+长期令牌
    this.stageActive = false;
    if (raw.indexOf('://') < 0 && raw.length >= 20) {
      this.manualToken = raw;
      this.manualOpen = true;
      this.err = '检测到你粘贴的可能是长期访问令牌，已为你填入下方「访问令牌」，请补充电脑地址后连接。';
    } else {
      this.err = '未识别到有效的连接令牌，请在电脑「Agent Mobile」面板点击「复制连接令牌」后完整粘贴。';
    }
    this.scrollToFeedback();
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
      this.err = '未找到可用连接地址，请重新扫码或重新复制电脑端的连接令牌。';
      this.scrollToFeedback();
      return;
    }
    const c: string = codeStr.trim();
    if (c.length !== 6) {
      this.stageActive = false;
      this.err = '连接令牌不完整，请重新扫码或重新复制连接令牌。';
      this.scrollToFeedback();
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
    this.stageDetail = '已获取 ' + String(list.length) + ' 条可用通道，准备尝试连接…';
    this.startTimer();
    this.scrollToFeedback();

    try {
      await new Promise<void>((r: () => void) => setTimeout(r, 60));
      if (seq !== this.claimSeq) {
        return;
      }
      this.stageIdx = 1;
      this.stageDetail = '正在尝试第 1 / ' + String(list.length) + ' 条通道…';

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
      const hostId: string = res.hostId !== undefined && res.hostId !== '' ? res.hostId : '';
      const e2eePub: string = res.e2eePub !== undefined && res.e2eePub !== '' ? res.e2eePub : '';

      this.stageIdx = 3;
      this.stageDetail = '连接成功，正在保存本机加密凭据 · ' + hostLabel;
      this.okMsg = '已连接到电脑 · ' + hostLabel;
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
        : '暂时连不上电脑，请确认电脑上的 DSH 正在运行后重试。';
      this.stageIdx = e instanceof PairError ? 2 : 1;
      this.stageErr = msg;
      this.err = msg;
      this.scrollToFeedback();
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
      this.scrollToFeedback();
      return;
    }
    const norm: string = Pairing.normalizeBase(rawBase);
    if (!this.isValidHostUrl(norm)) {
      this.stageActive = false;
      this.stageErr = '';
      this.err = '地址格式无效，例如 192.168.1.10:8901 或 https://example.com';
      this.scrollToFeedback();
      return;
    }
    if (rawToken === '') {
      this.stageActive = false;
      this.stageErr = '';
      this.err = '请填写访问令牌。';
      this.scrollToFeedback();
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
    this.stageDetail = '正在验证连接地址与访问令牌…';
    this.startTimer();
    this.scrollToFeedback();

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
        throw new PairError(resp.responseCode, '访问令牌不正确或已失效，请在电脑端重新复制后再试。');
      }
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error('电脑返回异常状态（HTTP ' + String(resp.responseCode) + '），请确认地址和隧道正常。');
      }
      let info: ManualInfoResp = {};
      try {
        info = JSON.parse(resp.result as string) as ManualInfoResp;
      } catch (e) {
        throw new Error('返回内容格式异常，请确认地址指向电脑端 Agent Mobile 服务。');
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
      this.stageDetail = '验证通过，正在保存加密凭据 · ' + hostName;
      this.okMsg = '已连接到电脑 · ' + hostName;
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
        : '暂时连不上该地址，请检查网络或电脑服务状态。';
      this.stageIdx = e instanceof PairError ? 2 : 1;
      this.stageErr = msg;
      this.err = msg;
      this.scrollToFeedback();
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
        this.err = '未能识别该二维码，请扫描电脑端「Agent Mobile」面板里的配对二维码。';
        this.scrollToFeedback();
        return;
      }
      this.hint = '已识别二维码，正在自动匹配最佳通道…';
      const bases: string[] = [link.base];
      for (let i = 0; i < link.alts.length; i++) {
        if (bases.indexOf(link.alts[i]) < 0) {
          bases.push(link.alts[i]);
        }
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
      this.err = '暂时无法打开相机扫码，请改用下方「连接令牌」直接粘贴连接。';
      this.scrollToFeedback();
    }
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
          .animation(null)
          .opacity(this.entered ? 1 : 0)
          .animation(this.entered
            ? Motion.iconFlyOpacityAnimByDist(this.wave.distanceOf('conn:hero', 96), this.motionMode)
            : null)
          .scale({
            x: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
            y: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
            centerX: '50%',
            centerY: '50%'
          })
          .animation(this.entered
            ? Motion.iconFlyScaleAnimByDist(this.wave.distanceOf('conn:hero', 96), this.motionMode)
            : null)
          .rotate({
            angle: this.entered ? 0 : Motion.ICON_FLY_ROTATE_START,
            centerX: '50%',
            centerY: '50%'
          })
          .animation(this.entered
            ? Motion.iconFlyRotateAnimByDist(this.wave.distanceOf('conn:hero', 96), this.motionMode)
            : null)
        Column({ space: 3 }) {
          Text('方式一：扫一扫二维码')
            .fontSize(Tokens.fsTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          Text('对准电脑端「Agent Mobile」面板里的二维码扫一下即可，局域网和外网自动匹配')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(18)
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
        Text(this.busy ? '正在连接电脑…' : '扫一扫连接电脑')
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
  tokenConnectCard() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        CardIcon({
          symbol: $r('sys.symbol.key_shield_fill'),
          badgeSize: 32,
          glyphSize: 28,
          entered: this.entered,
          distanceVp: this.wave.distanceOf('conn:mode', 280)
        })
        Column({ space: 3 }) {
          Text('方式二：粘贴连接令牌')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          Text('不方便扫码时，粘贴电脑端或已连接手机复制的「连接令牌」，同样支持局域网与外网自动连上')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(18)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextInput({ text: this.inviteText, placeholder: '粘贴 dshmobile://... 连接令牌' })
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .cancelButton({ style: CancelButtonStyle.INPUT })
        .height(46)
        .width('100%')
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rInput)
        .onChange((v: string) => {
          this.inviteText = v;
          if (this.err !== '') {
            this.err = '';
          }
          this.scheduleAutoParse(v);
        })

      Text(this.busy ? '正在连接电脑…' : '立即连接')
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(!this.busy && this.inviteText.trim() !== '' ? Tokens.accentInk : Tokens.dim)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(46)
        .backgroundColor(!this.busy && this.inviteText.trim() !== '' ? Tokens.accentStrong : Tokens.surface3)
        .borderRadius(Tokens.rPill)
        .opacity(!this.busy && this.inviteText.trim() !== '' ? 1 : 0.65)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          if (!this.busy) {
            this.submitTokenInput();
          }
        })

      Row() {
        Text(this.manualOpen ? '收起手动地址与长期令牌 ▴' : '有电脑地址与长期访问令牌？点此填写 ▾')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .padding({ top: 4, bottom: 2 })
          .onClick(() => {
            Haptics.tap();
            this.manualOpen = !this.manualOpen;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)

      if (this.manualOpen) {
        Column({ space: 10 }) {
          TextInput({ text: this.manualBase, placeholder: '电脑地址，如 https://... 或 192.168.1.10:8901' })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .cancelButton({ style: CancelButtonStyle.INPUT })
            .height(44)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rInput)
            .onChange((v: string) => {
              this.manualBase = v;
              if (this.err !== '') {
                this.err = '';
              }
            })

          TextInput({ text: this.manualToken, placeholder: '访问令牌（在电脑配置文件或面板中查看）' })
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

          TextInput({ text: this.manualName, placeholder: '给这台电脑起个备注名（可选）' })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .height(44)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rInput)
            .onChange((v: string) => {
              this.manualName = v;
            })

          Text(this.busy ? '正在校验令牌…' : '验证令牌并连接')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(!this.busy && this.manualBase.trim() !== '' && this.manualToken.trim() !== '' ? Tokens.accentInk : Tokens.dim)
            .textAlign(TextAlign.Center)
            .width('100%')
            .height(44)
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
        .width('100%')
        .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rCard)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .margin({ top: 12 })
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
            Text('暂时还没连上')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.err)
            Text(this.err)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.err)
              .lineHeight(19)
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
          if (this.lastBases.length > 0 && this.lastCode.length === 6) {
            Text('重新连接')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .onClick(() => {
                void this.runClaim(this.lastBases, this.lastCode);
              })
          }
          Text('查看排查方法')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.fg)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .onClick(() => {
              Haptics.tap();
              this.helpSheet = true;
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
        title: '连不上电脑怎么办',
        subtitle: '按下面 3 步快速排查',
        onClose: () => {
          this.helpSheet = false;
        }
      })

      Column({ space: 12 }) {
        Text('1. 确认电脑上的 DSH 处于运行状态，并且「Agent Mobile」页面里能正常看到二维码。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(21)
        Text('2. 手机和电脑连在同一 Wi-Fi 时，如果一直连接超时，请检查电脑防火墙是否放行了 8901 端口，或避开访客隔离 Wi-Fi。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(21)
        Text('3. 不在同一 Wi-Fi（如用手机流量）时，请确认电脑端已配置并连通公网入口，随后直接扫码或粘贴新的连接令牌即可自动连通。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(21)
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

      Column({ space: 6 }) {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
        Text(desc)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(20)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
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
        Text('任选一种方式连接，局域网与外网通用')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
      }
      .width('100%')
      .margin({ bottom: 12 })
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
        this.tokenConnectCard()
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:mode', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:mode', 280), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:mode', 280), this.motionMode)
        : null)

      this.feedbackBlock()

      Row({ space: 10 }) {
        Text('‹ 上一步')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.accent)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.onGoOtherStep();
          })

        Blank()

        Text('连不上怎么办')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.helpSheet = true;
          })
      }
      .width('100%')
      .margin({ top: 18 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:foot', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:foot', 440), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:foot', 440), this.motionMode)
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
    Column({ space: 12 }) {
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text('第 1 步 / 共 2 步')
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          Text('先完成电脑端安装，再扫码或粘贴令牌连接')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 4 })

        Text('在电脑上安装连接插件')
          .fontSize(Tokens.fsDisplay)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
        Text('按下面 2 步在电脑装好插件并打开配对页面，之后就能用手机随时控制电脑上的智能体。')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim2)
          .lineHeight(20)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 4 })
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
        this.prepareStepCard(
          '1',
          '在电脑终端运行安装命令并重启 DSH',
          '① 先在电脑上安装并登录 DeepSeek Harness（DSH）桌面端；\n' +
            '② 打开电脑命令行窗口（Windows 按 Win + R 输入 cmd 后回车；Mac 打开「终端」）；\n' +
            '③ 复制下方命令粘贴到窗口中按回车执行，等提示安装完成后，彻底退出并重新打开 DSH。'
        )
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

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(PAIR_CMD)
            .fontSize(Tokens.fsFoot)
            .fontFamily('monospace')
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          Text('复制命令')
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .padding({ left: 11, right: 11, top: 7, bottom: 7 })
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
            .onClick(() => {
              Haptics.tap();
              void copyText(PAIR_CMD, '已复制安装命令');
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text('提示：若执行时提示找不到 dsh 命令，说明电脑尚未安装 DSH 桌面端或未加入系统路径。')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .lineHeight(17)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 14, right: 12, top: 12, bottom: 12 })
      .backgroundColor(Tokens.bgEl)
      .borderRadius(Tokens.rMd)
      .border({ width: 1, color: Tokens.lineSoft })
      .alignItems(HorizontalAlign.Start)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:cmd', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:cmd', 240), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:cmd', 240), this.motionMode)
        : null)

      Column() {
        this.prepareStepCard(
          '2',
          '打开电脑上的「Agent Mobile」页面',
          '重新打开 DSH 后，点击左侧栏或「设置」里的「Agent Mobile」，页面上方就会显示配对二维码和「复制连接令牌」按钮。接下来点下方按钮去连接即可。'
        )
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('prep:step2', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:step2', 350), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:step2', 350), this.motionMode)
        : null)

      Text('我已准备好，下一步')
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.accentInk)
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(48)
        .backgroundColor(Tokens.accent)
        .borderRadius(Tokens.rPill)
        .margin({ top: 8 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('prep:go', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('prep:go', 460), this.motionMode)
          : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('prep:go', 460), this.motionMode)
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
