import { Mat } from './Mat';
import { Motion, MOTION_VIVID } from './Motion';
import { Tokens } from './Tokens';

/**
 * 旗舰液态玻璃悬浮弹簧 Toast 宿主（挂载在 Index 顶层，透传全部触控事件）：
 * 仅在灵动档触发，带语义 SymbolGlyph 轻弹与非对称弹簧进出场。
 */
@Component
export struct GlassToastHost {
  @StorageLink('glassToastSeq') @Watch('onToastSeq') toastSeq: number = 0;
  @StorageLink('glassToastText') toastText: string = '';
  @StorageLink('glassToastKind') toastKind: string = 'info';
  @StorageLink('glassToastDur') toastDur: number = 1800;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private shown: boolean = false;
  @State private iconTick: number = 0;
  private hideTimer: number = -1;

  aboutToDisappear(): void {
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
  }

  private onToastSeq(): void {
    if (this.toastSeq <= 0 || this.toastText === '') {
      return;
    }
    if (this.hideTimer >= 0) {
      clearTimeout(this.hideTimer);
      this.hideTimer = -1;
    }
    this.iconTick += 1;
    this.shown = true;
    const dur: number = this.toastDur > 400 ? this.toastDur : 1800;
    this.hideTimer = setTimeout(() => {
      this.hideTimer = -1;
      this.shown = false;
    }, dur);
  }

  private glyphRes(): Resource {
    if (this.toastKind === 'ok') {
      return $r('sys.symbol.checkmark_circle_fill');
    }
    if (this.toastKind === 'err') {
      return $r('sys.symbol.exclamationmark_circle_fill');
    }
    return $r('sys.symbol.info_circle_fill');
  }

  private glyphColor(): string {
    if (this.toastKind === 'ok') {
      return Tokens.ok;
    }
    if (this.toastKind === 'err') {
      return Tokens.err;
    }
    return Tokens.accent;
  }

  build() {
    Column() {
      Blank()
      if (this.shown && this.toastText !== '') {
        Row({ space: 8 }) {
          SymbolGlyph(this.glyphRes())
            .fontSize(17)
            .fontColor([this.glyphColor()])
            .symbolEffect(Motion.bounceEffect(EffectDirection.UP), this.iconTick)

          Text(this.toastText)
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .constraintSize({ maxWidth: 320 })
        .padding({ left: 15, right: 17, top: 10, bottom: 10 })
        .borderRadius(Tokens.rPill)
        .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
        .backgroundEffect(Mat.glassEffect(this.hdsOn, true))
        .border(Mat.glassRimBorder(this.hdsOn))
        .shadow(Mat.glassFloatShadow(this.hdsOn))
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: this.bottomInset + 96 })
        .transition(
          TransitionEffect.asymmetric(
            TransitionEffect.OPACITY.animation({ duration: 160, curve: Motion.std })
              .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }).animation(Motion.flagshipSnappy()))
              .combine(TransitionEffect.translate({ y: 20 }).animation(Motion.flagshipSnappy())),
            TransitionEffect.OPACITY.animation({ duration: 150, curve: Motion.std })
              .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }).animation({ duration: 150, curve: Motion.std }))
              .combine(TransitionEffect.translate({ y: 12 }).animation({ duration: 150, curve: Motion.std }))
          )
        )
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }
}
