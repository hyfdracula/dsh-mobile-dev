import { AppIcon, ICON_DARK } from '../common/AppIcon';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Tokens } from '../common/Tokens';

/**
 * 「正在回复」的平滑相位呼吸圆点气泡（M1 / M4）。
 *
 * 父级仅在 running === true 时推进 active（0/1/2），停止生成后立即清零定时器；
 * 三颗圆点按相位差联动透明度、缩放与轻微起伏，使用统一 Motion 曲线过渡。
 */
@Component
export struct TypingBubble {
  /** 当前主相位的点下标（0/1/2），由父级在运行态推进。 */
  @Prop active: number = 0;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private dotOpacity(i: number): number {
    if (this.active === i) {
      return 1.0;
    }
    if ((this.active + 2) % 3 === i) {
      return 0.56;
    }
    return 0.24;
  }

  private dotScale(i: number): number {
    if (this.active === i) {
      return 1.22;
    }
    if ((this.active + 2) % 3 === i) {
      return 1.02;
    }
    return 0.86;
  }

  private dotOffsetY(i: number): number {
    return this.active === i ? -2.5 : 0;
  }

  @Builder
  private phaseDot(i: number) {
    Circle()
      .width(6)
      .height(6)
      .fill(Tokens.accent)
      .opacity(this.dotOpacity(i))
      .scale({ x: this.dotScale(i), y: this.dotScale(i) })
      .translate({ y: this.dotOffsetY(i) })
      .animation(Motion.moveOpts(this.motionMode))
  }

  build() {
    Column() {
      Row() {
        Image(AppIcon.res(this.appIconStyle))
          .width(20)
          .height(20)
          .borderRadius(Tokens.rXs)
          .border({ width: 0.5, color: Tokens.line })
          .objectFit(ImageFit.Cover)
      }
      .width('100%')
      .margin({ bottom: 6 })

      Row({ space: 6 }) {
        this.phaseDot(0)
        this.phaseDot(1)
        this.phaseDot(2)
      }
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .backgroundColor(Tokens.surface)
      .borderRadius(Tokens.rCard)
      .border({ width: 1, color: Tokens.lineSoft })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 20 })
  }
}
