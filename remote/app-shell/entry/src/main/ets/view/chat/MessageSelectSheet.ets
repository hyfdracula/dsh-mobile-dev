import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { parseMd } from '../../common/Md';
import { Motion } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { MdBody } from '../MdBody';

/**
 * 长按消息弹出的「选择文本 / Markdown 原文」半模态面板（K4 / U1 / M1）。
 */
@Component
export struct MessageSelectSheet {
  @Prop text: string = '';
  onQuote: () => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('textScale') textScale: number = 1;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private selRaw: boolean = false;

  @Builder
  private selTab(label: string, which: string, act: () => void) {
    Text(label)
      .fontSize(Tokens.fsBody)
      .fontColor(((which === 'raw') === this.selRaw) ? Tokens.fg : Tokens.dim)
      .fontWeight(((which === 'raw') === this.selRaw) ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(34)
      .borderRadius(Tokens.rPill)
      .backgroundColor(Color.Transparent)
      .animation({ duration: Motion.move, curve: Motion.std })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(() => {
        Haptics.tap();
        act();
      })
  }

  @Builder
  private selBtn(label: string, primary: boolean, act: () => void) {
    Text(label)
      .fontSize(Tokens.fsBody)
      .fontColor(primary ? Tokens.accentInk : Tokens.fg)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(42)
      .borderRadius(Tokens.rPill)
      .backgroundColor(primary ? Tokens.accentStrong : Mat.subCardBg(this.hdsOn))
      .border(primary
        ? { width: 1, color: Tokens.accentStrong }
        : Mat.subCardBorder(this.hdsOn))
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(act)
  }

  build() {
    Column() {
      Row() {
        Text('选择文本')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('×')
          .fontSize(24)
          .fontColor(Tokens.dim2)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 10, top: 12, bottom: 2 })

      Row() {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('50%')
            .height(34)
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.hdsOn
              ? (Tokens.isDark ? '#3DFFFFFF' : '#FFFFFFFF')
              : Tokens.surface)
            .shadow(this.hdsOn
              ? { radius: 6, color: Tokens.isDark ? '#33000000' : '#1A000000', offsetY: 1 }
              : { radius: 0, color: Color.Transparent })
            .translate({ x: this.selRaw ? '100%' : '0%' })
            .animation({ duration: Motion.move, curve: Motion.std })
          Row() {
            this.selTab('正文', 'body', (): void => {
              this.selRaw = false;
            })
            this.selTab('Markdown 原文', 'raw', (): void => {
              this.selRaw = true;
            })
          }
          .width('100%')
        }
        .width('100%')
        .height(40)
        .padding(3)
        .backgroundColor(this.hdsOn
          ? (Tokens.isDark ? '#26FFFFFF' : '#14000000')
          : Tokens.surface2)
        .border(this.hdsOn ? { width: 0, color: Color.Transparent } : Mat.subCardBorder(false))
        .borderRadius(Tokens.rPill)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8 })

      Scroll() {
        if (this.selRaw) {
          Text(this.text)
            .fontSize(13 * this.textScale)
            .lineHeight(22 * this.textScale)
            .fontFamily('monospace')
            .fontColor(Tokens.fg)
            .width('100%')
            .textAlign(TextAlign.Start)
            .copyOption(CopyOptions.LocalDevice)
            .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
        } else {
          MdBody({ blocks: parseMd(this.text) })
            .width('100%')
            .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 10 })
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)

      Row({ space: 10 }) {
        this.selBtn('复制全文', true, (): void => {
          void copyText(this.text, '已复制全文');
        })
        this.selBtn('引用全文', false, (): void => {
          Haptics.tap();
          this.onQuote();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: this.bottomInset + 16 })
    }
    .width('100%')
    .height('100%')
  }
}
