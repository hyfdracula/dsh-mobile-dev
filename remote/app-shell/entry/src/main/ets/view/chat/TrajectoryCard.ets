import { ToolStep } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 可折叠「思考过程」与「工具步骤」轨迹卡（G4）：
 * 默认折叠为紧凑胶囊，不侵占正文阅读高度；包含运行中工具时展示微动指示；
 * 点击展开查看浅色斜体思考摘要与每一步工具调用状态（ok 绿 / run 蓝 / err 红）。
 */
@Component
export struct TrajectoryCard {
  @Prop thinking: string = '';
  @Prop tools: ToolStep[] = [];
  @StorageLink('textScale') textScale: number = 1;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @State private expanded: boolean = false;
  @State private chevronTrigger: number = -1;

  private hasThinking(): boolean {
    return this.thinking.trim() !== '';
  }

  private hasRunningTool(): boolean {
    for (let i = 0; i < this.tools.length; i++) {
      if (this.tools[i].status === 'run') {
        return true;
      }
    }
    return false;
  }

  private hasErrTool(): boolean {
    for (let i = 0; i < this.tools.length; i++) {
      if (this.tools[i].status === 'err') {
        return true;
      }
    }
    return false;
  }

  private headerLabel(): string {
    const think: boolean = this.hasThinking();
    const count: number = this.tools.length;
    const runningSuffix: string = this.hasRunningTool() ? ' · 执行中' : '';
    if (think && count > 0) {
      return '思考过程 · ' + String(count) + ' 个工具步骤' + runningSuffix;
    }
    if (think) {
      return '思考过程' + runningSuffix;
    }
    return String(count) + ' 个工具步骤' + runningSuffix;
  }

  private headerDotColor(): string {
    if (this.hasErrTool()) {
      return Tokens.err;
    }
    if (this.tools.length > 0) {
      return Tokens.ok;
    }
    return Tokens.accent;
  }

  private stepColor(status: string): string {
    if (status === 'ok') {
      return Tokens.ok;
    }
    if (status === 'run') {
      return Tokens.accent;
    }
    if (status === 'err') {
      return Tokens.err;
    }
    return Tokens.dim2;
  }

  build() {
    Column() {
      // 顶栏胶囊行
      Row() {
        if (this.hasRunningTool()) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Tokens.accent)
            .margin({ right: 7 })
        } else {
          Circle()
            .width(6)
            .height(6)
            .fill(this.headerDotColor())
            .margin({ right: 8 })
        }

        Text(this.headerLabel())
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.dim)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (Motion.isVivid(this.motionMode)) {
          SymbolGlyph(this.expanded ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right'))
            .fontSize(13)
            .fontColor([Tokens.dim2])
            .symbolEffect(Motion.replaceEffect(), this.chevronTrigger)
            .margin({ left: 6 })
        } else {
          Text('›')
            .fontSize(15)
            .fontColor(Tokens.dim2)
            .rotate({ angle: this.expanded ? 90 : 0 })
            .animation({ duration: Motion.move, curve: Motion.std })
            .margin({ left: 6 })
        }
      }
      .width('100%')
      .padding({ left: 11, right: 11, top: 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        Haptics.tap();
        if (Motion.isVivid(this.motionMode)) {
          this.chevronTrigger += 1;
        }
        this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
          this.expanded = !this.expanded;
        });
      })

      // 展开内容：思考摘要 + 工具调用列表
      if (this.expanded) {
        Column({ space: 8 }) {
          if (this.hasThinking()) {
            Row() {
              Text(this.thinking.trim())
                .fontSize(12.5 * this.textScale)
                .lineHeight(19 * this.textScale)
                .fontColor(Tokens.dim)
                .fontStyle(FontStyle.Italic)
                .layoutWeight(1)
                .copyOption(CopyOptions.LocalDevice)
            }
            .width('100%')
            .padding({ left: 9, top: 2, bottom: 2 })
            .border({ width: { left: 2 }, color: Tokens.line })
            .alignItems(VerticalAlign.Top)
          }

          if (this.tools.length > 0) {
            Column({ space: 6 }) {
              ForEach(this.tools, (step: ToolStep, idx: number) => {
                Row() {
                  Circle()
                    .width(6)
                    .height(6)
                    .fill(this.stepColor(step.status))
                    .margin({ top: 6, right: 8 })

                  Column({ space: 2 }) {
                    Text(step.name !== '' ? step.name : 'tool')
                      .fontSize(12 * this.textScale)
                      .fontFamily('monospace')
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tokens.fg)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (step.summary !== '') {
                      Text(step.summary)
                        .fontSize(11.5 * this.textScale)
                        .lineHeight(17 * this.textScale)
                        .fontColor(Tokens.dim2)
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
              }, (step: ToolStep, idx: number) =>
                step.id + '_' + step.status + '_' + String(step.summary.length) + '_' + String(idx))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .padding({ left: 11, right: 11, top: 2, bottom: 10 })
        .border({ width: { top: 0.5 }, color: Tokens.lineSoft })
        .alignItems(HorizontalAlign.Start)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }
    }
    .width('100%')
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rMd)
    .border({ width: 0.5, color: Tokens.lineSoft })
    .clip(true)
  }
}
