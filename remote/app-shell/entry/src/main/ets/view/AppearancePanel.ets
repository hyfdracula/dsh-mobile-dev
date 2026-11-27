import preferences from '@ohos.data.preferences';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK, ICON_LIGHT, IconSwitchResult } from '../common/AppIcon';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_CLASSIC, MOTION_VIVID } from '../common/Motion';
import { PickerOption, PopupPicker } from '../common/PopupPicker';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel, RowSwitch } from '../common/Widgets';

const PREF_STORE: string = 'dsh_mobile_cfg';

const MOTION_OPTIONS: PickerOption[] = [
  { id: MOTION_VIVID, label: '灵动', sub: '水平视差推拉 · 逐卡绽放 · 景深阅读卡' },
  { id: MOTION_CLASSIC, label: '经典', sub: '弹簧、流光、一镜到底与图标形变' }
];

const THEME_OPTIONS: PickerOption[] = [
  { id: 'dark', label: '深色' },
  { id: 'light', label: '浅色' },
  { id: 'auto', label: '跟随系统' }
];

const SCALE_OPTIONS: PickerOption[] = [
  { id: '0.92', label: '小', sub: '更紧凑的对话阅读密度' },
  { id: '1', label: '标准', sub: '默认均衡排版尺寸' },
  { id: '1.08', label: '大', sub: '更易阅读的放大字号' }
];

/**
 * 「外观与交互」面板：
 * 拆分为「外观显示」与「对话与交互」两大区域下的独立单条卡片，逐条错峰绽放。
 * 全部多选项统一使用 64-65 秒同款锚点弹出选择卡（PopupPicker），并移除三档动画速度调节。
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
  @State private entered: boolean = true;
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
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

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
    this.getUIContext().animateTo(Motion.flagshipSpring(), () => {
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

  private async applyIcon(target: string): Promise<void> {
    if (this.iconBusy || this.appIconStyle === target) {
      return;
    }
    Haptics.confirm();
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
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
    .onClick(() => {
      void this.applyIcon(styleId);
    })
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
      // 分组 1：外观显示（逐条独立卡片）
      this.sectionTitle('外观显示', 6, 'hdr:display', 0)
      Column({ space: 9 }) {
        // 0. 主题
        Row() {
          Text('主题')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
            .layoutWeight(1)
          PopupPicker({
            options: THEME_OPTIONS,
            selected: this.themeMode,
            title: '选择主题',
            popupWidth: 204,
            onSelect: (id: string) => {
              this.onTheme(id);
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
          this.wave.record('card:theme', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:theme', 52), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:theme', 52), this.motionMode)
          : null)

        // 1. 沉浸光感
        Row() {
          Column() {
            this.labelWithHint(
              '沉浸光感',
              '开启（液态玻璃皮肤）：输入框、阅读卡片、弹出菜单、添加对话按钮与排队抽屉呈现液态玻璃光感；关闭（经典实色皮肤）：切换为零模糊高对比实色表面与纯色按钮。'
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
                Haptics.toggle(v);
                this.onHds(v);
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
          this.wave.record('card:hds', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:hds', 124), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:hds', 124), this.motionMode)
          : null)

        // 2. 交互动效
        Row() {
          Column() {
            this.labelWithHint(
              '交互动效',
              '灵动：在经典全部动效之上，解锁全屏水平视差推拉、页内逐卡景深绽放、锚点悬浮下拉卡与液态玻璃 Toast；经典：保留原生弹簧、AI 双边流光、一镜到底、数字翻滚与图标形变。'
            )
            Text(Motion.isFlagship(this.motionMode)
              ? '当前：灵动（视差推拉 · 逐卡绽放）'
              : '当前：经典（弹簧 · 流光 · 形变）')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .margin({ top: 3 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          PopupPicker({
            options: MOTION_OPTIONS,
            selected: this.motionMode,
            title: '交互动效',
            popupWidth: 248,
            onSelect: (id: string) => {
              void this.applyMotion(id);
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
          this.wave.record('card:motion', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:motion', 204), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:motion', 204), this.motionMode)
          : null)

        // 3. 应用图标（语义整体单卡）
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
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rCard)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('card:icon', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:icon', 310), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:icon', 310), this.motionMode)
          : null)

        // 4. 正文字号
        Row() {
          Row() {
            this.labelWithHint('正文字号', '只缩放聊天消息正文，界面按钮与标题尺寸保持稳定。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          PopupPicker({
            options: SCALE_OPTIONS,
            selected: this.scaleIdOf(this.textScale),
            title: '正文字号',
            popupWidth: 216,
            onSelect: (id: string) => {
              const v: number = Number(id);
              if (!Number.isNaN(v) && v > 0) {
                this.onTextScale(v);
              }
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
          this.wave.record('card:scale', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:scale', 438), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:scale', 438), this.motionMode)
          : null)
      }
      .width('100%')

      // 分组 2：对话与交互（逐条独立卡片）
      this.sectionTitle('对话与交互', 16, 'hdr:interact', 512)
      Column({ space: 9 }) {
        // 5. 触感反馈
        Row() {
          Row() {
            this.labelWithHint('触感反馈', '按场景区分轻触、开关、成功、警告与错误等细腻震动纹理。')
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Toggle({ type: ToggleType.Switch, isOn: this.haptics })
            .selectedColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onChange((v: boolean) => {
              if (v !== this.haptics) {
                if (!v) {
                  Haptics.toggle(false);
                }
                this.onHaptics(v);
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
          this.wave.record('card:haptics', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:haptics', 556), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:haptics', 556), this.motionMode)
          : null)

        // 6. 回车发送
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
                Haptics.toggle(v);
                this.onEnterSend(v);
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
          this.wave.record('card:enter', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:enter', 624), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:enter', 624), this.motionMode)
          : null)

        // 7. 会话精简加载
        Column() {
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
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('card:compact', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:compact', 700), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:compact', 700), this.motionMode)
          : null)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
