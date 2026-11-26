import { copyText } from '../../common/Clipboard';
import {
  sizeText,
  statusText,
  Ticket,
  TicketFile,
  TicketReply,
  ticketText,
  timeText
} from '../../common/Feedback';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { ticketStatusBg, ticketStatusInk } from './FeedbackTypes';

/**
 * 工单详情视图：展示工单全文、环境信息、附件清单与开发者回复记录。
 */
@Component
export struct FeedbackDetailView {
  @Prop cur: Ticket | null = null;
  @Prop note: string = '';
  @Prop err: string = '';
  @Prop busy: boolean = false;
  onRefresh: (id: string) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  build() {
    Column() {
      if (this.note !== '') {
        Row() {
          Text('√ ' + this.note)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.ok)
            .lineHeight(18)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .margin({ bottom: 12 })
        .backgroundColor(Tokens.doneBg)
        .borderRadius(Tokens.rMd)
      }

      if (this.err !== '') {
        Text(this.err)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.err)
          .lineHeight(18)
          .width('100%')
          .padding(12)
          .margin({ bottom: 12 })
          .backgroundColor(Tokens.intrBg)
          .border({ width: 1, color: Tokens.err })
          .borderRadius(Tokens.rMd)
      }

      if (this.cur !== null) {
        Column() {
          Row() {
            Text(this.cur.id)
              .fontSize(Tokens.fsCaption)
              .fontFamily('monospace')
              .fontColor(Tokens.dim2)
            Blank()
            Text(statusText(this.cur.status))
              .fontSize(Tokens.fsCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(ticketStatusInk(this.cur.status))
              .backgroundColor(ticketStatusBg(this.cur.status))
              .borderRadius(Tokens.rPill)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.cur.title)
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .width('100%')
            .margin({ top: 8 })

          if (this.cur.body.trim() !== this.cur.title.trim()) {
            Text(this.cur.body)
              .fontSize(Tokens.fsBody)
              .lineHeight(20)
              .fontColor(Tokens.fg)
              .width('100%')
              .margin({ top: 10 })
              .copyOption(CopyOptions.LocalDevice)
          }

          Text('运行环境：' + (this.cur.env !== '' ? this.cur.env : '未采集'))
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .lineHeight(16)
            .width('100%')
            .margin({ top: 12 })

          Text('提交时间：' + timeText(this.cur.created_at))
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .width('100%')
            .margin({ top: 3 })

          if (this.cur.files !== undefined && this.cur.files.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.cur.files, (f: TicketFile, idx: number) => {
                Text(f.name + ' · ' + sizeText(f.size))
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim)
                  .backgroundColor(Tokens.surface2)
                  .borderRadius(Tokens.rSm)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .margin({ right: 6, top: 8 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }, (f: TicketFile, idx: number) => String(idx) + '-' + f.name)
            }
            .width('100%')
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .borderRadius(Tokens.rCard)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.cardShadow(this.hdsOn))
        .transition(Motion.bloomCard(0, this.motionMode))

        Text('处理记录')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .letterSpacing(1.4)
          .width('100%')
          .margin({ left: 6, top: 18, bottom: 8 })

        if (this.cur.replies === undefined || this.cur.replies.length === 0) {
          Column() {
            Text('暂时还没有新回复，有进展时会在此更新。')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(Tokens.rCard)
          .backgroundColor(Mat.cardBg(this.hdsOn))
          .border(Mat.cardBorder(this.hdsOn))
          .shadow(Mat.cardShadow(this.hdsOn))
          .transition(Motion.bloomCard(1, this.motionMode))
        } else {
          ForEach(this.cur.replies, (r: TicketReply, i: number) => {
            Column() {
              Row() {
                Text(r.author === 'admin' ? '开发者' : '用户')
                  .fontSize(Tokens.fsCaption)
                  .fontColor(r.author === 'admin' ? Tokens.accentInk : Tokens.dim)
                  .backgroundColor(r.author === 'admin' ? Tokens.accent : Tokens.surface3)
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                Text(timeText(r.at))
                  .fontSize(Tokens.fsCaption)
                  .fontColor(Tokens.dim2)
                  .margin({ left: 8 })
                Blank()
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Text(r.text)
                .fontSize(Tokens.fsBody)
                .lineHeight(20)
                .fontColor(Tokens.fg)
                .width('100%')
                .margin({ top: 6 })
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .margin({ bottom: 8 })
            .borderRadius(Tokens.rMd)
            .backgroundColor(Mat.cardBg(this.hdsOn))
            .border(Mat.cardBorder(this.hdsOn))
            .shadow(Mat.cardShadow(this.hdsOn))
            .transition(Motion.bloomCard(i + 1, this.motionMode))
          }, (r: TicketReply, i: number) => String(r.at) + '-' + String(i))
        }

        Row() {
          Text('复制工单')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.surface2)
            .margin({ right: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              if (this.cur !== null) {
                void copyText(ticketText(this.cur), '工单已复制');
              }
            })
          Text(this.busy ? '刷新中…' : '刷新状态')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.busy ? Tokens.dim : Tokens.accentInk)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.busy ? Tokens.surface3 : Tokens.accentStrong)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .onClick(() => {
              if (!this.busy && this.cur !== null) {
                Haptics.tap();
                this.onRefresh(this.cur.id);
              }
            })
        }
        .width('100%')
        .margin({ top: 16 })
      } else {
        EmptyState({
          icon: $r('app.media.ic_chat'),
          title: '未找到该工单',
          hint: '请返回列表重新选择'
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
