import {
  BlurStrategy,
  HdsNavigationBackgroundStyle,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleBarStyle,
  ScrollEffectOptions,
  TitleBarContentOptions,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';
import { Tokens } from './Tokens';
import { Haptics } from './Haptics';
import { Mat } from './Mat';

/**
 * 统一页面头部、透明 HDS 顶栏与顶部渐隐。
 */
@Component
export struct GlassIconButton {
  icon: Resource = $r('app.media.ic_back');
  glyph: string = '';
  label: string = '';
  btnSize: number = 46;
  /** 仅当所在容器为 HdsNavigation / HdsNavDestination 的 titleBar 时传 true 以启用系统沉浸光感 */
  @Prop immersive: boolean = false;
  onTap: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private useImmersive(): boolean {
    return this.immersive && this.hdsOn && Mat.isImmersiveReady();
  }

  build() {
    Stack() {
      if (this.glyph !== '') {
        Text(this.glyph)
          .fontSize(20)
          .fontColor(Tokens.fg)
      } else {
        Image(this.icon)
          .width(this.label === '返回' ? 21 : 20)
          .height(this.label === '返回' ? 21 : 20)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
      }
    }
    .width(this.btnSize)
    .height(this.btnSize)
    .borderRadius(Tokens.rPill)
    .backgroundColor(!this.hdsOn ? Tokens.surface : (this.useImmersive() ? Color.Transparent : Tokens.glassStrong))
    .backdropBlur(this.hdsOn && !this.useImmersive() ? 18 : 0)
    .systemMaterial(this.hdsOn ? Mat.whiteOn(this.useImmersive()) : Mat.empty())
    .border({
      width: 1,
      color: !this.hdsOn ? Tokens.line : (this.useImmersive() ? Tokens.glassLine : Tokens.pillEdge)
    })
    .shadow(!this.hdsOn || this.useImmersive()
      ? { radius: 0, color: Color.Transparent }
      : { radius: 12, color: Tokens.accentGlow, offsetY: 2 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .accessibilityText(this.label)
    .onClick(() => {
      if (this.label === '返回') {
        Haptics.soft();
      } else {
        Haptics.tap();
      }
      this.onTap();
    })
  }
}

/** 右侧槽位：不显示 / 图标 / 字符（如 ↻）/ 文字（如「刷新」）。 */
@Component
export struct PageHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop hasBack: boolean = true;
  /** 为 true 时自动加上状态栏安全区内边距，供全屏独立页直接使用；默认 false 避免双倍叠加 */
  padTop: boolean = false;
  /** 位于 HDS titleBar 中时传 true，按钮随全局沉浸光感开关切换 */
  @Prop immersive: boolean = false;
  @StorageLink('topInset') topInset: number = 44;
  @StorageLink('themeDark') themeDark: boolean = true;
  /** none | glyph | icon | label */
  rightKind: string = 'none';
  rightGlyph: string = '\u21bb';
  rightIcon: Resource = $r('app.media.ic_scan');
  @Prop rightLabel: string = '';
  /** 第二个右侧圆钮（聊天页的「任务」与「更多」） */
  hasRight2: boolean = false;
  rightIcon2: Resource = $r('app.media.ic_group');
  onBack: () => void = () => {};
  onRight: () => void = () => {};
  onRight2: () => void = () => {};

  build() {
    Row() {
      if (this.hasBack) {
        GlassIconButton({
          icon: $r('app.media.ic_back'),
          label: '返回',
          immersive: this.immersive,
          onTap: () => {
            this.onBack();
          }
        })
      }
      Column() {
        Text(this.title)
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 1 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: this.hasBack ? 12 : 0 })
      if (this.rightKind === 'glyph') {
        GlassIconButton({
          glyph: this.rightGlyph,
          label: '刷新',
          immersive: this.immersive,
          onTap: () => {
            this.onRight();
          }
        })
      } else if (this.rightKind === 'icon') {
        GlassIconButton({
          icon: this.rightIcon,
          label: '更多',
          immersive: this.immersive,
          onTap: () => {
            this.onRight();
          }
        })
      } else if (this.rightKind === 'label') {
        Text(this.rightLabel)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accentSoft)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onRight();
          })
      }
      if (this.hasRight2) {
        GlassIconButton({
          icon: this.rightIcon2,
          label: '更多',
          immersive: this.immersive,
          onTap: () => {
            this.onRight2();
          }
        })
        .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(this.padTop ? 56 + this.topInset : 56)
    .padding({ top: this.padTop ? this.topInset : 0 })
    .alignItems(VerticalAlign.Center)
  }
}

/** 顶部同色渐隐：滚上来的内容在浮动标题下淡出，静止态下方卡片首行文字清晰不发雾。 */
@Component
export struct TopFade {
  fadeHeight: number = 80;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;

  private transparentStop(): string {
    const raw: string = this.themeBg.startsWith('#') ? this.themeBg.slice(1) : this.themeBg;
    const rgb: string = raw.length === 8 ? raw.slice(2) : raw;
    return '#00' + rgb;
  }

  build() {
    Row()
      .width('100%')
      .height(this.fadeHeight)
      .linearGradient({
        angle: 180,
        colors: [[this.themeBg, 0.0], [this.themeBg, 0.42], [this.transparentStop(), 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 构建无整条底板、无滚动灰罩的透明 HDS 标题栏配置，收口列表页与聊天页的重复样板代码。
 */
export function buildTransparentHdsTitle(stack: CustomBuilder): HdsNavigationTitleBarOptions {
  const content: TitleBarContentOptions = { stackBuilder: stack };
  const style: TitleBarStyleOptions = {};
  const bgStyle: HdsNavigationBackgroundStyle = {};
  bgStyle.backgroundColor = Color.Transparent;
  bgStyle.blurRadius = 0;
  bgStyle.maskExtraHeight = 0;
  const origStyle: HdsNavigationTitleBarStyle = {};
  origStyle.backgroundStyle = bgStyle;
  style.originalStyle = origStyle;
  style.blurStrategy = BlurStrategy.DISABLE;
  const eff: ScrollEffectOptions = {};
  eff.enableScrollEffect = false;
  style.scrollEffectOpts = eff;
  style.scrollEffectStyle = origStyle;
  const opts: HdsNavigationTitleBarOptions = { content: content, style: style };
  return opts;
}
