import { Haptics } from '../common/Haptics';
import { legalBodyOf, LegalDocKind, legalTitleOf } from '../common/LegalDocs';
import { Tokens } from '../common/Tokens';
import { SheetHeader } from '../common/Widgets';

/**
 * 合规文档阅读半屏内容（挂在原生 bindSheet + Mat.sheetOpts 中，与全站半屏液态玻璃视觉统一）。
 */
@Component
export struct LegalSheet {
  @Prop kind: LegalDocKind = 'privacy';
  onClose: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      SheetHeader({
        title: legalTitleOf(this.kind),
        onClose: () => {
          this.onClose();
        }
      })

      Scroll() {
        Text(legalBodyOf(this.kind))
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .lineHeight(22)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .margin({ top: 10 })

      Row() {
        Text('关闭')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rInput)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 14, bottom: this.bottomInset + 16 })
  }
}
