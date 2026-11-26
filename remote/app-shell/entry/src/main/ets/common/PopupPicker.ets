import { Haptics } from './Haptics';
import { Mat } from './Mat';
import { Motion, MOTION_VIVID } from './Motion';
import { Tokens } from './Tokens';
import { PopupItem, PopupSection, UnifiedPopupCard } from './UnifiedPopup';

/** 锚点下拉选择项定义。 */
export interface PickerOption {
  id: string;
  label: string;
  sub?: string;
}

/**
 * 64-65 秒同款锚点下拉选择卡（PopupPicker）：
 * - 视觉样式、圆角与沉浸光感与会话页顶栏工作区/电脑选择菜单 100% 统一；
 * - 跟随全局 hdsOn 实时在「液态玻璃」与「经典实色」之间切换；
 * - 替代分段滑块作为全应用所有选项按钮的统一交互控件。
 */
@Component
export struct PopupPicker {
  @Prop options: PickerOption[] = [];
  @Prop selected: string = '';
  @Prop title: string = '';
  @Prop disabled: boolean = false;
  @Prop popupWidth: number = 220;
  onSelect: (id: string) => void = () => {};

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private open: boolean = false;

  private currentLabel(): string {
    for (let i = 0; i < this.options.length; i++) {
      if (this.options[i].id === this.selected) {
        return this.options[i].label;
      }
    }
    return this.options.length > 0 ? this.options[0].label : '';
  }

  private buildSections(): PopupSection[] {
    const items: PopupItem[] = [];
    for (let i = 0; i < this.options.length; i++) {
      const opt: PickerOption = this.options[i];
      const row: PopupItem = {
        id: opt.id,
        label: opt.label,
        sub: opt.sub,
        checked: opt.id === this.selected
      };
      items.push(row);
    }
    const sec: PopupSection = { title: this.title, items: items };
    return [sec];
  }

  @Builder
  private menuBuilder() {
    UnifiedPopupCard({
      sections: this.buildSections(),
      cardWidth: this.popupWidth,
      maxCardHeight: 340,
      onSelect: (id: string): void => {
        this.open = false;
        if (id !== this.selected) {
          Haptics.confirm();
          this.onSelect(id);
        }
      }
    })
  }

  build() {
    Row({ space: 6 }) {
      Text(this.currentLabel())
        .fontSize(Tokens.fsFoot)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.open ? Tokens.accent : Tokens.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 132 })

      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor([this.open ? Tokens.accent : Tokens.dim])
        .rotate({ angle: this.open ? 180 : 0 })
        .animation(Motion.fadeOpts(this.motionMode))
    }
    .height(34)
    .padding({ left: 12, right: 10 })
    .borderRadius(Tokens.rPill)
    .backgroundColor(this.open ? Tokens.accentSoft : Mat.subCardBg(this.hdsOn))
    .border(this.open ? { width: 1, color: Tokens.accent } : Mat.subCardBorder(this.hdsOn))
    .alignItems(VerticalAlign.Center)
    .opacity(this.disabled ? 0.55 : 1)
    .clickEffect(this.disabled ? null : { level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      if (this.disabled) {
        return;
      }
      Haptics.tick();
      this.open = !this.open;
    })
    .bindPopup(this.open, Mat.popupOpts(
      this.hdsOn,
      (): void => {
        this.menuBuilder();
      },
      Placement.BottomRight,
      { x: 0, y: 6 },
      (vis: boolean): void => {
        if (!vis) {
          this.open = false;
        }
      },
      20,
      Motion.popupMenuTransition(this.motionMode, true)
    ))
  }
}
