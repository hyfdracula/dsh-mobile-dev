import preferences from '@ohos.data.preferences';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK, ICON_LIGHT, IconSwitchResult } from '../common/AppIcon';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Motion, MOTION_CLASSIC, MOTION_VIVID } from '../common/Motion';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel, RowSwitch } from '../common/Widgets';

const PREF_STORE: string = 'dsh_mobile_cfg';

interface MotionOpt {
  id: string;
  name: string;
}

const MOTIONS: MotionOpt[] = [
  { id: MOTION_VIVID, name: '灵动' },
  { id: MOTION_CLASSIC, name: '经典' }
];

interface ThemeOpt {
  id: string;
  name: string;
}

const THEMES: ThemeOpt[] = [
  { id: 'dark', name: '深色' },
  { id: 'light', name: '浅色' },
  { id: 'auto', name: '跟随系统' }
];

interface ScaleOpt {
  val: number;
  name: string;
}

const SCALES: ScaleOpt[] = [
  { val: 0.92, name: '小' },
  { val: 1, name: '标准' },
  { val: 1.08, name: '大' }
];

/**
 * 「外观与交互」面板：
 * 拆分为「外观显示」与「对话与交互」两张语义分组卡片，全标题统一使用 Tokens.fg + Tokens.fsBodyLg。
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
  @State private iconBusy: boolean = false;

  private async applyMotion(target: string): Promise<void> {
    const norm: string = Motion.normalize(target);
    if (this.motionMode === norm) {
      return;
    }
    Haptics.tap();
    AppStorage.setOrCreate('motionMode', norm);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('motionMode', norm);
      await p.flush();
    } catch (_e) {
    }
    Toast.ok(norm === MOTION_VIVID ? '已切换为灵动动效' : '已切换为经典动效');
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
        Text(this.appIconStyle === styleId ? tag + ' · 使用中' : tag)
          .fontSize(Tokens.fsCaption)
          .fontColor(this.appIconStyle === styleId ? Tokens.accent : Tokens.dim2)
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
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
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
          Row() {
            ForEach(THEMES, (o: ThemeOpt) => {
              Text(o.name)
                .fontSize(Tokens.fsFoot)
                .fontColor(this.themeMode === o.id ? Tokens.accentInk : Tokens.dim)
                .backgroundColor(this.themeMode === o.id ? Tokens.accent : Tokens.surface2)
                .borderRadius(Tokens.rPill)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .margin({ left: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  if (this.themeMode === o.id) {
                    return;
                  }
                  Haptics.tap();
                  this.onTheme(o.id);
                })
            }, (o: ThemeOpt) => o.id)
          }
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
              '灵动：启用鸿蒙原生弹簧物理曲线、首屏错峰入场与数字翻滚；经典：保留简洁干脆的经典贝塞尔动画。'
            )
            Text(Motion.isVivid(this.motionMode) ? '当前：灵动（弹簧 · 错峰 · 翻滚）' : '当前：经典（简洁贝塞尔动效）')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Row() {
            ForEach(MOTIONS, (mo: MotionOpt) => {
              Text(mo.name)
                .fontSize(Tokens.fsFoot)
                .fontColor(this.motionMode === mo.id ? Tokens.accentInk : Tokens.dim)
                .backgroundColor(this.motionMode === mo.id ? Tokens.accent : Tokens.surface2)
                .borderRadius(Tokens.rPill)
                .padding({ left: 13, right: 13, top: 6, bottom: 6 })
                .margin({ left: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  void this.applyMotion(mo.id);
                })
            }, (mo: MotionOpt) => mo.id)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

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

          Row() {
            ForEach(SCALES, (sc: ScaleOpt) => {
              Text(sc.name)
                .fontSize(Tokens.fsFoot)
                .fontColor(this.textScale === sc.val ? Tokens.accentInk : Tokens.dim)
                .backgroundColor(this.textScale === sc.val ? Tokens.accent : Tokens.surface2)
                .borderRadius(Tokens.rPill)
                .padding({ left: 11, right: 11, top: 6, bottom: 6 })
                .margin({ left: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
                .onClick(() => {
                  if (this.textScale === sc.val) {
                    return;
                  }
                  Haptics.tap();
                  this.onTextScale(sc.val);
                })
            }, (sc: ScaleOpt) => String(sc.val))
          }
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
            this.labelWithHint('触感反馈', '点击、归档、发送时提供轻巧短振动反馈。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          Toggle({ type: ToggleType.Switch, isOn: this.haptics })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onHaptics(v);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        Divider().color(Tokens.lineSoft).margin({ left: 16 })

        Row() {
          Row() {
            this.labelWithHint('回车发送', '关掉后回车只换行，用右侧发送按钮发出；适合经常输入多行指令。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          Toggle({ type: ToggleType.Switch, isOn: this.enterSend })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              this.onEnterSend(v);
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
            this.onCompactHistory(v);
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
