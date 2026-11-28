import { Api, PairInviteResp, RemotePairPendingItem } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Machines } from '../common/Machines';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { Pairing } from '../common/Pairing';
import { PickerOption, PopupPicker } from '../common/PopupPicker';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel } from '../common/Widgets';
import { ConnectForm } from './ConnectForm';
import { DeviceCard } from './DeviceCard';
import { MachineList } from './MachineList';

const NET_MODE_OPTIONS: PickerOption[] = [
  { id: 'auto', label: '自动', sub: '同 Wi-Fi 优先局域网直连，出门自动切公网' },
  { id: 'lan', label: '仅局域网', sub: '不回退公网隧道入口' },
  { id: 'wan', label: '仅公网', sub: '始终走公网安全隧道' }
];

/**
 * 「连接与设备」面板：
 * 多电脑切换、网络策略（PopupPicker）、手动地址表单、
 * 外网访问双入口（统一让 AI 帮你配 & 手动向导）与当前设备概况。
 */
@Component
export struct ConnectPanel {
  api: Api = new Api('', '');
  @Link editBase: string;
  @Link editToken: string;
  @Prop saved: string = '';
  @Prop saveErr: string = '';
  @Prop saving: boolean = false;
  @Prop saveStage: number = 0;
  @Prop saveDetail: string = '';
  @Prop saveElapsed: number = 0;
  @Prop netMode: string = 'auto';
  @Prop machineName: string = '';
  @Prop currentBase: string = '';
  @Prop pluginVersion: string = '';
  @Prop sessionsCount: number = -1;
  @Prop connected: boolean = false;
  @Prop linkLoading: boolean = false;
  @Prop isLanLink: boolean = false;

  onSave: () => void = () => {};
  onNetMode: (mode: string) => void = () => {};
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  onOpenPair: (entry: string) => void = () => {};
  onOpenGuide: (kind: string) => void = () => {};
  onReconnect: () => void = () => {};
  onRemoveCurrent: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('linkEncrypted') linkEncrypted: boolean = false;

  @State private addOn: boolean = false;
  @State private addBase: string = '';
  @State private addToken: string = '';
  @State private addName: string = '';
  @State private addErr: string = '';

  @State private renameOn: boolean = false;
  @State private renameId: string = '';
  @State private renameName: string = '';
  @State private renameErr: string = '';
  @State private pairReqs: RemotePairPendingItem[] = [];
  @State private pairReqBusyId: string = '';
  @State private inviteBusy: boolean = false;
  @State private inviteCode: string = '';
  @State private invitePayload: string = '';
  @State private inviteHasPublic: boolean = false;
  @State private inviteExpiresAt: number = 0;
  @State private entered: boolean = true;
  private enterTimer: number = -1;
  private pairReqTimer: number = -1;
  private pairReqPollInFlight: boolean = false;
  private wave: BloomWaveTracker = new BloomWaveTracker();

