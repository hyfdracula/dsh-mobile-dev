import { GoalView } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

interface RoundChoice {
  label: string;
  value: number;
}

const ROUND_CHOICES: RoundChoice[] = [
  { label: '默认', value: 0 },
  { label: '5 轮', value: 5 },
  { label: '10 轮', value: 10 },
  { label: '20 轮', value: 20 }
];

/**
 * 长程目标新建、查看、编辑与状态控制半模态面板（F09）：
 * - 无目标时支持直接填写目标描述与可选最大轮数，调用 api.goalCreate 创建；
 * - 有目标时支持编辑、暂停、继续、完成与清除；
 * - 配合 SheetSize.FIT_CONTENT 与 kbH 动态避让，键盘绝不遮挡操作区。
 */
@Component
export struct GoalSheet {
  @Prop hasGoal: boolean = false;
  @Prop goal: GoalView = {};
  @Prop busy: boolean = false;
  @Prop kbH: number = 0;
  onCreate: (objective: string, maxRounds: number) => Promise<boolean> = async () => false;
  onAction: (action: string) => void = () => {};
  onSaveEdit: (objective: string) => Promise<boolean> = async () => false;
  onClose: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private editing: boolean = false;
  @State private draft: string = '';
  @State private createDraft: string = '';
  @State private maxRounds: number = 0;
  @State private submitting: boolean = false;

  private phaseText(): string {
    const ph: string = this.goal.phase === undefined ? '' : this.goal.phase;
    if (ph === 'active') return '进行中';
    if (ph === 'paused') return '已暂停';
    if (ph === 'complete' || ph === 'completed') return '已完成';
    if (ph === 'blocked') return '被阻塞';
    return ph === '' ? '进行中' : ph;
  }

  private phaseColor(): string {
    const ph: string = this.goal.phase === undefined ? '' : this.goal.phase;
    if (ph === 'complete' || ph === 'completed') return Tokens.ok;
    if (ph === 'blocked') return Tokens.err;
    if (ph === 'paused') return Tokens.intrInk;
    return Tokens.accent;
  }

  private isTerminalPhase(): boolean {
    const ph: string = this.goal.phase === undefined ? '' : this.goal.phase;
    return ph === 'complete' || ph === 'completed';
  }

