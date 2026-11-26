import notificationManager from '@ohos.notificationManager';
import { Want } from '@kit.AbilityKit';
import { AppCtx } from '../common/AppCtx';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Notifier } from '../common/Notifier';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { Unread } from '../common/Unread';
import { HintLabel, RowSwitch } from '../common/Widgets';

/**
 * 「通知」面板：
 * 顶部展示系统通知权限卡片，紧随提醒偏好（主开关关闭时禁用仅后台提醒）与测试/未读清理操作。
 */
@Component
export struct NotifyPanel {
  @Prop done: boolean = true;
  @Prop bgOnly: boolean = true;
  onDone: (v: boolean) => void = () => {};
  onBgOnly: (v: boolean) => void = () => {};
  onClearUnread?: () => void;

  @State private allowed: boolean = false;
  @StorageLink('notifyProbe') @Watch('onNotifyProbe') notifyProbe: number = 0;
  @StorageLink('unreadCount') unreadCount: number = 0;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  private pollTimer: number = -1;

  aboutToAppear(): void {
    Unread.count();
    void this.refreshPermission();
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
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

  build() {
    Column() {
      // 1. 顶部系统权限状态卡
      Column() {
        Row({ space: 10 }) {
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
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .margin({ top: 6 })
      .transition(Motion.bloomCard(0, this.motionMode))

      Text('提醒偏好')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        RowSwitch({
          title: '回合结束提醒',
          hint: '一轮回答完成或有提问待确认时发送本地通知',
          value: this.done,
          onChanged: (v: boolean) => {
            this.onDone(v);
          }
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        RowSwitch({
          title: '仅在后台提醒',
          hint: this.done ? '在前台查看对话时不打扰，切换后台后推送通知' : '需先开启上方的「回合结束提醒」',
          value: this.bgOnly,
          switchEnabled: this.done,
          onChanged: (v: boolean) => {
            this.onBgOnly(v);
          }
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(1, this.motionMode))

      Text('调试与未读')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        Row() {
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

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
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
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(2, this.motionMode))

      Text('应用在前台及切回前台时会自动巡检会话变化，并将结果同步至未读角标与系统通知栏。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .margin({ top: 12, left: 4, right: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
