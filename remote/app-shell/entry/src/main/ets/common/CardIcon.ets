import { Motion, MOTION_VIVID } from './Motion';
import { Tokens } from './Tokens';

/**
 * 卡片语义图标徽标：
 * - 为每个重要卡片提供高辨识度的深浅双色语义底色 + 矢量图标，打破卡片同质化；
 * - 在「灵动」动效档下，与宿主卡片的空间距离绽放同步联动：滞后 34ms 从左下角旋转（-86° -> 0°）
 *   并伴随弹性放大飞入就位，形成「卡片长大、图标旋转飞入」的层次感。
 */
@Component
export struct CardIcon {
  symbol: Resource = $r('sys.symbol.info_circle');
  imageRes: Resource = $r('app.media.ic_pc');
  @Prop useImage: boolean = false;
  @Prop tone: string = 'blue';
  @Prop badgeSize: number = 34;
  @Prop glyphSize: number = 17;
  @Prop entered: boolean = true;
  @Prop distanceVp: number = 0;
  @Prop baseDelay: number = 16;

  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private fgColor(): string {
    if (this.tone === 'green') {
      return this.themeDark ? '#3DDC97' : '#0F9D63';
    }
    if (this.tone === 'amber') {
      return this.themeDark ? '#F5B747' : '#D97706';
    }
    if (this.tone === 'violet') {
      return this.themeDark ? '#A78BFA' : '#7C5CFF';
    }
    if (this.tone === 'danger') {
      return this.themeDark ? '#FF6B6B' : '#DC3545';
    }
    if (this.tone === 'teal') {
      return this.themeDark ? '#38BDF8' : '#0891B2';
    }
    if (this.tone === 'neutral') {
      return Tokens.dim;
    }
    return this.themeDark ? '#78A2FF' : '#2F6BFF';
  }

  private bgColor(): string {
    if (this.tone === 'green') {
      return this.themeDark ? '#263DDC97' : '#160F9D63';
    }
    if (this.tone === 'amber') {
      return this.themeDark ? '#26F5B747' : '#18D97706';
    }
    if (this.tone === 'violet') {
      return this.themeDark ? '#26A78BFA' : '#167C5CFF';
    }
    if (this.tone === 'danger') {
      return this.themeDark ? '#26FF5C5C' : '#16DC3545';
    }
    if (this.tone === 'teal') {
      return this.themeDark ? '#2638BDF8' : '#160891B2';
    }
    if (this.tone === 'neutral') {
      return this.themeDark ? '#249AA3B2' : '#145B6474';
    }
    return this.themeDark ? '#265B8CFF' : '#162F6BFF';
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.useImage) {
        Image(this.imageRes)
          .width(this.glyphSize)
          .height(this.glyphSize)
          .fillColor(this.fgColor())
          .objectFit(ImageFit.Contain)
      } else {
        SymbolGlyph(this.symbol)
          .fontSize(this.glyphSize)
          .fontColor([this.fgColor()])
      }
    }
    .width(this.badgeSize)
    .height(this.badgeSize)
    .borderRadius(Math.round(this.badgeSize * 0.30))
    .backgroundColor(this.bgColor())
    .flexShrink(0)
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.iconFlyOpacityAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
    .translate({
      x: this.entered ? 0 : Motion.ICON_FLY_OFFSET_X,
      y: this.entered ? 0 : Motion.ICON_FLY_OFFSET_Y
    })
    .animation(this.entered
      ? Motion.iconFlyTransformAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
      y: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.iconFlyTransformAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
    .rotate({
      angle: this.entered ? 0 : Motion.ICON_FLY_ROTATE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.iconFlyTransformAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
  }
}
