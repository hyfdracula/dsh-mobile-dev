import { TaskStep } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 跨引擎可折叠「任务/步骤清单」卡片（DSH / Antigravity / Codex / Claude Code / OpenCode）：
 * 默认折叠为单行紧凑进度条胶囊，展示当前进行中的步骤标题与完成进度（如 3/5）；
 * 点击平滑展开完整有序清单，支持液态玻璃与实体卡片双皮肤、深浅主题及字体缩放。
 */
@Component
export struct TaskStepsCard {
  @Prop tasks: TaskStep[] = [];
  @Prop running: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('textScale') textScale: number = 1;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private expanded: boolean = false;
  @State private chevronTrigger: number = -1;

  private doneCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === 'done') {
        n++;
      }
    }
    return n;
  }

  private activeStep(): TaskStep | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === 'in_progress') {
        return this.tasks[i];
      }
    }
    return null;
  }

  private firstPending(): TaskStep | null {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === 'pending') {
        return this.tasks[i];
      }
    }
    return null;
  }

  private hasFailed(): boolean {
    for (let i = 0; i < this.tasks.length; i++) {
      if (this.tasks[i].status === 'failed') {
        return true;
      }
    }
    return false;
  }

  private allDone(): boolean {
    if (this.tasks.length === 0) {
      return false;
    }
    let done: number = 0;
    for (let i = 0; i < this.tasks.length; i++) {
      const st: string = this.tasks[i].status;
      if (st === 'done') {
        done++;
      } else if (st !== 'skipped') {
        return false;
      }
    }
    return done > 0;
  }

  private progressPct(): number {
    if (this.tasks.length === 0) {
      return 0;
    }
    return Math.min(100, Math.round((this.doneCount() * 100) / this.tasks.length));
  }

  private headerTitle(): string {
    if (this.expanded) {
      return '任务步骤';
    }
    const active: TaskStep | null = this.activeStep();
    if (active !== null) {
      return active.title;
    }
    if (this.allDone()) {
      return '任务步骤已全部完成';
    }
    const pending: TaskStep | null = this.firstPending();
    if (pending !== null) {
      return pending.title;
    }
    return '任务步骤';
  }

  private accentBarColor(): string {
    if (this.hasFailed()) {
      return Tokens.err;
    }
    if (this.allDone()) {
      return Tokens.ok;
    }
    return Tokens.accent;
  }

  private badgeInk(): string {
    if (this.hasFailed()) {
      return Tokens.err;
    }
    if (this.allDone()) {
      return Tokens.doneInk;
    }
    if (this.activeStep() !== null) {
      return Tokens.runInk;
    }
    return Tokens.dim;
  }

  private badgeBg(): string {
    if (this.allDone()) {
      return Tokens.doneBg;
    }
    if (this.activeStep() !== null) {
      return Tokens.runBg;
    }
    return Tokens.surface2;
  }

  private stepTextColor(status: string): string {
    if (status === 'in_progress') {
      return Tokens.accent;
    }
    if (status === 'failed') {
      return Tokens.err;
    }
    if (status === 'done') {
      return Tokens.dim;
    }
    if (status === 'skipped') {
      return Tokens.dim2;
    }
    return Tokens.fg;
  }

  build() {
    Column() {
      // 顶栏胶囊行：状态指示 + 当前步骤/标题 + 进度胶囊 + 折叠箭头
      Row() {
        Stack({ alignContent: Alignment.Center }) {
          if (this.activeStep() !== null && this.running) {
            LoadingProgress()
              .width(15)
              .height(15)
              .color(Tokens.accent)
          } else if (this.allDone()) {
            SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
              .fontSize(15)
              .fontColor([Tokens.ok])
          } else if (this.hasFailed()) {
            SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
              .fontSize(15)
              .fontColor([Tokens.err])
          } else if (this.activeStep() !== null) {
            Circle()
              .width(8)
              .height(8)
              .fill(Tokens.accent)
          } else {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize(14)
              .fontColor([Tokens.accent])
          }
        }
        .width(18)
        .height(18)
        .margin({ right: 8 })

        Text(this.headerTitle())
          .fontSize(13 * this.textScale)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.allDone() && !this.expanded ? Tokens.ok : Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(String(this.doneCount()) + '/' + String(this.tasks.length))
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.badgeInk())
          .backgroundColor(this.badgeBg())
          .borderRadius(Tokens.rPill)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .margin({ left: 8 })

        if (Motion.isVivid(this.motionMode)) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([Tokens.dim2])
            .symbolEffect(Motion.replaceEffect(), this.chevronTrigger)
            .margin({ left: 6 })
        } else {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([Tokens.dim2])
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 9, bottom: 9 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.985 })
      .accessibilityText(this.expanded ? '收起任务步骤列表' : '展开任务步骤列表')
      .onClick(() => {
        Haptics.tap();
        if (Motion.isVivid(this.motionMode)) {
          this.chevronTrigger += 1;
        }
        this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
          this.expanded = !this.expanded;
        });
      })

      // 2vp 极细进度轨道
      Row() {
        Row()
          .width(String(this.progressPct()) + '%')
          .height(2)
          .backgroundColor(this.accentBarColor())
          .animation({ duration: Motion.move, curve: Motion.std })
      }
      .width('100%')
      .height(2)
      .backgroundColor(Tokens.lineSoft)
      .alignItems(VerticalAlign.Center)

      // 展开列表：限高 224vp 独立滚动，不遮挡消息流
      if (this.expanded) {
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.tasks, (item: TaskStep, idx: number) => {
              Row() {
                Stack({ alignContent: Alignment.Center }) {
                  if (item.status === 'done') {
                    SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                      .fontSize(14)
                      .fontColor([Tokens.ok])
                  } else if (item.status === 'in_progress' && this.running) {
                    LoadingProgress()
                      .width(14)
                      .height(14)
                      .color(Tokens.accent)
                  } else if (item.status === 'in_progress') {
                    Circle()
                      .width(8)
                      .height(8)
                      .fill(Tokens.accent)
                  } else if (item.status === 'failed') {
                    SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                      .fontSize(14)
                      .fontColor([Tokens.err])
                  } else if (item.status === 'skipped') {
                    Row()
                      .width(9)
                      .height(1.8)
                      .borderRadius(1)
                      .backgroundColor(Tokens.dim2)
                  } else {
                    Circle()
                      .width(11)
                      .height(11)
                      .fill(Color.Transparent)
                      .stroke(Tokens.dim2)
                      .strokeWidth(1.4)
                  }
                }
                .width(16)
                .height(18)
                .margin({ right: 9, top: 1 })

                Column({ space: 2 }) {
                  Text(item.title)
                    .fontSize(12.5 * this.textScale)
                    .lineHeight(18 * this.textScale)
                    .fontWeight(item.status === 'in_progress' ? FontWeight.Medium : FontWeight.Regular)
                    .fontColor(this.stepTextColor(item.status))
                    .decoration({
                      type: item.status === 'skipped' ? TextDecorationType.LineThrough : TextDecorationType.None,
                      color: Tokens.dim2
                    })
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')

                  if (item.detail !== undefined && item.detail.trim() !== '') {
                    Text(item.detail.trim())
                      .fontSize(11.5 * this.textScale)
                      .lineHeight(16 * this.textScale)
                      .fontColor(Tokens.dim2)
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (item: TaskStep, idx: number) =>
              item.id + '_' + item.status + '_' + item.title + '_' + String(idx))
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 9, bottom: 10 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .constraintSize({ maxHeight: 224 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
    .borderRadius(Tokens.rMd)
    .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
    .backgroundEffect(Mat.glassEffect(this.hdsOn, false))
    .border(Mat.glassRimBorder(this.hdsOn))
    .shadow(Mat.glassFloatShadow(this.hdsOn))
    .clip(true)
    .transition(Motion.panelTransition(this.motionMode))
  }
}
