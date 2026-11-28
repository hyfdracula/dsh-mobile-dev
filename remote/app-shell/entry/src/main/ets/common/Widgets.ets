import { CardIcon } from './CardIcon';
import { Haptics } from './Haptics';
import { Mat } from './Mat';
import { Motion } from './Motion';
import { Tokens } from './Tokens';

/**
 * 设置里最常见的「图标 + 标题 + 说明 + 开关」一行。
 */
@Component
export struct RowSwitch {
  title: string = '';
  hint: string = '';
  @Prop value: boolean = false;
  @Prop switchEnabled: boolean = true;
  @Prop showIcon: boolean = false;
  iconSymbol: Resource = $r('sys.symbol.info_circle');
  @Prop iconTone: string = 'blue';
  @Prop entered: boolean = true;
  @Prop distanceVp: number = 0;
  @Prop baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY;
  onChanged: (v: boolean) => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Row() {
      if (this.showIcon) {
        CardIcon({
          symbol: this.iconSymbol,
          tone: this.iconTone,
          entered: this.entered,
          distanceVp: this.distanceVp,
          baseDelay: this.baseDelay
        })
        .margin({ right: 12 })
      }
      Column() {
        Text(this.title)
          .fontSize(Tokens.fsBodyLg)
          .fontColor(this.switchEnabled ? Tokens.fg : Tokens.dim2)
          .width('100%')
        if (this.hint !== '') {
          Text(this.hint)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(17)
            .maxLines(2)
            .width('100%')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 12 })
      Toggle({ type: ToggleType.Switch, isOn: this.value })
        .enabled(this.switchEnabled)
        .selectedColor(Tokens.accent)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onChange((v: boolean) => {
          if (this.switchEnabled) {
            if (v !== this.value) {
              Haptics.toggle(v);
            }
            this.onChanged(v);
          }
        })
    }
    .width('100%')
    .opacity(this.switchEnabled ? 1 : 0.52)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 统一空态：图标 + 一句标题 + 可选说明 + 可选动作。
 */
@Component
export struct EmptyState {
  icon: Resource = $r('app.media.ic_chat');
  title: string = '';
  hint: string = '';
  action: string = '';
  onAction: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      Image(this.icon)
        .width(44)
        .height(44)
        .fillColor(Tokens.dim2)
        .objectFit(ImageFit.Contain)
      Text(this.title)
        .fontSize(Tokens.fsBodyLg)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ top: 12 })
        .textAlign(TextAlign.Center)
      if (this.hint !== '') {
        Text(this.hint)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
      }
      if (this.action !== '') {
        Text(this.action)
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .margin({ top: 14 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 72, bottom: 40 })
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 标题 + 圆圈感叹号提示组件：点按弹出玻璃浮层解释，替代各面板散落的手写实现。
 */
@Component
export struct HintLabel {
  @Prop title: string = '';
  @Prop tipText: string = '';
  @Prop dim: boolean = false;
  @State private open: boolean = false;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @Builder
  private popupCard() {
    Text(this.tipText)
      .fontSize(Tokens.fsFoot)
      .lineHeight(18)
      .fontColor(Tokens.fg)
      .width(240)
      .padding(12)
      .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
      .borderRadius(Tokens.rMd)
      .border(this.hdsOn
        ? { width: 1, color: Mat.floatBorderColor(true) }
        : { width: 1, color: Tokens.line })
  }

  build() {
    Row() {
      if (this.title !== '') {
        Text(this.title)
          .fontSize(Tokens.fsBody)
          .fontColor(this.dim ? Tokens.dim : Tokens.fg)
      }
      Text('!')
        .fontSize(Tokens.fsCaption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.dim2)
        .textAlign(TextAlign.Center)
        .width(15)
        .height(15)
        .borderRadius(Tokens.rPill)
        .border({ width: 1, color: this.themeDark ? '#59FFFFFF' : '#33000000' })
        .margin({ left: this.title !== '' ? 6 : 0 })
        .bindPopup(this.open, Mat.popupOpts(
          this.hdsOn,
          (): void => { this.popupCard(); },
          Placement.Bottom,
          { x: 0, y: 4 },
          (vis: boolean): void => {
            if (!vis && this.open) {
              this.open = false;
            }
          },
          14
        ))
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText((this.title !== '' ? this.title + ' ' : '') + '说明')
        .onClick(() => {
          Haptics.tap();
          this.open = !this.open;
        })
    }
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 分阶段可视化连接进度卡片（R3）：
 * 展示阶段勾号/加载圈、已耗时秒表、当前阶段详情与失败错误态，支持取消。
 */
@Component
export struct ConnectionStageCard {
  @Prop stages: string[] = [];
  @Prop currentStage: number = 0;
  @Prop elapsedSec: number = 0;
  @Prop detail: string = '';
  @Prop errorText: string = '';
  onCancel?: () => void;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private elapsedLabel(): string {
    if (this.elapsedSec <= 0) {
      return '0.0s';
    }
    return Number.isInteger(this.elapsedSec)
      ? this.elapsedSec.toFixed(1) + 's'
      : this.elapsedSec.toFixed(1) + 's';
  }

  private stageTextColor(idx: number): string {
    if (idx < this.currentStage) {
      return Tokens.fg;
    }
    if (idx === this.currentStage) {
      return this.errorText !== '' ? Tokens.err : Tokens.fg;
    }
    return Tokens.dim2;
  }

  build() {
    Column() {
      Row() {
        Text(this.errorText !== '' ? '连接未成功' : '正在连接电脑')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.errorText !== '' ? Tokens.err : Tokens.fg)
          .layoutWeight(1)
        Text(this.elapsedLabel())
          .fontSize(Tokens.fsCaption)
          .fontFamily('monospace')
          .fontColor(this.errorText !== '' ? Tokens.err : Tokens.runInk)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(this.errorText !== '' ? Tokens.intrBg : Tokens.runBg)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 8 }) {
        ForEach(this.stages, (label: string, idx: number) => {
          Row() {
            if (idx < this.currentStage) {
              Stack({ alignContent: Alignment.Center }) {
                Text('√')
                  .fontSize(11)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.doneInk)
              }
              .width(18)
              .height(18)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.doneBg)
            } else if (idx === this.currentStage && this.errorText !== '') {
              Stack({ alignContent: Alignment.Center }) {
                Text('×')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.err)
              }
              .width(18)
              .height(18)
              .borderRadius(Tokens.rPill)
              .border({ width: 1, color: Tokens.err })
            } else if (idx === this.currentStage) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color(Tokens.accent)
            } else {
              Stack({ alignContent: Alignment.Center }) {
                Row()
                  .width(6)
                  .height(6)
                  .borderRadius(Tokens.rPill)
                  .backgroundColor(Tokens.line)
              }
              .width(18)
              .height(18)
            }

            Text(label)
              .fontSize(Tokens.fsBody)
              .fontWeight(idx === this.currentStage ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.stageTextColor(idx))
              .margin({ left: 10 })
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }, (label: string, idx: number) => String(idx) + '-' + label)
      }
      .width('100%')
      .margin({ top: 12 })
      .alignItems(HorizontalAlign.Start)

      if (this.detail !== '') {
        Text(this.detail)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(17)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 10 })
      }

      if (this.errorText !== '') {
        Text(this.errorText)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.err)
          .lineHeight(18)
          .width('100%')
          .padding(10)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rSm)
          .margin({ top: 10 })
      }

      if (this.onCancel !== undefined) {
        Row() {
          Blank()
          Text('取消')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.surface2)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              if (this.onCancel !== undefined) {
                this.onCancel();
              }
            })
        }
        .width('100%')
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rCard)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 统一半屏弹窗顶部标题栏：左标题（+可选副标题），右轻量关闭按钮。
 */
