import { Ticket, statusText, timeText } from '../../common/Feedback';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { feedbackKindName, ticketStatusBg, ticketStatusInk } from './FeedbackTypes';

/**
 * 「我的反馈」工单列表视图：区分加载中、空态与工单卡片列表（统一材质与逐卡绽放）。
 */
@Component
export struct FeedbackMineView {
  @Prop rows: Ticket[] = [];
  @Prop loaded: boolean = false;
  @Prop busy: boolean = false;
  @Prop err: string = '';
  onGoSubmit: () => void = () => {};
  onOpenTicket: (id: string) => void = () => {};
  onRetry: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private replySuffix(t: Ticket): string {
    if (t.replies !== undefined && t.replies.length > 0) {
      return ' · ' + String(t.replies.length) + ' 条回复';
    }
    return '';
  }

  build() {
    Column() {
      if (this.err !== '') {
        Row() {
          Text(this.err)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .maxLines(4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text('重试')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ left: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
            .onClick(() => {
              Haptics.tap();
              this.onRetry();
            })
        }
        .width('100%')
        .padding(12)
        .margin({ bottom: 12 })
        .backgroundColor(Tokens.intrBg)
        .border({ width: 1, color: Tokens.err })
        .borderRadius(Tokens.rMd)
        .alignItems(VerticalAlign.Center)
      }

      if (!this.loaded && this.busy) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(Tokens.accent)
          Text('正在读取工单列表…')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.dim2)
            .margin({ top: 10 })
        }
        .width('100%')
        .padding({ top: 72, bottom: 48 })
        .alignItems(HorizontalAlign.Center)
      } else if (this.rows.length === 0) {
        EmptyState({
          icon: $r('app.media.ic_chat'),
          title: '还没有提交过反馈',
          hint: '遇到连接异常、界面细节问题或新功能建议，欢迎随时提交',
          action: '去提交反馈',
          onAction: () => {
            this.onGoSubmit();
          }
        })
      } else {
        ForEach(this.rows, (t: Ticket, idx: number) => {
          Column() {
            Row() {
              Text(t.id)
                .fontSize(Tokens.fsCaption)
                .fontFamily('monospace')
                .fontColor(Tokens.dim2)
              Blank()
              Text(statusText(t.status))
                .fontSize(Tokens.fsCaption)
                .fontWeight(FontWeight.Medium)
                .fontColor(ticketStatusInk(t.status))
                .backgroundColor(ticketStatusBg(t.status))
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(t.title)
              .fontSize(Tokens.fsBodyLg)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .width('100%')
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 6 })

            Text(feedbackKindName(t.kind) + ' · ' + timeText(t.created_at) + this.replySuffix(t))
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .width('100%')
              .margin({ top: 6 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(14)
          .margin({ bottom: 10 })
          .borderRadius(Tokens.rCard)
          .backgroundColor(Mat.cardBg(this.hdsOn))
          .border(Mat.cardBorder(this.hdsOn))
          .shadow(Mat.cardShadow(this.hdsOn))
          .transition(Motion.bloomCard(idx, this.motionMode))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            Haptics.tap();
            this.onOpenTicket(t.id);
          })
        }, (t: Ticket) => t.id + ':' + t.status + ':' + String(t.updated_at))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
