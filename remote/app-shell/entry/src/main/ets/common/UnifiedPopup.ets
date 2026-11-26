import { Haptics } from './Haptics';
import { Mat } from './Mat';
import { Tokens } from './Tokens';

/** 统一弹出菜单单项定义。 */
export interface PopupItem {
  id: string;
  label: string;
  sub?: string;
  checked?: boolean;
  danger?: boolean;
  disabled?: boolean;
}

/** 统一弹出菜单分组定义。 */
export interface PopupSection {
  title: string;
  items: PopupItem[];
}

/**
 * 统一弹出菜单卡片（F05）：
 * 供会话列表菜单、聊天顶栏更多、筛选切换等所有弹层共用，
 * 保持统一的毛玻璃材质、圆角、投影、分组标题与选中态。
 */
@Component
export struct UnifiedPopupCard {
  @Prop sections: PopupSection[] = [];
  @Prop cardWidth: number = 248;
  @Prop maxCardHeight: number = 440;
  onSelect: (id: string) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private labelColor(item: PopupItem): string {
    if (item.danger === true) {
      return Tokens.err;
    }
    if (item.checked === true) {
      return Tokens.accent;
    }
    return Tokens.fg;
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          ForEach(this.sections, (sec: PopupSection, sIdx: number) => {
            Column() {
              if (sIdx > 0) {
                Divider()
                  .color(Tokens.lineSoft)
                  .margin({ left: 10, right: 10, top: 4, bottom: 4 })
              }
              if (sec.title !== '') {
                Text(sec.title)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Tokens.dim2)
                  .letterSpacing(0.8)
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 6, bottom: 4 })
              }
              ForEach(sec.items, (item: PopupItem) => {
                Row() {
                  Column() {
                    Text(item.label)
                      .fontSize(13.5)
                      .fontWeight(item.checked === true ? FontWeight.Medium : FontWeight.Normal)
                      .fontColor(this.labelColor(item))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.sub !== undefined && item.sub !== '') {
                      Text(item.sub)
                        .fontSize(11)
                        .fontColor(Tokens.dim2)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 1 })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (item.checked === true) {
                    SymbolGlyph($r('sys.symbol.checkmark'))
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor([Tokens.accent])
                      .margin({ left: 8 })
                  }
                }
                .width('100%')
                .constraintSize({ minHeight: 40 })
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .alignItems(VerticalAlign.Center)
                .borderRadius(Tokens.rSm)
                .backgroundColor(item.checked === true ? Tokens.accentSoft : Color.Transparent)
                .opacity(item.disabled === true ? 0.42 : 1)
                .clickEffect(item.disabled === true ? null : { level: ClickEffectLevel.LIGHT, scale: 0.97 })
                .onClick(() => {
                  if (item.disabled === true) {
                    return;
                  }
                  if (item.danger === true) {
                    Haptics.warn();
                  } else {
                    Haptics.tick();
                  }
                  this.onSelect(item.id);
                })
              }, (item: PopupItem) => sec.title + '|' + item.id + '|' + (item.checked === true ? '1' : '0') + '|' +
                (item.disabled === true ? 'd' : 'e') + '|' + item.label)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (sec: PopupSection, sIdx: number) => String(sIdx) + '|' + sec.title + '|' + String(sec.items.length))
        }
        .width('100%')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
      }
      .width('100%')
      .constraintSize({ maxHeight: this.maxCardHeight })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(this.cardWidth)
    .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
    .border(this.hdsOn
      ? { width: 1, color: Mat.floatBorderColor(true) }
      : { width: 1, color: Tokens.line })
    .borderRadius(Tokens.rCard)
    .clip(true)
  }
}
