import { AppCtx } from '../common/AppCtx';
import { isFeedbackEnabled } from '../common/Feedback';
import { Haptics } from '../common/Haptics';
import { LegalDocKind } from '../common/LegalDocs';
import { LinkLog } from '../common/LinkLog';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
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
  @State private entered: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  private enterTimer: number = -1;
  private wave: BloomWaveTracker = new BloomWaveTracker();

  aboutToAppear(): void {
    this.logCount = LinkLog.count();
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 24);
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

  private diagBaseIdx(): number {
    return this.rows.length;
  }

  private legalStartIdx(): number {
    return this.rows.length + (isFeedbackEnabled() ? 2 : 1);
  }

  @Builder
  actionCard(title: string, hint: string, waveKey: string, fallbackDistVp: number, onTap: () => void) {
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
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .borderRadius(Tokens.rRow)
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onAreaChange((_old: Area, area: Area) => {
      this.wave.record(waveKey, area);
    })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
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
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:ver', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:ver', 0), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:ver', 0), this.motionMode)
          : null)

      Column({ space: 9 }) {
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
          .backgroundColor(Mat.cardBg(this.hdsOn))
          .border(Mat.cardBorder(this.hdsOn))
          .shadow(Mat.rowShadow(this.hdsOn))
          .borderRadius(Tokens.rRow)
          .clip(true)
          .onAreaChange((_old: Area, area: Area) => {
            this.wave.record('row:' + r.k, area);
          })
          .animation(null)
          .opacity(this.entered ? 1 : 0)
          .animation(this.entered
            ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('row:' + r.k, 32 + i * 58), this.motionMode)
            : null)
          .scale({
            x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
            y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
            centerX: '50%',
            centerY: '50%'
          })
          .animation(this.entered
            ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('row:' + r.k, 32 + i * 58), this.motionMode)
            : null)
        }, (r: AboutRow) => r.k + ':' + r.v)
      }
      .width('100%')

      Text('诊断与协议')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:diag', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:diag', 32 + this.diagBaseIdx() * 58 + 20), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:diag', 32 + this.diagBaseIdx() * 58 + 20), this.motionMode)
          : null)

      Column({ space: 9 }) {
        this.actionCard(
          this.exporting ? '正在导出运行诊断日志…' : '导出运行诊断日志',
          String(this.logCount) + ' 条脱敏记录 · 网络/引擎/运行状态，不含令牌与正文',
          'act:diag',
          32 + this.diagBaseIdx() * 58 + 56,
          () => {
            void this.exportDiagLog();
          }
        )

        if (isFeedbackEnabled()) {
          this.actionCard('反馈与支持', '提交问题、功能建议与查看进度', 'act:fb', 32 + this.diagBaseIdx() * 58 + 132, () => {
            this.onFeedback();
          })
        }

        this.actionCard('隐私政策', '说明本地存储、权限范围与加密机制', 'act:privacy', 32 + this.legalStartIdx() * 68 + 56, () => {
          this.onLegal('privacy');
        })

        this.actionCard('用户协议', '使用约定与免责说明', 'act:terms', 32 + (this.legalStartIdx() + 1) * 68 + 56, () => {
          this.onLegal('terms');
        })

        this.actionCard('开源许可', '查看第三方组件与标准协议声明', 'act:licenses', 32 + (this.legalStartIdx() + 2) * 68 + 56, () => {
          this.onLegal('licenses');
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
