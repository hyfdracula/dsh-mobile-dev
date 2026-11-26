import { Message } from '../../common/Api';
import { clock } from '../../common/Format';
import { Haptics } from '../../common/Haptics';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 会话内消息搜索全屏浮层（K4 / U1 / M1）：
 * 对齐顶部/底部安全区与键盘高度，补齐顺滑进出场过渡。
 */
@Component
export struct ChatSearchOverlay {
  @Prop msgs: Message[] = [];
  @Prop kbH: number = 0;
  onJump: (m: Message) => void = () => {};
  onClose: () => void = () => {};
  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private query: string = '';

  private matchedRows(): Message[] {
    const kw: string = this.query.trim().toLowerCase();
    if (kw === '') {
      return [];
    }
    const out: Message[] = [];
    for (let i = 0; i < this.msgs.length; i++) {
      const m: Message = this.msgs[i];
      const textHit: boolean = m.text.toLowerCase().indexOf(kw) >= 0;
      const thinkHit: boolean = m.thinking !== undefined && m.thinking.toLowerCase().indexOf(kw) >= 0;
      if (textHit || thinkHit) {
        out.push(m);
      }
    }
    return out;
  }

  private snippet(t: string): string {
    const plain: string = t.replace(/[#*`>|~]/g, ' ').replace(/\s+/g, ' ').trim();
    return plain.length > 96 ? plain.slice(0, 96) + '…' : plain;
  }

  build() {
    Column() {
      Row() {
        TextInput({ placeholder: '搜索本会话消息…', text: this.query })
          .height(38)
          .fontSize(14)
          .fontColor(Tokens.fg)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface2)
          .placeholderColor(Tokens.dim2)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.query = v;
          })

        Text('取消')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .padding({ left: 12, right: 4, top: 8, bottom: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.query = '';
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.query.trim() === '') {
        Text('输入关键词，检索本会话中的对话与思考摘要')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .margin({ top: 44 })
      } else if (this.matchedRows().length === 0) {
        Text('没有匹配的消息')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim2)
          .margin({ top: 44 })
      } else {
        List() {
          ForEach(this.matchedRows(), (m: Message) => {
            ListItem() {
              Column() {
                Row() {
                  Text(m.role === 'user' ? '你' : '助手')
                    .fontSize(Tokens.fsCaption)
                    .fontColor(m.role === 'user' ? Tokens.accent : Tokens.dim2)
                  Blank()
                  Text(clock(m.time))
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.dim2)
                }
                .width('100%')

                Text(this.snippet(m.text !== '' ? m.text : (m.thinking === undefined ? '' : m.thinking)))
                  .fontSize(Tokens.fsBody)
                  .fontColor(Tokens.fg)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 4 })
              }
              .width('100%')
              .padding(12)
              .backgroundColor(Tokens.surface)
              .borderRadius(Tokens.rMd)
              .border({ width: 1, color: Tokens.lineSoft })
              .margin({ bottom: 8 })
              .alignItems(HorizontalAlign.Start)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
              .onClick(() => {
                Haptics.tap();
                this.onJump(m);
              })
            }
          }, (m: Message) => 'sr' + String(m.seq) + '_' + String(m.text.length))
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({
          left: 16,
          right: 16,
          bottom: this.kbH > 0 ? this.kbH + 12 : this.bottomInset + 16
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .padding({ top: this.topInset + 8 })
    .transition(Motion.panelTransition(this.motionMode))
  }
}
