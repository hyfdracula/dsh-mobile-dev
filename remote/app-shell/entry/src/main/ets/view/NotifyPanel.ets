import notificationManager from '@ohos.notificationManager';
import { Want } from '@kit.AbilityKit';
import { Api } from '../common/Api';
import { PushStatusResp, PushTestResp } from '../common/ApiTypes';
import { AppCtx } from '../common/AppCtx';
import { CardIcon } from '../common/CardIcon';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { Notifier } from '../common/Notifier';
import { PushBridge } from '../common/PushBridge';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { Unread } from '../common/Unread';
import { HintLabel, RowSwitch } from '../common/Widgets';

/**
 * 「通知」面板：
 * 顶部展示系统通知权限卡片，紧随提醒偏好、Push Kit 后台通道状态与测试/未读清理操作。
 */
@Component
export struct NotifyPanel {
  api: Api = new Api('', '');
  @Prop done: boolean = true;
  @Prop bgOnly: boolean = true;
  @Prop showTitle: boolean = true;
  onDone: (v: boolean) => void = () => {};
  onBgOnly: (v: boolean) => void = () => {};
  onShowTitle: (v: boolean) => void = () => {};
  onClearUnread?: () => void;

  @State private allowed: boolean = false;
  @StorageLink('notifyProbe') @Watch('onNotifyProbe') notifyProbe: number = 0;
  @StorageLink('unreadCount') unreadCount: number = 0;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('pushState') pushState: string = 'idle';
  @StorageLink('pushBindState') pushBindState: string = 'idle';
  @StorageLink('pushTokenPreview') pushTokenPreview: string = '';
  @StorageLink('pushErrMsg') pushErrMsg: string = '';
  @StorageLink('pushSynced') pushSynced: boolean = false;
  @State private relayLoading: boolean = false;
  @State private relayOk: boolean = false;
  @State private relayConfigured: boolean = false;
  @State private relayErr: string = '';
  @State private testPushBusy: boolean = false;
  @State private rotateBusy: boolean = false;
  @State private entered: boolean = true;
  private pollTimer: number = -1;
  private enterTimer: number = -1;
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
    Unread.count();
    void this.refreshPermission();
    void this.refreshPushChannel(false);
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private onNotifyProbe(): void {
    void this.refreshPermission();
  }

  private async refreshPermission(): Promise<void> {
    try {
      this.allowed = await notificationManager.isNotificationEnabled();
    } catch (e) {
      // 忽略权限读取异常
    }
  }

