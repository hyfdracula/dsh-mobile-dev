import { AppCtx } from '../common/AppCtx';
import { isFeedbackEnabled } from '../common/Feedback';
import { Haptics } from '../common/Haptics';
import { LegalDocKind } from '../common/LegalDocs';
import { LinkLog } from '../common/LinkLog';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Saver } from '../common/Saver';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';

/** 关于页的一行「键 - 值」。 */
export interface AboutRow {
  k: string;
  v: string;
  mono: boolean;
}

/**
 * 「关于与协议」：版本/环境概况 + 运行诊断日志导出 + 隐私政策/用户协议/开源许可 + 条件反馈入口。
 */
@Component
export struct AboutPanel {
  @Prop rows: AboutRow[] = [];
  @Prop verText: string = '';
  onFeedback: () => void = () => {};
  onLegal: (kind: LegalDocKind) => void = () => {};

  @State private logCount: number = 0;
  @State private exporting: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  aboutToAppear(): void {
    this.logCount = LinkLog.count();
  }

  private async exportDiagLog(): Promise<void> {
    if (this.exporting) {
      return;
    }
    Haptics.tap();
    this.exporting = true;
    try {
      const ctx = AppCtx.ability();
      const content: string = LinkLog.exportContent(this.verText);
      const saved: boolean = await Saver.saveText(ctx, content, 'agent-mobile-diag-log.txt');
      this.logCount = LinkLog.count();
      if (saved) {
        Haptics.success();
        Toast.ok('已导出脱敏运行诊断日志');
      }
    } catch (e) {
      Toast.err('导出失败：' + (e as Error).message);
    } finally {
      this.exporting = false;
    }
  }

  @Builder
  actionRow(title: string, hint: string, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.fg)
        if (hint !== '') {
          Text(hint)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

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
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      Haptics.tap();
      onTap();
    })
  }

  build() {
    Column() {
      Text('版本与环境')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 6, bottom: 8 })

      Column() {
        ForEach(this.rows, (r: AboutRow, i: number) => {
          Row() {
            Text(r.k)
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.dim)
              .width(88)
            Text(r.v)
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.fg)
              .fontFamily(r.mono ? 'monospace' : 'sans-serif')
              .layoutWeight(1)
              .textAlign(TextAlign.End)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 13, bottom: 13 })
          .alignItems(VerticalAlign.Center)
          if (i < this.rows.length - 1) {
            Divider().color(Tokens.lineSoft).margin({ left: 16 })
          }
        }, (r: AboutRow) => r.k + ':' + r.v)
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(0, this.motionMode))

      Text('诊断与协议')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        this.actionRow(
          this.exporting ? '正在导出运行诊断日志…' : '导出运行诊断日志',
          String(this.logCount) + ' 条脱敏记录 · 网络/引擎/运行状态，不含令牌与正文',
          () => {
            void this.exportDiagLog();
          }
        )

        if (isFeedbackEnabled()) {
          Divider().color(Tokens.lineSoft).margin({ left: 16 })
          this.actionRow('反馈与支持', '提交问题、功能建议与查看进度', () => {
            this.onFeedback();
          })
        }

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.actionRow('隐私政策', '说明本地存储、权限范围与加密机制', () => {
          this.onLegal('privacy');
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.actionRow('用户协议', '使用约定与免责说明', () => {
          this.onLegal('terms');
        })

        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.actionRow('开源许可', '查看第三方组件与标准协议声明', () => {
          this.onLegal('licenses');
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(1, this.motionMode))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
