import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { QQ_GROUP } from './FeedbackTypes';

/**
 * 反馈入口视图：提交反馈 / 我的反馈 / QQ 交流群快捷复制（与外部设置页材质、错峰绽放统一）。
 */
@Component
export struct FeedbackEntryView {
  onGoSubmit: () => void = () => {};
  onGoMine: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @State private entered: boolean = true;
  private enterTimer: number = -1;

  aboutToAppear(): void {
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 16);
    } else {
      this.entered = true;
    }
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  @Builder
  entryRow(title: string, sub: string, idx: number, act: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
        if (sub !== '') {
          Text(sub)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (Motion.isFlagship(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Tokens.dim2])
      } else {
        Text('›')
          .fontSize(17)
          .fontColor(Tokens.dim2)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 14, bottom: 14 })
    .margin({ bottom: 9 })
    .borderRadius(Tokens.rRow)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(Motion.bloomOpacityAnim(idx, this.motionMode))
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .translate({ y: this.entered ? 0 : 6 })
    .animation(Motion.bloomScaleAnim(idx, this.motionMode))
    .onClick(act)
  }

  build() {
    Column() {
      Text('遇到问题或有新功能想法都可以在这里直接提交；无需电脑在线也可发送。')
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .lineHeight(19)
        .width('100%')
        .margin({ bottom: 16 })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(Motion.bloomHeaderOpacityAnim(0, this.motionMode))
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .translate({ y: this.entered ? 0 : 6 })
        .animation(Motion.bloomHeaderScaleAnim(0, this.motionMode))

      this.entryRow('提交反馈', '填写描述并附带截图、录屏或脱敏日志', 0, () => {
        Haptics.tap();
        this.onGoSubmit();
      })
      this.entryRow('我的反馈', '查看本机提交过的工单与处理进展', 1, () => {
        Haptics.tap();
        this.onGoMine();
      })
      if (QQ_GROUP !== '') {
        this.entryRow('交流群 ' + QQ_GROUP, '点此复制群号，进群反馈交流', 2, () => {
          void copyText(QQ_GROUP, '群号已复制');
        })
      }

      Text('隐私说明：提交内容仅开发者可见，不会采集账号、会话正文、访问令牌或本地私人文件。')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .lineHeight(17)
        .width('100%')
        .margin({ top: 14 })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(Motion.bloomHeaderOpacityAnim(3, this.motionMode))
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .translate({ y: this.entered ? 0 : 6 })
        .animation(Motion.bloomHeaderScaleAnim(3, this.motionMode))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
