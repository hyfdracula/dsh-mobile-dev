import preferences from '@ohos.data.preferences';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK, ICON_LIGHT, IconSwitchResult } from '../common/AppIcon';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import {
  Motion,
  MOTION_CLASSIC,
  MOTION_VIVID,
  SPEED_FAST,
  SPEED_GENTLE,
  SPEED_NORMAL
} from '../common/Motion';
import { SegmentOption, SlidingSegment } from '../common/SlidingSegment';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel, RowSwitch } from '../common/Widgets';

const PREF_STORE: string = 'dsh_mobile_cfg';

const MOTION_OPTIONS: SegmentOption[] = [
  { id: MOTION_VIVID, label: '灵动' },
  { id: MOTION_CLASSIC, label: '经典' }
];

const SPEED_OPTIONS: SegmentOption[] = [
  { id: SPEED_FAST, label: '偏快' },
  { id: SPEED_NORMAL, label: '正常' },
  { id: SPEED_GENTLE, label: '柔和' }
];

const THEME_OPTIONS: SegmentOption[] = [
  { id: 'dark', label: '深色' },
  { id: 'light', label: '浅色' },
  { id: 'auto', label: '跟随系统' }
];

const SCALE_OPTIONS: SegmentOption[] = [
  { id: '0.92', label: '小' },
  { id: '1', label: '标准' },
  { id: '1.08', label: '大' }
];

/**
 * 「外观与交互」面板：
 * 拆分为「外观显示」与「对话与交互」两张语义分组卡片，全标题统一使用 Tokens.fg + Tokens.fsBodyLg。
 * 灵动档下全部选项组采用 SlidingSegment 实体弹性滑块，并展开三档动画速度细调。
 */
@Component
export struct AppearancePanel {
  @Prop themeMode: string = 'auto';
  @Prop haptics: boolean = true;
  @Prop hds: boolean = true;
  @Prop enterSend: boolean = true;
  @Prop textScale: number = 1;
  @Prop compactHistory: boolean = false;

  onTheme: (m: string) => void = () => {};
  onHaptics: (v: boolean) => void = () => {};
  onHds: (v: boolean) => void = () => {};
  onEnterSend: (v: boolean) => void = () => {};
  onTextScale: (v: number) => void = () => {};
  onCompactHistory: (v: boolean) => void = () => {};

  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('motionSpeed') motionSpeed: string = SPEED_NORMAL;
  @State private iconBusy: boolean = false;
  @State private iconPressId: string = '';

  private scaleIdOf(val: number): string {
    if (val < 0.96) {
      return '0.92';
    }
    if (val > 1.04) {
      return '1.08';
    }
    return '1';
  }

