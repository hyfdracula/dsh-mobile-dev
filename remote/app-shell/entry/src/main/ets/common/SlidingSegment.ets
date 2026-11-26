import { Haptics } from './Haptics';
import { Motion, MOTION_VIVID } from './Motion';
import { Tokens } from './Tokens';

export interface SegmentOption {
  id: string;
  label: string;
}

interface SegBox {
  x: number;
  w: number;
  h: number;
}

/**
 * 旗舰实体分段弹性滑块（SlidingSegment）：
 * - 灵动档：凹槽轨道 + 一枚真实独立的高亮实体胶囊滑块，切换选项时按实测宽度与横坐标
 *   通过 springMotion 弹性滑移并自适应伸展/收缩，快速连续点击自动继承瞬时速度；
 * - 经典档：回退为简洁独立的圆角胶囊选项条。
 */
@Component
export struct SlidingSegment {
  @Prop options: SegmentOption[] = [];
  @Prop @Watch('onSelectedChange') selected: string = '';
  @Prop disabled: boolean = false;
  @Prop compact: boolean = false;
  onSelect: (id: string) => void = () => {};

  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private thumbX: number = 0;
  @State private thumbW: number = 0;
  @State private thumbH: number = 0;
  @State private thumbReady: boolean = false;
  @State private pressingId: string = '';

  private boxes: Map<string, SegBox> = new Map<string, SegBox>();

  private syncThumb(animate: boolean): void {
    const box: SegBox | undefined = this.boxes.get(this.selected);
    if (box === undefined || box.w <= 0) {
      return;
    }
    if (!animate || !this.thumbReady) {
      this.thumbX = box.x;
      this.thumbW = box.w;
      this.thumbH = box.h;
      this.thumbReady = true;
      return;
    }
    this.getUIContext().animateTo(Motion.flagshipSnappy(), () => {
      this.thumbX = box.x;
      this.thumbW = box.w;
      this.thumbH = box.h;
    });
  }

  private onSelectedChange(): void {
    this.syncThumb(Motion.isFlagship(this.motionMode));
  }

  private hPad(): number {
    return this.compact ? 11 : 12;
  }

  private vPad(): number {
    return this.compact ? 5.5 : 6;
  }

  build() {
    if (Motion.isFlagship(this.motionMode)) {
      Stack({ alignContent: Alignment.Start }) {
        if (this.thumbReady && this.thumbW > 0) {
          Row()
            .width(this.thumbW)
            .height(this.thumbH > 0 ? this.thumbH : 28)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.accent)
            .shadow({ radius: 10, color: Tokens.accentGlow, offsetY: 2 })
            .translate({ x: this.thumbX })
            .scale({
              x: this.pressingId === this.selected ? 0.95 : 1,
              y: this.pressingId === this.selected ? 0.95 : 1
            })
            .animation(Motion.flagshipSnappy())
            .hitTestBehavior(HitTestMode.None)
        }

        Row({ space: 2 }) {
          ForEach(this.options, (opt: SegmentOption) => {
            Text(opt.label)
              .fontSize(Tokens.fsFoot)
              .fontWeight(this.selected === opt.id ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.selected === opt.id ? Tokens.accentInk : Tokens.dim)
              .padding({
                left: this.hPad(),
                right: this.hPad(),
                top: this.vPad(),
                bottom: this.vPad()
              })
              .borderRadius(Tokens.rPill)
              .backgroundColor(!this.thumbReady && this.selected === opt.id ? Tokens.accent : Color.Transparent)
              .scale({
                x: this.pressingId === opt.id && this.selected !== opt.id ? 0.93 : 1,
                y: this.pressingId === opt.id && this.selected !== opt.id ? 0.93 : 1
              })
              .animation(Motion.flagshipSnappy())
              .onAreaChange((_oldVal: Area, newVal: Area) => {
                const x: number = Number(newVal.position.x);
                const w: number = Number(newVal.width);
                const h: number = Number(newVal.height);
                if (w > 0 && h > 0) {
                  const prev: SegBox | undefined = this.boxes.get(opt.id);
                  const changed: boolean = prev === undefined
                    || Math.abs(prev.x - x) > 0.5
                    || Math.abs(prev.w - w) > 0.5
                    || Math.abs(prev.h - h) > 0.5;
                  if (changed) {
                    const nextBox: SegBox = { x: x, w: w, h: h };
                    this.boxes.set(opt.id, nextBox);
                    if (opt.id === this.selected) {
                      this.syncThumb(this.thumbReady);
                    }
                  }
                }
              })
              .onTouch((e: TouchEvent) => {
                if (this.disabled) {
                  return;
                }
                if (e.type === TouchType.Down) {
                  this.pressingId = opt.id;
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  if (this.pressingId === opt.id) {
                    this.pressingId = '';
                  }
                }
              })
              .onClick(() => {
                if (this.disabled || this.selected === opt.id) {
                  return;
                }
                Haptics.tap();
                this.onSelect(opt.id);
              })
          }, (opt: SegmentOption) => opt.id)
        }
        .alignItems(VerticalAlign.Center)
      }
      .padding(3)
      .borderRadius(Tokens.rPill)
      .backgroundColor(this.themeDark ? '#24FFFFFF' : '#120F172A')
      .border({
        width: 0.5,
        color: this.themeDark ? '#26FFFFFF' : '#140F172A'
      })
      .opacity(this.disabled ? 0.6 : 1)
    } else {
      Row() {
        ForEach(this.options, (opt: SegmentOption) => {
          Text(opt.label)
            .fontSize(Tokens.fsFoot)
            .fontColor(this.selected === opt.id ? Tokens.accentInk : Tokens.dim)
            .backgroundColor(this.selected === opt.id ? Tokens.accent : Tokens.surface2)
            .borderRadius(Tokens.rPill)
            .padding({
              left: this.hPad(),
              right: this.hPad(),
              top: this.vPad(),
              bottom: this.vPad()
            })
            .margin({ left: 6 })
            .opacity(this.disabled ? 0.65 : 1)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              if (this.disabled || this.selected === opt.id) {
                return;
              }
              Haptics.tap();
              this.onSelect(opt.id);
            })
        }, (opt: SegmentOption) => opt.id)
      }
      .alignItems(VerticalAlign.Center)
    }
  }
}