  @Builder
  private actionChip(label: string, action: string, strong: boolean) {
    Text(label)
      .fontSize(Tokens.fsBody)
      .fontWeight(FontWeight.Medium)
      .fontColor(strong ? Tokens.accentInk : Tokens.fg)
      .textAlign(TextAlign.Center)
      .padding({ left: 16, right: 16, top: 9, bottom: 9 })
      .borderRadius(Tokens.rPill)
      .backgroundColor(strong ? Tokens.accent : Tokens.surface2)
      .opacity(this.busy ? 0.5 : 1)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        if (this.busy) {
          return;
        }
        Haptics.tap();
        this.editing = false;
        this.onAction(action);
      })
  }

  build() {
    Column() {
      Row() {
        Text('长期目标')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor(Tokens.dim)
            .objectFit(ImageFit.Contain)
        }
        .width(34)
        .height(34)
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.surface2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('关闭')
        .onClick(() => {
          Haptics.tap();
          this.editing = false;
          this.onClose();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 12 })

      if (!this.hasGoal) {
        Text('为当前会话设定一个长期目标，智能体将按多轮持续推进直至完成。')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .width('100%')
          .margin({ bottom: 12 })

        TextArea({ text: this.createDraft, placeholder: '描述你希望持续推进的目标内容…' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rMd)
          .border({ width: 0.5, color: Tokens.line })
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .constraintSize({ minHeight: 76, maxHeight: 136 })
          .width('100%')
          .onChange((v: string) => {
            this.createDraft = v;
          })

        Row({ space: 6 }) {
          Text('最大轮数')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .margin({ right: 4 })
          ForEach(ROUND_CHOICES, (rc: RoundChoice) => {
            Text(rc.label)
              .fontSize(Tokens.fsCaption)
              .fontWeight(this.maxRounds === rc.value ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.maxRounds === rc.value ? Tokens.accentInk : Tokens.dim)
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.maxRounds === rc.value ? Tokens.accent : Tokens.surface2)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                this.maxRounds = rc.value;
              })
          }, (rc: RoundChoice) => String(rc.value) + '_' + (this.maxRounds === rc.value ? '1' : '0'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 12 })

        Row() {
          Blank()
          Text(this.busy || this.submitting ? '创建中…' : '创建目标')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.createDraft.trim() === '' || this.busy || this.submitting ? Tokens.dim2 : Tokens.accentInk)
            .padding({ left: 20, right: 20, top: 10, bottom: 10 })
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.createDraft.trim() === '' || this.busy || this.submitting ? Tokens.surface2 : Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              const trimmed: string = this.createDraft.trim();
              if (trimmed === '' || this.busy || this.submitting) {
                return;
              }
              Haptics.tap();
              this.submitting = true;
              this.onCreate(trimmed, this.maxRounds).then((ok: boolean) => {
                if (ok) {
                  this.createDraft = '';
                }
              }).finally(() => {
                this.submitting = false;
              });
            })
        }
        .width('100%')
        .margin({ top: 14 })
      } else {
        Column({ space: 10 }) {
          Text(this.goal.objective === undefined ? '' : this.goal.objective)
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
            .lineHeight(23)
            .width('100%')

          Row({ space: 8 }) {
            Text(this.phaseText())
              .fontSize(Tokens.fsCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.phaseColor())
              .padding({ left: 9, right: 9, top: 4, bottom: 4 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.accentSoft)
            Text('第 ' + String(this.goal.roundsStarted === undefined ? 0 : this.goal.roundsStarted) +
              ' / ' + String(this.goal.maxGoalRounds === undefined ? 0 : this.goal.maxGoalRounds) + ' 轮')
              .fontSize(Tokens.fsCaption)
              .fontFamily('monospace')
              .fontColor(Tokens.dim2)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding(14)
        .borderRadius(Tokens.rCard)
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .alignItems(HorizontalAlign.Start)

        if (this.editing) {
          TextArea({ text: this.draft, placeholder: '目标内容' })
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .placeholderColor(Tokens.dim2)
            .backgroundColor(Mat.subCardBg(this.hdsOn))
            .borderRadius(Tokens.rMd)
            .border(Mat.subCardBorder(this.hdsOn))
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .constraintSize({ minHeight: 56, maxHeight: 120 })
            .width('100%')
            .margin({ top: 12 })
            .onChange((v: string) => {
              this.draft = v;
            })

          Row({ space: 10 }) {
            Blank()
            Text('取消')
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.dim)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface2)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                this.getUIContext().animateTo({ duration: Motion.move, curve: Motion.std }, () => {
                  this.editing = false;
                });
              })
            Text(this.busy || this.submitting ? '保存中…' : '保存')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.draft.trim() === '' || this.busy || this.submitting ? Tokens.dim2 : Tokens.accentInk)
              .padding({ left: 18, right: 18, top: 9, bottom: 9 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.draft.trim() === '' || this.busy || this.submitting ? Tokens.surface2 : Tokens.accent)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                const trimmed: string = this.draft.trim();
                if (trimmed === '' || this.busy || this.submitting) {
                  return;
                }
                Haptics.tap();
                this.submitting = true;
                this.onSaveEdit(trimmed).then((ok: boolean) => {
                  if (ok) {
                    this.editing = false;
                  }
                }).finally(() => {
                  this.submitting = false;
                });
              })
          }
          .width('100%')
          .margin({ top: 12 })
        } else {
          Row({ space: 8 }) {
            if (this.goal.phase === 'active') {
              this.actionChip('暂停', 'pause', false)
            }
            if (this.goal.phase === 'paused') {
              this.actionChip('继续', 'resume', true)
            }
            if (!this.isTerminalPhase()) {
              this.actionChip('完成', 'complete', false)
            }
            Text('编辑')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.fg)
              .padding({ left: 16, right: 16, top: 9, bottom: 9 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.surface2)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Haptics.tap();
                this.draft = this.goal.objective === undefined ? '' : this.goal.objective;
                this.getUIContext().animateTo({ duration: Motion.move, curve: Motion.std }, () => {
                  this.editing = true;
                });
              })
            Blank()
            Text('清除')
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.err)
              .padding({ left: 8, right: 4, top: 9, bottom: 9 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                if (this.busy) {
                  return;
                }
                Haptics.tap();
                this.onAction('clear');
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 200 })
    .padding({
      left: 20,
      right: 20,
      top: 10,
      bottom: this.kbH > 0 ? this.kbH + 16 : this.bottomInset + 20
    })
    .alignItems(HorizontalAlign.Start)
  }
}