  private watchPermission(times: number = 24): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    let left: number = times;
    this.pollTimer = setInterval(() => {
      left = left - 1;
      void this.refreshPermission();
      if (left <= 0) {
        clearInterval(this.pollTimer);
        this.pollTimer = -1;
      }
    }, 800);
  }

  private async openSystemSettings(): Promise<void> {
    const ctx = AppCtx.ability();
    try {
      await notificationManager.openNotificationSettings(ctx);
      void this.refreshPermission();
      this.watchPermission();
      return;
    } catch (e) {
      // 回退系统授权弹窗
    }
    try {
      await notificationManager.requestEnableNotification(ctx);
      void this.refreshPermission();
      return;
    } catch (e) {
      // 回退应用详情页
    }
    try {
      const want: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility',
        uri: 'application_info_entry',
        parameters: { pushParams: AppCtx.bundleName() }
      };
      await ctx.startAbility(want);
    } catch (e) {
      Toast.err('无法打开系统通知设置');
    }
  }

  private clearUnread(): void {
    if (this.onClearUnread !== undefined) {
      this.onClearUnread();
    } else {
      Unread.clearAll();
      Toast.ok('已清除全部未读与桌面红点');
    }
    void this.refreshPermission();
  }

  private unreadSummaryText(): string {
    return this.unreadCount > 0 ? ('当前 ' + String(this.unreadCount) + ' 条未读') : '暂无未读';
  }

  private async refreshPushChannel(retryToken: boolean): Promise<void> {
    if (this.relayLoading) {
      return;
    }
    this.relayLoading = true;
    try {
      if (retryToken) {
        await PushBridge.refreshToken();
      }
      if (this.api.currentBase() === '') {
        this.relayOk = false;
        this.relayConfigured = false;
        this.relayErr = '未连接电脑网关，无法同步 Push Token';
        return;
      }
      if (PushBridge.hasToken()) {
        await PushBridge.syncToGateway(this.api, retryToken);
      }
      const st: PushStatusResp | null = await PushBridge.fetchGatewayStatus(this.api);
      if (st === null) {
        this.relayOk = false;
        this.relayConfigured = false;
        this.relayErr = '无法读取电脑网关推送状态（请确认网关已更新并保持在线）';
        return;
      }
      this.relayOk = st.relayOk === true;
      this.relayConfigured = st.relayConfigured === true;
      this.relayErr = st.relayError !== undefined ? st.relayError : '';
    } finally {
      this.relayLoading = false;
    }
  }

  private pushBadgeText(): string {
    if (this.pushState === 'ready' && this.relayConfigured) {
      return '通道就绪';
    }
    if (this.pushState === 'ready') {
      return '待配中继';
    }
    if (this.pushState === 'loading' || this.relayLoading) {
      return '检测中';
    }
    return '暂不可用';
  }

  private pushBadgeReady(): boolean {
    return this.pushState === 'ready' && this.relayConfigured;
  }

  private pushDetailText(): string {
    if (this.pushState === 'ready') {
      const tokPart: string = this.pushTokenPreview !== '' ? ('设备令牌 ' + this.pushTokenPreview) : '已获取设备令牌';
      if (this.pushBindState === 'relay_pending_deploy') {
        return tokPart + ' · 云端中继待部署 /v1/push/bind 后即可完成防刷绑定';
      }
      if (this.relayConfigured) {
        if (this.pushBindState === 'bound' && this.pushSynced) {
          return tokPart + ' · 已绑定防刷凭据并同步至电脑网关与云端中继';
        }
        if (this.pushBindState === 'bound') {
          return tokPart + ' · 已领取防刷凭据，待同步至电脑网关';
        }
        return tokPart + (this.pushSynced ? ' · 已同步至电脑网关，点击刷新状态完成防刷绑定' : ' · 待绑定防刷凭据');
      }
      if (this.api.currentBase() === '') {
        return tokPart + ' · 请先连接电脑端网关';
      }
      if (this.relayOk) {
        return tokPart + ' · 云端中继已在线，但尚未填入华为 AGC 服务账号密钥';
      }
      return tokPart + (this.relayErr !== '' ? (' · ' + this.relayErr) : ' · 云端推送中继暂未配置');
    }
    if (this.pushErrMsg !== '') {
      return this.pushErrMsg;
    }
    return '正在探测华为 Push Kit 通道状态…';
  }

  private async runRotateBinding(): Promise<void> {
    if (this.rotateBusy) {
      return;
    }
    if (this.api.currentBase() === '') {
      Haptics.warn();
      Toast.err('请先连接电脑端网关');
      return;
    }
    this.rotateBusy = true;
    try {
      const ok: boolean = await PushBridge.rotateBinding(this.api);
      if (ok) {
        Haptics.success();
        Toast.ok('已重置并同步防刷推送凭据');
      } else {
        Haptics.warn();
        Toast.err('凭据重置未完成，请确认云端中继已部署并重试');
      }
    } finally {
      this.rotateBusy = false;
    }
  }

  private async runTestPush(): Promise<void> {
    if (this.testPushBusy) {
      return;
    }
    if (this.api.currentBase() === '') {
      Haptics.warn();
      Toast.err('请先连接电脑端网关');
      return;
    }
    this.testPushBusy = true;
    try {
      const res: PushTestResp = await PushBridge.testPush(this.api);
      if (res.ok === true) {
        Haptics.success();
        Toast.ok(res.message !== undefined && res.message !== '' ? res.message : '已发送后台测试推送');
      } else {
        Haptics.warn();
        Toast.err(res.message !== undefined && res.message !== '' ? res.message : '后台测试推送未就绪');
      }
    } finally {
      this.testPushBusy = false;
    }
  }

  build() {
    Column() {
      // 0. 顶部系统权限状态卡
      Column() {
        Row({ space: 12 }) {
          CardIcon({
            symbol: $r('sys.symbol.bell_fill'),
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:perm', 0)
          })

          Column({ space: 3 }) {
            Row({ space: 8 }) {
              Text('系统通知权限')
                .fontSize(Tokens.fsBodyLg)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.fg)
              Text(this.allowed ? '已开启' : '未开启')
                .fontSize(Tokens.fsCaption)
                .fontColor(this.allowed ? Tokens.doneInk : Tokens.askInk)
                .backgroundColor(this.allowed ? Tokens.doneBg : Tokens.askBg)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            }
            Text(this.allowed ? '系统已放行应用横幅与通知栏推送' : '请授权通知权限以接收任务完成与待回答提醒')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .lineHeight(17)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.allowed ? '系统设置' : '去开启')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.allowed ? Tokens.fg : Tokens.accentInk)
            .backgroundColor(this.allowed ? Tokens.surface2 : Tokens.accent)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              void this.openSystemSettings();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rRow)
      .clip(true)
      .margin({ top: 6 })
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('notify:perm', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:perm', 0), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:perm', 0), this.motionMode)
        : null)

      Text('提醒偏好')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:pref', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:pref', 94), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:pref', 94), this.motionMode)
          : null)

      Column({ space: 9 }) {
        // 1. 回合结束提醒
        Column() {
          RowSwitch({
            title: '回合结束提醒',
            hint: '一轮回答完成或有提问待确认时发送本地通知',
            value: this.done,
            showIcon: true,
            iconSymbol: $r('sys.symbol.bell_fill'),
            iconTone: 'blue',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:done', 148),
            onChanged: (v: boolean) => {
              this.onDone(v);
            }
          })
        }
        .width('100%')
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:done', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:done', 148), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:done', 148), this.motionMode)
          : null)

        // 2. 仅在后台提醒
        Column() {
          RowSwitch({
            title: '仅在后台提醒',
            hint: this.done ? '开启时前台查看其他页面或会话不弹本地横幅，退后台后由系统推送接管' : '需先开启上方的「回合结束提醒」',
            value: this.bgOnly,
            switchEnabled: this.done,
            showIcon: true,
            iconSymbol: $r('sys.symbol.bell_slash_fill'),
            iconTone: 'violet',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:bgOnly', 228),
            onChanged: (v: boolean) => {
              this.onBgOnly(v);
            }
          })
        }
        .width('100%')
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:bgOnly', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:bgOnly', 228), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:bgOnly', 228), this.motionMode)
          : null)

        // 3. 推送显示会话标题
        Column() {
          RowSwitch({
            title: '推送显示会话标题',
            hint: this.done ? '关闭后后台系统推送仅提示通用消息，不经云端中继发送会话标题' : '需先开启上方的「回合结束提醒」',
            value: this.showTitle,
            switchEnabled: this.done,
            showIcon: true,
            iconSymbol: $r('sys.symbol.eye'),
            iconTone: 'amber',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:showTitle', 308),
            onChanged: (v: boolean) => {
              this.onShowTitle(v);
            }
          })
        }
        .width('100%')
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:showTitle', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:showTitle', 308), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:showTitle', 308), this.motionMode)
          : null)
      }
      .width('100%')

      Text('后台系统推送（Push Kit）')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:push', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:push', 386), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:push', 386), this.motionMode)
          : null)

      // 4. 华为系统推送通道（多行状态与操作复合卡）
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          CardIcon({
            symbol: $r('sys.symbol.cloud_fill'),
            tone: this.pushBadgeReady() ? 'green' : 'blue',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:push', 480)
          })
          Text('华为系统推送通道')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
          Text(this.pushBadgeText())
            .fontSize(Tokens.fsCaption)
            .fontColor(this.pushBadgeReady() ? Tokens.doneInk : Tokens.askInk)
            .backgroundColor(this.pushBadgeReady() ? Tokens.doneBg : Tokens.askBg)
            .borderRadius(Tokens.rPill)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          Blank()
        }
        .width('100%')

        Text(this.pushDetailText())
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(this.relayLoading ? '刷新中…' : '刷新状态')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .margin({ right: 8, top: 2 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              void this.refreshPushChannel(true);
            })

          Text(this.testPushBusy ? '发送中…' : '测试后台推送')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .margin({ right: 8, top: 2 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              void this.runTestPush();
            })

          if (this.pushState === 'ready') {
            Text(this.rotateBusy ? '重置中…' : '重置凭据')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.dim)
              .backgroundColor(Tokens.surface2)
              .borderRadius(Tokens.rPill)
              .padding({ left: 12, right: 12, top: 7, bottom: 7 })
              .margin({ top: 2 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                void this.runRotateBinding();
              })
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rCard)
      .alignItems(HorizontalAlign.Start)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('notify:push', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:push', 480), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:push', 480), this.motionMode)
        : null)

      Text('调试与未读')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:debug', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:debug', 598), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:debug', 598), this.motionMode)
          : null)

      Column({ space: 9 }) {
        // 5. 测试本地通知
        Row() {
          CardIcon({
            symbol: $r('sys.symbol.paperplane_fill'),
            tone: 'teal',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:test', 652)
          })
          .margin({ right: 12 })

          Column({ space: 2 }) {
            Text('测试本地通知')
              .fontSize(Tokens.fsBodyLg)
              .fontColor(Tokens.fg)
            Text('立即触发一条横幅通知验证通道是否畅通')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('发送测试')
            .fontSize(Tokens.fsFoot)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              void this.refreshPermission();
              void Notifier.done('测试通知', '能看到这条，说明这台手机的通知是通的', 990001);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:test', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:test', 652), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:test', 652), this.motionMode)
          : null)

        // 6. 清除未读与桌面角标
        Row() {
          CardIcon({
            symbol: $r('sys.symbol.xmark_circle_fill'),
            tone: 'danger',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('notify:unread', 730)
          })
          .margin({ right: 12 })

          Column() {
            Row() {
              Text('清除未读与桌面角标')
                .fontSize(Tokens.fsBodyLg)
                .fontColor(Tokens.fg)
              HintLabel({
                title: '',
                tipText: '同时清除会话列表未读蓝点、撤回系统通知栏消息，并将桌面图标角标数字归零。'
              })
              .margin({ left: 6 })
            }
            .alignItems(VerticalAlign.Center)

            Text(this.unreadSummaryText())
              .fontSize(Tokens.fsFoot)
              .fontColor(this.unreadCount > 0 ? Tokens.accent : Tokens.dim2)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text(this.unreadCount > 0 ? ('清除 (' + String(this.unreadCount) + ')') : '清除')
            .fontSize(Tokens.fsFoot)
            .fontColor(this.unreadCount > 0 ? Tokens.err : Tokens.dim2)
            .backgroundColor(this.unreadCount > 0 ? Tokens.intrBg : Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.clearUnread();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:unread', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('notify:unread', 730), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('notify:unread', 730), this.motionMode)
          : null)
      }
      .width('100%')

      Text('前台由应用轮询同步状态并在非当前会话时按偏好提醒；退后台或锁屏后，电脑网关通过 Push Kit 云端中继推送系统通知。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .margin({ top: 12, left: 4, right: 4 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('notify:foot', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('notify:foot', 804), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('notify:foot', 804), this.motionMode)
          : null)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