  private async applyMotion(target: string): Promise<void> {
    const norm: string = Motion.normalize(target);
    if (this.motionMode === norm) {
      return;
    }
    this.getUIContext().animateTo(Motion.flagshipSpring(this.motionSpeed), () => {
      AppStorage.setOrCreate('motionMode', norm);
    });
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('motionMode', norm);
      await p.flush();
    } catch (_e) {
    }
    Toast.ok(norm === MOTION_VIVID ? '已切换为灵动空间动效' : '已切换为经典动效');
  }

  private async applySpeed(target: string): Promise<void> {
    const norm: string = Motion.normalizeSpeed(target);
    if (this.motionSpeed === norm) {
      return;
    }
    AppStorage.setOrCreate('motionSpeed', norm);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('motionSpeed', norm);
      await p.flush();
    } catch (_e) {
    }
    const label: string = norm === SPEED_FAST ? '偏快' : (norm === SPEED_GENTLE ? '柔和' : '正常');
    Toast.ok('动画速度已切换为' + label);
  }

  private async applyIcon(target: string): Promise<void> {
    if (this.iconBusy || this.appIconStyle === target) {
      return;
    }
    Haptics.tap();
    this.iconBusy = true;
    try {
      const res: IconSwitchResult = await AppIcon.switchTo(target);
      if (res.desktopApplied) {
        Toast.ok(target === ICON_LIGHT ? '已切换为冷银瓷白图标' : '已切换为纯粹曜黑默认图标');
      } else {
        Toast.info('应用内图标已切换；桌面图标切换受系统限制（' + String(res.errCode) + '）');
      }
    } finally {
      this.iconBusy = false;
    }
  }

  @Builder
  private iconOptionCard(styleId: string, label: string, tag: string, imgRes: Resource) {
    Row({ space: 10 }) {
      Image(imgRes)
        .width(38)
        .height(38)
        .borderRadius(10)
        .border({ width: 0.5, color: Tokens.line })

      Column({ space: 2 }) {
        Text(label)
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
        Text(this.appIconStyle === styleId ? '使用中' : tag)
          .fontSize(Tokens.fsCaption)
          .fontColor(this.appIconStyle === styleId ? Tokens.accent : Tokens.dim2)
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .layoutWeight(1)
    .padding({ left: 11, right: 11, top: 10, bottom: 10 })
    .borderRadius(Tokens.rMd)
    .backgroundColor(this.appIconStyle === styleId ? Tokens.accentSoft : Mat.subCardBg(this.hdsOn))
    .border(this.appIconStyle === styleId
      ? { width: 1.5, color: Tokens.accent }
      : Mat.subCardBorder(this.hdsOn))
    .opacity(this.iconBusy ? 0.65 : 1)
    .scale({
      x: this.iconPressId === styleId ? 0.95 : 1,
      y: this.iconPressId === styleId ? 0.95 : 1
    })
    .animation(Motion.isFlagship(this.motionMode)
      ? Motion.flagshipSnappy(this.motionSpeed)
      : Motion.fadeOpts(this.motionMode))
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.iconPressId = styleId;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.iconPressId === styleId) {
          this.iconPressId = '';
        }
      }
    })
    .onClick(() => {
      void this.applyIcon(styleId);
    })
  }

  @Builder
  sectionTitle(text: string, topMargin: number) {
    Text(text)
      .fontSize(Tokens.fsCaption)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.4)
      .margin({ left: 6, top: topMargin, bottom: 8 })
  }

  @Builder
  labelWithHint(title: string, tip: string) {
    Row() {
      Text(title)
        .fontSize(Tokens.fsBodyLg)
        .fontColor(Tokens.fg)
      HintLabel({
        title: '',
        tipText: tip
      })
      .margin({ left: 6 })
    }
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // 分组 1：外观显示
      this.sectionTitle('外观显示', 6)
      Column() {
        Row() {
          Text('主题')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          SlidingSegment({
            options: THEME_OPTIONS,
            selected: this.themeMode,
            compact: true,
            onSelect: (id: string) => {
              this.onTheme(id);
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Column() {
            this.labelWithHint(
              '沉浸光感',
              '开启（液态玻璃皮肤）：输入框、模型卡片、统计面板、弹出菜单、添加对话按钮与排队抽屉呈现液态玻璃光感；关闭（经典实色皮肤）：切换为零模糊高对比实色表面与纯色按钮。'
            )
            Text(this.hdsOn ? '当前：液态玻璃皮肤（悬浮通透光感）' : '当前：经典实色皮肤（零模糊高对比）')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Toggle({ type: ToggleType.Switch, isOn: this.hdsOn })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              if (v !== this.hdsOn) {
                this.onHds(v);
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Column() {
            this.labelWithHint(
              '交互动效',
              '灵动：在经典全部动效之上，解锁设置页景深虚化缩退、悬浮可拖拽半模态卡片栈、栈内左右视差推拉、实体分段弹性滑块与液态玻璃 Toast；经典：保留原生弹簧、AI 双边流光、一镜到底、数字翻滚与图标形变。'
            )
            Text(Motion.isFlagship(this.motionMode)
              ? '当前：灵动（景深虚化 · 弹性滑块）'
              : '当前：经典（弹簧 · 流光 · 形变）')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          SlidingSegment({
            options: MOTION_OPTIONS,
            selected: this.motionMode,
            compact: true,
            onSelect: (id: string) => {
              void this.applyMotion(id);
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        if (Motion.isFlagship(this.motionMode)) {
          Column() {
            Divider().color(Tokens.lineSoft).margin({ left: 16 })
            Row() {
              Column() {
                Text('动画速度')
                  .fontSize(Tokens.fsBodyLg)
                  .fontColor(Tokens.fg)
                Text('调节弹簧与景深转场节奏')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SlidingSegment({
                options: SPEED_OPTIONS,
                selected: this.motionSpeed,
                compact: true,
                onSelect: (id: string) => {
                  void this.applySpeed(id);
                }
              })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .transition(Motion.panelTransition(this.motionMode))
        }

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Column({ space: 10 }) {
          Row() {
            Column() {
              this.labelWithHint(
                '应用图标',
                '在纯粹曜黑（默认）与冷银瓷白两套鸿蒙分层图标之间切换，同步更新桌面图标与应用内标识。'
              )
              Text(this.appIconStyle === ICON_LIGHT ? '当前：冷银瓷白（浅色饱满版）' : '当前：纯粹曜黑（默认饱满版）')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
                .margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Row({ space: 10 }) {
            this.iconOptionCard(ICON_DARK, '纯粹曜黑', '默认', $r('app.media.app_icon_dark'))
            this.iconOptionCard(ICON_LIGHT, '冷银瓷白', '浅色', $r('app.media.app_icon'))
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 13 })
        .alignItems(HorizontalAlign.Start)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Row() {
            this.labelWithHint('正文字号', '只缩放聊天消息正文，界面按钮与标题尺寸保持稳定。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          SlidingSegment({
            options: SCALE_OPTIONS,
            selected: this.scaleIdOf(this.textScale),
            compact: true,
            onSelect: (id: string) => {
              const v: number = Number(id);
              if (!Number.isNaN(v) && v > 0) {
                this.onTextScale(v);
              }
            }
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

      // 分组 2：对话与交互
      this.sectionTitle('对话与交互', 18)
      Column() {
        Row() {
          Row() {
            this.labelWithHint('触感反馈', '点击与滑动操作时提供细腻震动提示。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Toggle({ type: ToggleType.Switch, isOn: this.haptics })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              if (v !== this.haptics) {
                this.onHaptics(v);
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Row() {
            this.labelWithHint('回车发送', '按键盘回车键直接发送消息；关闭后回车换行，需点发送按钮。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Toggle({ type: ToggleType.Switch, isOn: this.enterSend })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              if (v !== this.enterSend) {
                this.onEnterSend(v);
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        RowSwitch({
          title: '会话精简加载',
          hint: '默认折叠长工具输出以加快大历史加载，重进会话生效',
          value: this.compactHistory,
          onChanged: (v: boolean) => {
            if (v !== this.compactHistory) {
              this.onCompactHistory(v);
            }
          }
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
