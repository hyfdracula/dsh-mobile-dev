import { AskAnswer, AskOption, AskQuestion, PendingAsk } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 模型向用户提问的交互卡片（I4 / K4）：
 * - 支持多题步进与多选；
 * - 渲染 AskOption.description（12vp Tokens.dim2）；
 * - 提供「其他（自由填写回答）」展开输入框，支持随预设选项或单独提交。
 */
@Component
export struct AskQuestionCard {
  @Prop @Watch('onAskChanged') ask: PendingAsk = { callId: '', questions: [], state: '' };
  onSubmit: (callId: string, answers: AskAnswer[]) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private curIdx: number = 0;
  @State private selMap: Record<string, string[]> = {};
  @State private customMap: Record<string, string> = {};
  @State private customOpenMap: Record<string, boolean> = {};
  @State private submitting: boolean = false;
  private lastCallId: string = '';

  aboutToAppear(): void {
    this.lastCallId = this.ask.callId;
  }

  onAskChanged(): void {
    if (this.ask.callId !== this.lastCallId) {
      this.lastCallId = this.ask.callId;
      this.curIdx = 0;
      this.selMap = {};
      this.customMap = {};
      this.customOpenMap = {};
      this.submitting = false;
    }
  }

  private safeIdx(): number {
    const n: number = this.ask.questions.length;
    if (n <= 1) {
      return 0;
    }
    if (this.curIdx < 0) {
      return 0;
    }
    return this.curIdx >= n ? n - 1 : this.curIdx;
  }

  private qKey(q: AskQuestion, idx: number): string {
    return q.id !== '' ? q.id : ('__q_' + String(idx));
  }

  private curQuestion(): AskQuestion {
    return this.ask.questions[this.safeIdx()];
  }

  private curKey(): string {
    const idx: number = this.safeIdx();
    return this.qKey(this.ask.questions[idx], idx);
  }

  private goIdx(nextIdx: number): void {
    const n: number = this.ask.questions.length;
    if (n <= 1) {
      this.curIdx = 0;
      return;
    }
    let j: number = nextIdx;
    if (j < 0) {
      j = 0;
    }
    if (j > n - 1) {
      j = n - 1;
    }
    this.curIdx = j;
  }

  private pickedOf(qid: string): string[] {
    const hit: string[] | undefined = this.selMap[qid];
    return hit === undefined ? [] : hit;
  }

  private customOf(qid: string): string {
    const hit: string | undefined = this.customMap[qid];
    return hit === undefined ? '' : hit;
  }

  private isCustomOpen(qid: string): boolean {
    return this.customOpenMap[qid] === true;
  }

  private setPicked(qid: string, list: string[]): void {
    const next: Record<string, string[]> = {};
    const keys: string[] = Object.keys(this.selMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.selMap[keys[i]];
    }
    next[qid] = list;
    this.selMap = next;
  }

