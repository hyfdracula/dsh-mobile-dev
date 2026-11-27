import { Haptics } from '../common/Haptics';
import { LegalDocKind, legalParagraphsOf, legalTitleOf } from '../common/LegalDocs';
import { Mat } from '../common/Mat';
import { Motion } from '../common/Motion';
import { Tokens } from '../common/Tokens';
import { AiSetupGuideBody, TunnelSetupGuideBody } from './AgentSetupCard';

/**
 * 高帧率隔离悬浮阅读卡（用于「隐私政策 / 用户协议 / 开源许可 / 外网配置向导」）：
 * - 独立承载弹出/关闭/拖拽状态，避免触发 SettingsPage 千行根组件重绘；
 * - 彻底移除背板全屏动态 blur + 叠加 32px 实时模糊，消除 Rosen 每帧重复截图重算导致的严重掉帧；
 * - 运动与拖拽期间启用 renderGroup(true) 单纹理合成，落定后自动恢复清晰可选文本；
 * - 弹出、收起与拖拽回弹统一采用全 App 基础欠阻尼弹簧曲线 Motion.unifiedElastic。
 */
@Component
export struct ReadingSheetOverlay {
  @Prop route: string = '';
  @Prop maxCardWidth: number = 552;
  @Prop @Watch('onCloseSignal') closeSignal: number = 0;
  onClosed: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private openFactor: number = 0;
  @State private dragY: number = 0;
  @State private animating: boolean = true;
  @State private paragraphs: string[] = [];

  private openTimer: number = -1;
  private settleTimer: number = -1;
  private closeTimer: number = -1;
  private closing: boolean = false;

