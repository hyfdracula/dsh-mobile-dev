import { Haptics } from '../../common/Haptics';
import { Motion } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 全屏多行长文编辑器（K4 / U1 / U5 / M1）：
 * 既用于展开编辑当前草稿，也用于编辑宿主排队中的消息。
 */
@Component
export struct BigEditorOverlay {
  @Prop isQueueEdit: boolean = false;
  @Prop text: string = '';
  @Prop canSendAttach: boolean = false;
  @Prop kbH: number = 0;
  onTextChange: (v: string) => void = () => {};
  onSend: () => void = () => {};
  onSaveQueue: () => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      Row() {
        Text(this.isQueueEdit ? '编辑待发送' : '编辑消息')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text(this.isQueueEdit ? '取消' : '完成')
          .fontSize(Tokens.fsBody)
          .fontColor(this.isQueueEdit ? Tokens.dim : Tokens.accent)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ bottom: 10 })

      TextArea({ text: this.text, placeholder: '想清楚了再发…' })
        .placeholderColor(Tokens.dim2)
        .fontColor(Tokens.fg)
        .fontSize(Tokens.fsBodyLg)
        .lineHeight(23)
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(Tokens.surface3)
        .borderRadius(Tokens.rCard)
        .padding(14)
        .barState(BarState.Auto)
        .onChange((v: string) => {
          this.onTextChange(v);
        })

      Row() {
        Blank()
        if (this.isQueueEdit) {
          Text('保存')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.text.trim() === '' ? Tokens.dim : Tokens.accentInk)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(this.text.trim() === '' ? Tokens.surface3 : Tokens.accent)
            .borderRadius(Tokens.rPill)
            .margin({ top: 12 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              if (this.text.trim() === '') return;
              this.onSaveQueue();
            })
        } else {
          Text('发送')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.text.trim() === '' && !this.canSendAttach ? Tokens.dim : Tokens.accentInk)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .backgroundColor(this.text.trim() === '' && !this.canSendAttach ? Tokens.surface3 : Tokens.accent)
            .borderRadius(Tokens.rPill)
            .margin({ top: 12 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              if (this.text.trim() === '' && !this.canSendAttach) return;
              this.onSend();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16,
      top: this.topInset + 12,
      bottom: this.kbH > 0 ? this.kbH + 14 : this.bottomInset + 16
    })
    .backgroundColor(this.themeBg)
    .transition(
      TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
        .combine(TransitionEffect.translate({ y: '100%' }).animation(Motion.baseElastic()))
    )
  }
}