  private setCustom(qid: string, val: string): void {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.customMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.customMap[keys[i]];
    }
    next[qid] = val;
    this.customMap = next;
  }

  private toggleCustomOpen(qid: string): void {
    const next: Record<string, boolean> = {};
    const keys: string[] = Object.keys(this.customOpenMap);
    for (let i = 0; i < keys.length; i++) {
      next[keys[i]] = this.customOpenMap[keys[i]];
    }
    next[qid] = !this.isCustomOpen(qid);
    this.getUIContext().animateTo(Motion.baseElastic(), () => {
      this.customOpenMap = next;
    });
  }

  private isAnsweredKey(key: string): boolean {
    return this.pickedOf(key).length > 0 || this.customOf(key).trim() !== '';
  }

  private isAnsweredAt(idx: number): boolean {
    if (idx < 0 || idx >= this.ask.questions.length) {
      return false;
    }
    return this.isAnsweredKey(this.qKey(this.ask.questions[idx], idx));
  }

  private doneCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.ask.questions.length; i++) {
      if (this.isAnsweredAt(i)) {
        n++;
      }
    }
    return n;
  }

  private tapOption(q: AskQuestion, qIdx: number, label: string): void {
    Haptics.tap();
    const key: string = this.qKey(q, qIdx);
    const cur: string[] = this.pickedOf(key);
    if (q.multiSelect === true) {
      const next: string[] = cur.indexOf(label) >= 0
        ? cur.filter((x: string) => x !== label)
        : cur.concat([label]);
      this.setPicked(key, next);
      return;
    }
    // 单选：若用户已展开自定义输入且已有选中同项，允许再次点击取消该预设项以便纯自定义回答
    if ((this.isCustomOpen(key) || this.customOf(key).trim() !== '') && cur.indexOf(label) >= 0) {
      this.setPicked(key, []);
      return;
    }
    this.setPicked(key, [label]);
    if (this.isCustomOpen(key) || this.customOf(key).trim() !== '') {
      return;
    }
    if (this.ask.questions.length === 1) {
      this.fireSubmit();
      return;
    }
    if (qIdx < this.ask.questions.length - 1) {
      this.goIdx(qIdx + 1);
    }
  }

  private fireSubmit(): void {
    if (this.submitting) {
      return;
    }
    const answers: AskAnswer[] = [];
    for (let i = 0; i < this.ask.questions.length; i++) {
      const one: AskQuestion = this.ask.questions[i];
      const key: string = this.qKey(one, i);
      const picked: string[] = this.pickedOf(key);
      const custom: string = this.customOf(key).trim();
      if (picked.length === 0 && custom === '') {
        return;
      }
      const ansId: string = one.id !== '' ? one.id : ('q_' + String(i + 1));
      const ans: AskAnswer = { id: ansId, selected: picked };
      if (custom !== '') {
        ans.custom = custom;
      }
      answers.push(ans);
    }
    if (answers.length === 0) {
      return;
    }
    this.submitting = true;
    this.onSubmit(this.ask.callId, answers);
  }

  private needFooter(): boolean {
    const q: AskQuestion = this.curQuestion();
    const key: string = this.curKey();
    const opts: AskOption[] = q.options === undefined ? [] : q.options;
    return this.ask.questions.length > 1
      || q.multiSelect === true
      || opts.length === 0
      || this.isCustomOpen(key)
      || this.customOf(key).trim() !== '';
  }

  private tabTitleOf(item: AskQuestion, qIdx: number): string {
    const prefix: string = String(qIdx + 1) + '. ';
    const hdr: string = item.header !== undefined ? item.header.trim() : '';
    if (hdr === '') {
      return '第 ' + String(qIdx + 1) + ' 题';
    }
    return hdr.length > 8 ? (prefix + hdr.slice(0, 8) + '…') : (prefix + hdr);
  }

  build() {
    if (this.ask.questions.length > 0) {
      Column({ space: 8 }) {
        // 顶部固定题号与切换胶囊栏
        Row() {
          Text(this.curQuestion().header === undefined || this.curQuestion().header === ''
            ? '等待你的操作'
            : this.curQuestion().header!)
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.accent)
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.ask.questions.length > 1
            ? ('第 ' + String(this.safeIdx() + 1) + ' / ' + String(this.ask.questions.length) + ' 题')
            : (this.curQuestion().multiSelect === true ? '可多选' : '请选择'))
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .margin({ left: 8 })
        }
        .width('100%')

        if (this.ask.questions.length > 1) {
          Row() {
            Row()
              .width(String(Math.round(((this.safeIdx() + 1) * 100) / this.ask.questions.length)) + '%')
              .height(2.5)
              .borderRadius(Tokens.rXs)
              .backgroundColor(Tokens.accent)
          }
          .width('100%')
          .height(2.5)
          .borderRadius(Tokens.rXs)
          .backgroundColor(Tokens.surface3)

          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.ask.questions, (item: AskQuestion, qIdx: number) => {
                Row({ space: 4 }) {
                  if (this.isAnsweredAt(qIdx)) {
                    Row()
                      .width(6)
                      .height(6)
                      .borderRadius(Tokens.rPill)
                      .backgroundColor(qIdx === this.safeIdx() ? Tokens.accentInk : Tokens.accent)
                  }
                  Text(this.tabTitleOf(item, qIdx))
                    .fontSize(Tokens.fsCaption)
                    .fontWeight(qIdx === this.safeIdx() ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(qIdx === this.safeIdx()
                      ? Tokens.accentInk
                      : (this.isAnsweredAt(qIdx) ? Tokens.accent : Tokens.dim))
                }
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(qIdx === this.safeIdx() ? Tokens.accent : Tokens.surface3)
                .border({
                  width: qIdx !== this.safeIdx() && this.isAnsweredAt(qIdx) ? 1 : 0,
                  color: Tokens.accent
                })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
                .onClick(() => {
                  Haptics.tap();
                  this.goIdx(qIdx);
                })
              }, (item: AskQuestion, qIdx: number) => this.ask.callId + '_tab_' + String(qIdx) + '_' + item.id)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        // 中部可滚动题目正文与选项（使用 qIdx === safeIdx() 的变化键确保切题后完整重绘新题内容）
        Scroll() {
          Column({ space: 8 }) {
            ForEach(this.ask.questions, (q: AskQuestion, qIdx: number) => {
              if (qIdx === this.safeIdx()) {
                Column({ space: 8 }) {
                  if (q.prompt !== undefined && q.prompt !== '') {
                    Text(q.prompt)
                      .fontSize(Tokens.fsBody)
                      .fontColor(Tokens.fg)
                      .lineHeight(19)
                      .width('100%')
                  }

                  if (q.detail !== undefined && q.detail !== '') {
                    Text(q.detail)
                      .fontSize(Tokens.fsFoot)
                      .fontColor(Tokens.dim)
                      .lineHeight(18)
                      .width('100%')
                  }

                  // 预设选项（含 AskOption.description 说明）
                  ForEach(q.options === undefined ? [] : q.options, (o: AskOption, optIdx: number) => {
                    Row() {
                      Column({ space: 3 }) {
                        Text(o.label)
                          .fontSize(Tokens.fsBody)
                          .fontColor(this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? Tokens.fg : Tokens.accent)
                          .fontWeight(this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? FontWeight.Medium : FontWeight.Normal)
                        if (o.description !== undefined && o.description.trim() !== '') {
                          Text(o.description.trim())
                            .fontSize(12)
                            .lineHeight(17)
                            .fontColor(Tokens.dim2)
                        }
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)

                      Text(this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? '已选' : '›')
                        .fontSize(Tokens.fsFoot)
                        .fontColor(this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? Tokens.accent : Tokens.dim2)
                        .margin({ left: 8 })
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                    .borderRadius(Tokens.rMd)
                    .backgroundColor(this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? Tokens.surface : Tokens.surface3)
                    .border({
                      width: this.pickedOf(this.qKey(q, qIdx)).indexOf(o.label) >= 0 ? 1 : 0,
                      color: Tokens.accent
                    })
                    .alignItems(VerticalAlign.Center)
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
                    .onClick(() => {
                      this.tapOption(q, qIdx, o.label);
                    })
                  }, (o: AskOption, optIdx: number) => this.ask.callId + '_' + String(qIdx) + '_' + String(optIdx) + '_' + o.label)

                  // 其他（自由填写回答）开关与展开输入框
                  Column({ space: 8 }) {
                    Row() {
                      Text('其他（自由填写回答）')
                        .fontSize(Tokens.fsBody)
                        .fontColor(this.customOf(this.qKey(q, qIdx)).trim() !== '' ? Tokens.fg : Tokens.dim)
                        .fontWeight(this.customOf(this.qKey(q, qIdx)).trim() !== '' ? FontWeight.Medium : FontWeight.Normal)
                        .layoutWeight(1)
                      Text(this.isCustomOpen(this.qKey(q, qIdx)) ? '收起' : (this.customOf(this.qKey(q, qIdx)).trim() !== '' ? '已填' : '展开'))
                        .fontSize(Tokens.fsFoot)
                        .fontColor(this.customOf(this.qKey(q, qIdx)).trim() !== '' || this.isCustomOpen(this.qKey(q, qIdx)) ? Tokens.accent : Tokens.dim2)
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
                    .borderRadius(Tokens.rMd)
                    .backgroundColor(this.customOf(this.qKey(q, qIdx)).trim() !== '' ? Tokens.surface : Tokens.surface3)
                    .border({
                      width: this.customOf(this.qKey(q, qIdx)).trim() !== '' || this.isCustomOpen(this.qKey(q, qIdx)) ? 1 : 0,
                      color: Tokens.accent
                    })
                    .alignItems(VerticalAlign.Center)
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
                    .onClick(() => {
                      Haptics.tap();
                      this.toggleCustomOpen(this.qKey(q, qIdx));
                    })

                    if (this.isCustomOpen(this.qKey(q, qIdx))) {
                      TextArea({
                        text: this.customOf(this.qKey(q, qIdx)),
                        placeholder: '输入补充想法或自定义回答…'
                      })
                        .fontSize(Tokens.fsBody)
                        .fontColor(Tokens.fg)
                        .placeholderColor(Tokens.dim2)
                        .backgroundColor(Tokens.surface2)
                        .borderRadius(Tokens.rMd)
                        .border({ width: 1, color: Tokens.line })
                        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
                        .constraintSize({ minHeight: 42, maxHeight: 96 })
                        .width('100%')
                        .onChange((v: string) => {
                          this.setCustom(this.qKey(q, qIdx), v);
                        })
                    }
                  }
                  .width('100%')
                }
                .width('100%')
              }
            }, (q: AskQuestion, qIdx: number) => this.ask.callId + '_q_' + String(qIdx) + '_' + q.id + '_' +
              (qIdx === this.safeIdx() ? 'on' : 'off'))
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 300 })
        .scrollBar(BarState.Auto)

        // 底部固定翻题 / 提交栏
        if (this.needFooter()) {
          Row() {
            Text(this.doneCount() < this.ask.questions.length
              ? ('还差 ' + String(this.ask.questions.length - this.doneCount()) + ' 题')
              : '已填好，可提交回答')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
              .layoutWeight(1)

            if (this.ask.questions.length > 1 && this.safeIdx() > 0) {
              Text('上一题')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.dim)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface3)
                .margin({ right: 8 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.goIdx(this.safeIdx() - 1);
                })
            }

            if (this.ask.questions.length > 1 && this.safeIdx() < this.ask.questions.length - 1) {
              Text('下一题')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isAnsweredAt(this.safeIdx()) ? Tokens.accentInk : Tokens.fg)
                .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(this.isAnsweredAt(this.safeIdx()) ? Tokens.accent : Tokens.surface3)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.goIdx(this.safeIdx() + 1);
                })
            }

            if (this.safeIdx() >= this.ask.questions.length - 1 || this.doneCount() >= this.ask.questions.length) {
              Text(this.submitting ? '提交中…' : '提交')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(!this.submitting && this.doneCount() >= this.ask.questions.length ? Tokens.accentInk : Tokens.dim2)
                .padding({ left: 16, right: 16, top: 6, bottom: 6 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(!this.submitting && this.doneCount() >= this.ask.questions.length ? Tokens.accent : Tokens.surface3)
                .margin({ left: this.ask.questions.length > 1 && this.safeIdx() < this.ask.questions.length - 1 ? 8 : 0 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  if (!this.submitting && this.doneCount() >= this.ask.questions.length) {
                    Haptics.tap();
                    this.fireSubmit();
                  }
                })
            }
          }
          .width('100%')
          .margin({ top: 2 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .padding(12)
      .margin({ bottom: 8 })
      .borderRadius(Tokens.rCard)
      .backgroundColor(Mat.drawerBg(this.hdsOn))
      .backdropBlur(Mat.drawerBlur(this.hdsOn))
      .systemMaterial(Mat.drawer(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .transition(
        TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
          .combine(TransitionEffect.translate({ y: 8 }).animation(Motion.baseElastic()))
      )
    }
  }
}