@Component
export struct SheetHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  onClose: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Stack({ alignContent: Alignment.Center }) {
        Text('×')
          .fontSize(18)
          .fontColor(Tokens.dim)
      }
      .width(32)
      .height(32)
      .borderRadius(Tokens.rPill)
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .border(Mat.subCardBorder(this.hdsOn))
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .accessibilityText('关闭')
      .onClick(() => {
        Haptics.tap();
        this.onClose();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 统一弹窗底部双按钮行（取消 + 确认），防并发重复点击。
 */
@Component
export struct SheetActions {
  @Prop cancelText: string = '取消';
  @Prop confirmText: string = '确定';
  @Prop busy: boolean = false;
  @Prop destructive: boolean = false;
  onCancel: () => void = () => {};
  onConfirm: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Row({ space: 10 }) {
      Text(this.cancelText)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .padding({ top: 11, bottom: 11 })
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .borderRadius(Tokens.rInput)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          if (this.busy) {
            return;
          }
          Haptics.tap();
          this.onCancel();
        })

      Row({ space: 6 }) {
        if (this.busy) {
          LoadingProgress().width(14).height(14).color(Tokens.accentInk)
        }
        Text(this.confirmText)
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)
      .padding({ top: 11, bottom: 11 })
      .backgroundColor(this.destructive ? Tokens.err : Tokens.accent)
      .borderRadius(Tokens.rInput)
      .opacity(this.busy ? 0.65 : 1)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(() => {
        if (this.busy) {
          return;
        }
        if (this.destructive) {
          Haptics.warn();
        } else {
          Haptics.confirm();
        }
        this.onConfirm();
      })
    }
    .width('100%')
  }
}