  aboutToAppear(): void {
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 24);
    } else {
      this.entered = true;
    }
    void this.refreshPairRequests();
    this.pairReqTimer = setInterval(() => {
      void this.refreshPairRequests();
    }, 3000);
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.pairReqTimer >= 0) {
      clearInterval(this.pairReqTimer);
      this.pairReqTimer = -1;
    }
  }

  private async refreshPairRequests(): Promise<void> {
    if (!this.connected || this.pairReqPollInFlight) {
      return;
    }
    this.pairReqPollInFlight = true;
    try {
      this.pairReqs = await this.api.listPairRequests();
    } catch (e) {
    } finally {
      this.pairReqPollInFlight = false;
    }
  }

  private async handleDecidePairRequest(id: string, approve: boolean): Promise<void> {
    if (this.pairReqBusyId !== '') {
      return;
    }
    this.pairReqBusyId = id;
    try {
      this.pairReqs = await this.api.decidePairRequest(id, approve);
      if (approve) {
        Haptics.success();
        Toast.ok('已批准新设备配对');
      } else {
        Haptics.soft();
        Toast.info('已拒绝该配对申请');
      }
    } catch (e) {
      Haptics.error();
      Toast.err('审批失败：' + ((e as Error).message ?? '请稍后重试'));
    } finally {
      this.pairReqBusyId = '';
    }
  }

  private async handleCreatePairInvite(): Promise<void> {
    if (this.inviteBusy) {
      return;
    }
    if (!this.connected) {
      Toast.info('请先连接到电脑后再生成配对口令');
      return;
    }
    this.inviteBusy = true;
    try {
      const res: PairInviteResp = await this.api.createPairInvite();
      const payload: string = res.payload !== undefined ? res.payload : '';
      if (res.ok !== true || payload === '') {
        throw new Error(res.error !== undefined && res.error !== '' ? res.error : '电脑未开启新设备配对');
      }
      this.inviteCode = res.code !== undefined ? res.code : '';
      this.invitePayload = payload;
      this.inviteHasPublic = res.publicUrl !== undefined && res.publicUrl.trim() !== '';
      this.inviteExpiresAt = res.expiresAt !== undefined ? res.expiresAt : 0;
      Haptics.success();
      await copyText(payload, '已复制远程配对口令');
    } catch (e) {
      Haptics.error();
      Toast.err('生成失败：' + ((e as Error).message ?? '请确认电脑网关已升级并开启配对'));
    } finally {
      this.inviteBusy = false;
    }
  }

  private confirmRemoveMachine(id: string): void {
    Haptics.warn();
    AppCtx.confirm(
      '忘记这台电脑',
      '会从这台手机上删掉它的地址与令牌；电脑端不受影响。',
      '忘记',
      () => {
        this.onRemoveMachine(id);
      },
      true
    );
  }

  private submitAddMachine(): void {
    const rawBase: string = this.addBase.trim();
    const rawToken: string = this.addToken.trim();
    if (rawBase === '') {
      this.addErr = '请填写这台电脑的连接地址。';
      Haptics.error();
      return;
    }
    if (rawBase.indexOf('://') >= 0 && !/^https?:\/\//i.test(rawBase)) {
      this.addErr = '连接地址仅支持 http:// 或 https:// 协议。';
      Haptics.error();
      return;
    }
    const norm: string = Pairing.normalizeBase(rawBase);
    if (!/^https?:\/\/[^\s/]+/i.test(norm)) {
      this.addErr = '连接地址格式不正确，请检查域名或 IP 端口。';
      Haptics.error();
      return;
    }
    if (rawToken === '') {
      this.addErr = '请填写访问令牌。';
      Haptics.error();
      return;
    }
    Haptics.confirm();
    this.addErr = '';
    this.addOn = false;
    this.onAddMachine(norm, rawToken, this.addName.trim());
    Toast.ok('已添加并切换');
  }

  private submitRenameMachine(): void {
    const name: string = this.renameName.trim();
    if (name === '') {
      this.renameErr = '电脑名称不能为空。';
      Haptics.error();
      return;
    }
    Haptics.confirm();
    Machines.rename(this.renameId, name);
    this.renameErr = '';
    this.renameOn = false;
    Toast.ok('已重命名');
  }

  @Builder
  sectionTitle(text: string, topMargin: number, waveKey: string, fallbackDistVp: number) {
    Text(text)
      .fontSize(Tokens.fsCaption)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.4)
      .margin({ left: 6, top: topMargin, bottom: 8 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record(waveKey, area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
        : null)
  }

  @Builder
  addMachineChip(label: string, entry: string) {
    Text(label)
      .fontSize(Tokens.fsBody)
      .fontColor(Tokens.accent)
      .backgroundColor(Tokens.accentSoft)
      .borderRadius(Tokens.rPill)
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .margin({ right: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        Haptics.tap();
        if (entry === 'manual') {
          this.addBase = '';
          this.addToken = '';
          this.addName = '';
          this.addErr = '';
          this.addOn = true;
          return;
        }
        this.onOpenPair(entry);
      })
  }

  @Builder
  addMachineSheet() {
    Scroll() {
      Column() {
        Row() {
          Text('添加电脑')
            .fontSize(Tokens.fsTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          HintLabel({
            title: '',
            tipText: '填入另一台电脑的地址与访问令牌即可切换；同一台电脑无需重复添加。'
          })
          .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 14 })

        TextInput({ text: this.addName, placeholder: '备注名称（可留空）' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .margin({ bottom: 10 })
          .onChange((v: string) => {
            this.addName = v;
          })

        TextInput({ text: this.addBase, placeholder: 'https://dsh.example.com 或 192.168.1.3:8901' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .margin({ bottom: 10 })
          .onChange((v: string) => {
            this.addBase = v;
            if (this.addErr !== '') {
              this.addErr = '';
            }
          })

        TextInput({ text: this.addToken, placeholder: '访问令牌' })
          .type(InputType.Password)
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onChange((v: string) => {
            this.addToken = v;
            if (this.addErr !== '') {
              this.addErr = '';
            }
          })

        if (this.addErr !== '') {
          Text(this.addErr)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .width('100%')
            .padding(10)
            .margin({ top: 10 })
            .backgroundColor(Tokens.intrBg)
            .borderRadius(Tokens.rSm)
        }

        Row() {
          Text('取消')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              Haptics.soft();
              this.addOn = false;
            })
          Text('添加并切换')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.submitAddMachine();
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: this.bottomInset + 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
  }

  @Builder
  renameMachineSheet() {
    Scroll() {
      Column() {
        Text('重命名这台电脑')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.fg)
          .margin({ bottom: 14 })

        TextInput({ text: this.renameName, placeholder: '给这台电脑起个名字' })
          .height(44)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .borderRadius(Tokens.rInput)
          .backgroundColor(Tokens.surface2)
          .onChange((v: string) => {
            this.renameName = v;
            if (this.renameErr !== '') {
              this.renameErr = '';
            }
          })

        if (this.renameErr !== '') {
          Text(this.renameErr)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .width('100%')
            .padding(10)
            .margin({ top: 10 })
            .backgroundColor(Tokens.intrBg)
            .borderRadius(Tokens.rSm)
        }

        Row() {
          Text('取消')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              Haptics.soft();
              this.renameOn = false;
            })
          Text('保存')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .height(46)
            .textAlign(TextAlign.Center)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.accent)
            .margin({ left: 10 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              this.submitRenameMachine();
            })
        }
        .width('100%')
        .margin({ top: 16 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: this.bottomInset + 20 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
  }

  private linkSummaryText(): string {
    if (this.linkLoading) {
      return '正在检测连接…';
    }
    if (!this.connected) {
      return '未连接 · 请检查网络或重新配对';
    }
    const route: string = this.isLanLink ? '已连接 · 局域网直连' : '已连接 · 公网入口';
    return this.linkEncrypted ? route + ' · 端到端加密' : route;
  }

  @Builder
  linkStatusCard() {
    Column() {
      Row() {
        Row()
          .width(8)
          .height(8)
          .borderRadius(Tokens.rPill)
          .backgroundColor(this.linkLoading ? Tokens.dim2 : (this.connected ? Tokens.ok : Tokens.err))
        Text(this.linkSummaryText())
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.linkLoading ? Tokens.dim2 : (this.connected ? Tokens.fg : Tokens.err))
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (!this.linkLoading && this.connected && this.linkEncrypted) {
          Text('端到端加密')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.doneInk)
            .backgroundColor(Tokens.doneBg)
            .borderRadius(Tokens.rPill)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.currentBase !== '') {
        Text(this.currentBase)
          .fontSize(Tokens.fsCaption)
          .fontFamily('monospace')
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .borderRadius(Tokens.rRow)
    .clip(true)
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 6, bottom: 6 })
    .onAreaChange((_old: Area, area: Area) => {
      this.wave.record('conn:status', area);
    })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:status', 0), this.motionMode)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:status', 0), this.motionMode)
      : null)
  }

  @Builder
  guideEntryCard(title: string, sub: string, tag: string, kind: string, waveKey: string, fallbackDistVp: number) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.fg)
        Text(sub)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 8 })

      Text(tag)
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.accent)
        .backgroundColor(Tokens.accentSoft)
        .borderRadius(Tokens.rPill)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .margin({ right: 8 })

      if (Motion.isFlagship(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Tokens.dim2])
      } else {
        Text('›')
          .fontSize(17)
          .fontColor(Tokens.dim2)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .borderRadius(Tokens.rRow)
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onAreaChange((_old: Area, area: Area) => {
      this.wave.record(waveKey, area);
    })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
    .onClick(() => {
      Haptics.tap();
      this.onOpenGuide(kind);
    })
  }

  @Builder
  remotePairSection() {
    this.sectionTitle('远程配对新设备', 16, 'hdr:remotePair', 256)
    Column({ space: 9 }) {
      if (this.pairReqs.length > 0) {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Row()
              .width(7)
              .height(7)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.accent)
            Text('待审批的远程配对申请')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .layoutWeight(1)
            Text(String(this.pairReqs.length) + ' 条')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          ForEach(this.pairReqs, (req: RemotePairPendingItem) => {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text(req.deviceName !== '' ? req.deviceName : '新设备')
                  .fontSize(Tokens.fsBody)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.fg)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(req.source === 'lan' ? '局域网' : '公网远程')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(req.source === 'lan' ? Tokens.doneInk : Tokens.accent)
                  .backgroundColor(req.source === 'lan' ? Tokens.doneBg : Tokens.accentSoft)
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              }
              .width('100%')

              Row({ space: 10 }) {
                Text('验证码')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                Text(req.verifyCode)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontFamily('monospace')
                  .fontColor(Tokens.accent)
                Blank()
                if (req.expiresAt > 0) {
                  Text('约 ' + String(Math.max(1, Math.ceil((req.expiresAt - Date.now()) / 1000))) + 's 有效')
                    .fontSize(Tokens.fsCaption)
                    .fontFamily('monospace')
                    .fontColor(Tokens.dim2)
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Text('拒绝')
                  .fontSize(Tokens.fsFoot)
                  .fontColor(Tokens.fg)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(36)
                  .backgroundColor(Tokens.surface)
                  .borderRadius(Tokens.rSm)
                  .border({ width: 1, color: Tokens.lineSoft })
                  .opacity(this.pairReqBusyId === req.id ? 0.5 : 1)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                  .onClick(() => {
                    void this.handleDecidePairRequest(req.id, false);
                  })

                Text(this.pairReqBusyId === req.id ? '处理中…' : '批准配对')
                  .fontSize(Tokens.fsFoot)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.accentInk)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1.4)
                  .height(36)
                  .backgroundColor(Tokens.accent)
                  .borderRadius(Tokens.rSm)
                  .opacity(this.pairReqBusyId === req.id ? 0.5 : 1)
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                  .onClick(() => {
                    void this.handleDecidePairRequest(req.id, true);
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding(12)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rSm)
            .alignItems(HorizontalAlign.Start)
          }, (req: RemotePairPendingItem) => req.id)
        }
        .width('100%')
        .padding(14)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border({ width: 1, color: Tokens.accentGlass })
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .alignItems(HorizontalAlign.Start)
      }

      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Column({ space: 3 }) {
            Text('生成一次性远程配对口令')
              .fontSize(Tokens.fsBodyLg)
              .fontColor(Tokens.fg)
            Text('5 分钟内有效且不含长期令牌，发给新手机粘贴即可一键配对')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .lineHeight(17)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.inviteBusy ? '生成中…' : '生成口令')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .backgroundColor(Tokens.accent)
            .borderRadius(Tokens.rPill)
            .padding({ left: 13, right: 13, top: 8, bottom: 8 })
            .opacity(this.inviteBusy || !this.connected ? 0.55 : 1)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
            .onClick(() => {
              void this.handleCreatePairInvite();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.invitePayload !== '') {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text('6 位配对码：' + this.inviteCode)
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontFamily('monospace')
                .fontColor(Tokens.fg)
              Text(this.inviteHasPublic ? '已优先附带公网入口 · 仅限单次使用' : '当前未配公网地址 · 仅含局域网入口')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('再次复制')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .onClick(() => {
                Haptics.tap();
                void copyText(this.invitePayload, '已复制远程配对口令');
              })
          }
          .width('100%')
          .padding({ left: 11, right: 11, top: 9, bottom: 9 })
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rSm)
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rRow)
      .clip(true)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .onAreaChange((_old: Area, area: Area) => {
      this.wave.record('conn:remotePair', area);
    })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:remotePair', 274), this.motionMode)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:remotePair', 274), this.motionMode)
      : null)
  }

  build() {
    Column() {
      // 0. 当前连接与加密态
      this.linkStatusCard()

      // 1. 多电脑管理
      this.sectionTitle('电脑', 10, 'hdr:machines', 80)
      Column() {
        MachineList({
          onPick: (id: string) => {
            this.onPickMachine(id);
            Toast.ok('已切换电脑');
          },
          onRemove: (id: string) => {
            this.confirmRemoveMachine(id);
          },
          onRename: (id: string, name: string) => {
            this.renameId = id;
            this.renameName = name;
            this.renameErr = '';
            this.renameOn = true;
          }
        })
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:machines', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:machines', 140), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:machines', 140), this.motionMode)
        : null)
      .bindSheet($$this.renameOn, this.renameMachineSheet(),
        Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
          this.renameOn = false;
        }, true, true))

      Row() {
        this.addMachineChip('扫码 / 远程配对', 'scan')
        this.addMachineChip('新手引导', 'guide')
        this.addMachineChip('手动添加', 'manual')
      }
      .width('100%')
      .margin({ top: 2, bottom: 4 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:chips', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:chips', 220), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:chips', 220), this.motionMode)
        : null)
      .bindSheet($$this.addOn, this.addMachineSheet(),
        Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => {
          this.addOn = false;
        }, true, true))

      // 2. 远程配对新设备（异地审批 + 生成一次性口令）
      this.remotePairSection()

      // 3. 网络策略（独立单条卡片）
      this.sectionTitle('网络策略', 16, 'hdr:net', 284)
      Row() {
        Row() {
          Text('连接优先策略')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
          HintLabel({
            title: '',
            tipText: '自动：同一 Wi-Fi 下优先走局域网直连，出门自动走公网隧道；仅局域网：不回退隧道；仅公网：强制走隧道入口。'
          })
          .margin({ left: 6 })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        PopupPicker({
          options: NET_MODE_OPTIONS,
          selected: this.netMode,
          title: '连接优先策略',
          popupWidth: 236,
          onSelect: (mode: string) => {
            this.onNetMode(mode);
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rRow)
      .clip(true)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:net', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:net', 330), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:net', 330), this.motionMode)
        : null)

      // 4. 连接地址与外网（表单复合卡）
      this.sectionTitle('连接地址与外网', 16, 'hdr:form', 404)
      Column() {
        ConnectForm({
          base: $editBase,
          token: $editToken,
          saved: this.saved,
          errMsg: this.saveErr,
          saving: this.saving,
          stageIdx: this.saveStage,
          stageDetail: this.saveDetail,
          elapsedSec: this.saveElapsed,
          onSave: (): void => {
            this.onSave();
          },
          onRePair: (): void => {
            this.onOpenPair('scan');
          }
        })
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('conn:form', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('conn:form', 520), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('conn:form', 520), this.motionMode)
        : null)

      // 5-6. 外网访问配置（逐条独立卡片）
      this.sectionTitle('外网访问配置', 16, 'hdr:guide', 660)
      Column({ space: 9 }) {
        this.guideEntryCard('让 AI 帮你配', '复制完整指令给 Codex / Claude 等 AI 自动完成', '自动方案', 'ai', 'guide:ai', 710)
        this.guideEntryCard('外网访问配置向导', '按 7 步手动命令配置 Cloudflare 安全隧道', '手动向导', 'tunnel', 'guide:tunnel', 782)
      }
      .width('100%')

      // 7-12. 当前设备概况与断开/移除（内部逐条独立卡片，共享同一空间波纹追踪器）
      DeviceCard({
        name: this.machineName,
        base: this.currentBase,
        pluginVersion: this.pluginVersion,
        sessions: this.sessionsCount,
        startIdx: 7,
        entered: this.entered,
        wave: this.wave,
        onReconnect: (): void => {
          this.onReconnect();
        },
        onRemove: (): void => {
          this.onRemoveCurrent();
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