  aboutToAppear(): void {
    this.closing = false;
    this.openFactor = 0;
    this.dragY = 0;
    this.animating = true;
    this.paragraphs = this.isLegalRoute(this.route)
      ? legalParagraphsOf(this.legalKindOf(this.route))
      : [];
    this.openTimer = setTimeout(() => {
      this.openTimer = -1;
      if (this.closing) {
        return;
      }
      this.getUIContext().animateTo(Motion.flagshipSheet(), () => {
        this.openFactor = 1;
      });
      this.scheduleSettle(680);
    }, 20);
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.openTimer >= 0) {
      clearTimeout(this.openTimer);
      this.openTimer = -1;
    }
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
      this.settleTimer = -1;
    }
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  private scheduleSettle(delayMs: number): void {
    if (this.settleTimer >= 0) {
      clearTimeout(this.settleTimer);
    }
    this.settleTimer = setTimeout(() => {
      this.settleTimer = -1;
      if (!this.closing) {
        this.animating = false;
      }
    }, delayMs);
  }

  private onCloseSignal(): void {
    if (this.closeSignal > 0) {
      this.dismiss();
    }
  }

  private isLegalRoute(r: string): boolean {
    return r !== 'guide:ai' && r !== 'guide:tunnel';
  }

  private legalKindOf(r: string): LegalDocKind {
    if (r === 'legal:terms') {
      return 'terms';
    }
    if (r === 'legal:licenses') {
      return 'licenses';
    }
    return 'privacy';
  }

  private titleOf(r: string): string {
    if (r === 'guide:ai') {
      return '让 AI 帮你配';
    }
    if (r === 'guide:tunnel') {
      return '外网访问配置向导';
    }
    return legalTitleOf(this.legalKindOf(r));
  }

  private heightFor(r: string): string {
    if (r === 'guide:ai') {
      return '78%';
    }
    if (r === 'guide:tunnel') {
      return '84%';
    }
    return '80%';
  }

  private sheetSurfaceBg(): string {
    if (!this.hdsOn) {
      return Tokens.surface;
    }
    return this.themeDark ? '#F0151B28' : '#F5FFFFFF';
  }

  private sheetShadow(): ShadowOptions {
    if (!this.hdsOn) {
      return Mat.floatShadow(false);
    }
    const s: ShadowOptions = {
      radius: 16,
      color: this.themeDark ? '#42000000' : '#181C2C4D',
      offsetX: 0,
      offsetY: 5
    };
    return s;
  }

  private scrimOpacity(): number {
    if (this.openFactor <= 0) {
      return 0;
    }
    const dragRatio: number = Math.min(1, Math.max(0, this.dragY / 320));
    return Math.max(0, this.openFactor * (1 - dragRatio));
  }

  private isSectionHeading(line: string): boolean {
    return /^[一二三四五六七八九十]+、/.test(line) || /^[-=]{6,}$/.test(line);
  }

  private dismiss(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    this.clearTimers();
    this.animating = true;
    this.getUIContext().animateTo(Motion.flagshipSheet(), () => {
      this.openFactor = 0;
      this.dragY = 0;
    });
    this.closeTimer = setTimeout(() => {
      this.closeTimer = -1;
      this.onClosed();
    }, 320);
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 轻量化纯 GPU 透明遮罩（无全屏动态 blur 重算，锁定 120fps）
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeDark ? '#78000000' : '#380F172A')
        .opacity(this.scrimOpacity())
        .onClick(() => {
          Haptics.soft();
          this.dismiss();
        })

      Column() {
        Stack({ alignContent: Alignment.Top }) {
          if (this.hdsOn) {
            Row()
              .width('100%')
              .height(140)
              .linearGradient({
                angle: 170,
                colors: this.themeDark
                  ? [['#1FFFFFFF', 0.0], ['#08FFFFFF', 0.45], ['#00FFFFFF', 1.0]]
                  : [['#70FFFFFF', 0.0], ['#1CFFFFFF', 0.45], ['#00FFFFFF', 1.0]]
              })
              .hitTestBehavior(HitTestMode.None)
          }

          Column() {
            // 顶部拖拽指示条 + 标题栏
            Column() {
              Row()
                .width(38)
                .height(4)
                .borderRadius(2)
                .backgroundColor(this.themeDark ? '#40FFFFFF' : '#260F172A')
                .margin({ top: 9, bottom: 8 })

              Row({ space: 10 }) {
                Text(this.titleOf(this.route))
                  .fontSize(Tokens.fsTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.fg)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                Stack({ alignContent: Alignment.Center }) {
                  SymbolGlyph($r('sys.symbol.xmark'))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor([Tokens.dim])
                }
                .width(34)
                .height(34)
                .borderRadius(Tokens.rPill)
                .backgroundColor(Mat.subCardBg(this.hdsOn))
                .border(Mat.subCardBorder(this.hdsOn))
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                .accessibilityText('关闭')
                .onClick(() => {
                  Haptics.soft();
                  this.dismiss();
                })
              }
              .width('100%')
              .padding({ left: 18, right: 16, bottom: 10 })
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .gesture(
              PanGesture({ direction: PanDirection.Vertical, distance: 4 })
                .onActionStart(() => {
                  if (this.settleTimer >= 0) {
                    clearTimeout(this.settleTimer);
                    this.settleTimer = -1;
                  }
                  this.animating = true;
                })
                .onActionUpdate((e: GestureEvent) => {
                  const dy: number = e.offsetY;
                  this.dragY = dy > 0 ? dy : dy * 0.16;
                })
                .onActionEnd((e: GestureEvent) => {
                  if (this.dragY > 96 || e.velocityY > 560) {
                    Haptics.soft();
                    this.dismiss();
                  } else {
                    this.getUIContext().animateTo(Motion.flagshipSheet(), () => {
                      this.dragY = 0;
                    });
                    this.scheduleSettle(680);
                  }
                })
            )

            Scroll() {
              Column({ space: 8 }) {
                if (this.route === 'guide:ai') {
                  AiSetupGuideBody()
                } else if (this.route === 'guide:tunnel') {
                  TunnelSetupGuideBody()
                } else {
                  ForEach(this.paragraphs, (para: string, idx: number) => {
                    Text(para)
                      .fontSize(this.isSectionHeading(para) ? Tokens.fsBodyLg : Tokens.fsBody)
                      .fontWeight(this.isSectionHeading(para) ? FontWeight.Medium : FontWeight.Normal)
                      .fontColor(Tokens.fg)
                      .lineHeight(22)
                      .width('100%')
                      .margin({ top: this.isSectionHeading(para) && idx > 0 ? 6 : 0 })
                      .copyOption(CopyOptions.LocalDevice)
                  }, (para: string, idx: number) => String(idx) + ':' + para.substring(0, 12))
                }
              }
              .width('100%')
              .padding({ left: 18, right: 18, top: 4, bottom: 26 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top)
          }
          .width('100%')
          .height('100%')
          .renderGroup(this.animating)
        }
        .width('100%')
        .constraintSize({ maxWidth: this.maxCardWidth })
        .height(this.heightFor(this.route))
        .backgroundColor(this.sheetSurfaceBg())
        .borderRadius(28)
        .border(Mat.glassRimBorder(this.hdsOn))
        .shadow(this.sheetShadow())
        .clip(true)
        .translate({ y: (1 - this.openFactor) * 560 + this.dragY })
        .scale({
          x: 0.95 + 0.05 * this.openFactor,
          y: 0.95 + 0.05 * this.openFactor
        })
        .opacity(Math.min(1, this.openFactor * 1.5))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 10, right: 10, bottom: this.bottomInset + 10 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }
}
