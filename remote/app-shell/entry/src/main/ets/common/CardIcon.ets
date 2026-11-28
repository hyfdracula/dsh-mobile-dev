import { Motion, MOTION_VIVID } from './Motion';

/**
 * 卡片纯蓝无底色语义图标：
 * - 统一采用品牌蓝前景色、零背景块，保持清爽利落的原生视觉节奏；
 * - 在「灵动」动效档下，与宿主卡片的空间距离绽放同步联动：滞后卡片绽放 78ms，
 *   于槽位中心由 0x 弹性放大至 1x，同时完成 +180° -> 0° 丝滑旋正归位（无横向偏移）。
 */
@Component
export struct CardIcon {
  symbol: Resource = $r('sys.symbol.info_circle');
  imageRes: Resource = $r('app.media.ic_pc');
  @Prop useImage: boolean = false;
  @Prop tone: string = 'blue';
  @Prop badgeSize: number = 24;
  @Prop glyphSize: number = 22;
  @Prop entered: boolean = true;
  @Prop distanceVp: number = 0;
  @Prop baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY;

  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private fgColor(): string {
    return this.themeDark ? '#5B8CFF' : '#2F6BFF';
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
    .flexShrink(0)
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.iconFlyOpacityAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
      y: this.entered ? 1 : Motion.ICON_FLY_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.iconFlyScaleAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
    .rotate({
      angle: this.entered ? 0 : Motion.ICON_FLY_ROTATE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.iconFlyRotateAnimByDist(this.distanceVp, this.motionMode, this.baseDelay)
      : null)
  }
}
