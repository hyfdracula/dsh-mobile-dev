import { AgentRef } from '../../common/Api';
import { TopFade } from '../../common/Chrome';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';

/**
 * 聊天页顶栏胶囊控件、毛玻璃渐隐衬板、子智能体横条、计划模式提示条、
 * 空态欢迎面板、回到底部悬浮球、上下文进度胶囊（F07）与底部发送按钮组。
 */
@Component
export struct HeaderCirclePill {
  @Prop glyph: string = '';
  @Prop immersive: boolean = true;
  onTap: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private useImmersive(): boolean {
    return this.immersive && this.hdsOn && Mat.isImmersiveReady();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.glyph === 'back') {
        Image($r('app.media.ic_back'))
          .width(21)
          .height(21)
          .fillColor(Tokens.fg)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else if (this.glyph === 'stats') {
        Column({ space: 3 }) {
          Row().width(16).height(2.1).borderRadius(1).backgroundColor(Tokens.fg)
          Row().width(11).height(2.1).borderRadius(1).backgroundColor(Tokens.fg)
          Row().width(16).height(2.1).borderRadius(1).backgroundColor(Tokens.fg)
        }
        .alignItems(HorizontalAlign.Start)
      } else {
        Text(this.glyph)
          .fontSize(18)
          .fontWeight(this.glyph === '···' ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(Tokens.fg)
          .textAlign(TextAlign.Center)
      }
    }
    .width(46)
    .height(46)
    .borderRadius(Tokens.rPill)
    .backgroundColor(!this.hdsOn
      ? Tokens.surface
      : (this.useImmersive() ? Color.Transparent : (this.themeDark ? '#4D161C28' : '#59FFFFFF')))
    .backdropBlur(this.hdsOn && !this.useImmersive() ? 20 : 0)
    .systemMaterial(this.hdsOn ? (this.useImmersive() ? Mat.chatHeader(true) : Mat.empty()) : Mat.empty())
    .border({
      width: 1,
      color: !this.hdsOn ? Tokens.line : (this.themeDark ? '#4DFFFFFF' : '#A6FFFFFF')
    })
    .shadow(!this.hdsOn || this.useImmersive()
      ? { radius: 0, color: Color.Transparent }
      : { radius: 12, color: Tokens.accentGlow, offsetY: 2 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
    .onClick(() => {
      Haptics.tap();
      this.onTap();
    })
  }
}

@Component
export struct HeaderTitleCapsule {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  /** 'lan' | 'wan' | 'offline' */
  @Prop linkState: string = 'lan';
  @Prop immersive: boolean = true;
  onTap: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private useImmersive(): boolean {
    return this.immersive && this.hdsOn && Mat.isImmersiveReady();
  }

  private dotColor(): string {
    if (this.linkState === 'offline') {
      return Tokens.err;
    }
    if (this.linkState === 'lan') {
      return Tokens.ok;
    }
    return Tokens.accent;
  }

  build() {
    Column() {
      Text(this.title !== '' ? this.title : '会话')
        .fontSize(15.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(20)
      if (this.subtitle !== '') {
        Row({ space: 5 }) {
          Circle()
            .width(6)
            .height(6)
            .fill(this.dotColor())
          Text(this.subtitle)
            .fontSize(11.5)
            .fontColor(this.linkState === 'offline' ? Tokens.err : Tokens.dim)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(15)
        }
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .margin({ top: 1.5 })
      }
    }
    .width('100%')
    .height(46)
    .padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(!this.hdsOn
      ? Tokens.surface
      : (this.useImmersive() ? Color.Transparent : (this.themeDark ? '#4D161C28' : '#59FFFFFF')))
    .backdropBlur(this.hdsOn && !this.useImmersive() ? 20 : 0)
    .systemMaterial(this.hdsOn ? (this.useImmersive() ? Mat.chatHeader(true) : Mat.empty()) : Mat.empty())
    .borderRadius(Tokens.rPill)
    .border({
      width: 1,
      color: !this.hdsOn ? Tokens.line : (this.themeDark ? '#4DFFFFFF' : '#A6FFFFFF')
    })
    .shadow(!this.hdsOn || this.useImmersive()
      ? { radius: 0, color: Color.Transparent }
      : { radius: 12, color: Tokens.accentGlow, offsetY: 2 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      Haptics.tap();
      this.onTap();
    })
  }
}

@Component
export struct ChatTopBackdrop {
  @Prop immersive: boolean = true;
  @Prop topInset: number = 40;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      TopFade({ fadeHeight: this.hdsOn ? (this.topInset + 18) : (this.topInset + 70) })
    }
    .width('100%')
    .hitTestBehavior(HitTestMode.None)
    .position({ x: 0, y: 0 })
  }
}

@Component
export struct SubagentStrip {
  @Prop agents: AgentRef[] = [];
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Scroll() {
      Row() {
        Text('智能体').fontSize(Tokens.fsCaption).fontColor(Tokens.dim2).margin({ right: 8 })
        ForEach(this.agents, (a: AgentRef) => {
          Row() {
            Text(a.label)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (a.mode === 'continuable') {
              Text('·').fontSize(Tokens.fsFoot).fontColor(Tokens.accent).margin({ left: 3 })
            }
          }
          .constraintSize({ maxWidth: 168 })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .margin({ right: 6 })
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rPill)
        }, (a: AgentRef) => a.id)
      }
      .padding({ left: 14, right: 14, top: 6, bottom: 2 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }
}

/** 计划模式激活提示条（F09）：展示在输入框上方，可一键关闭退出计划模式。 */
@Component
export struct PlanModeBanner {
  @Prop busy: boolean = false;
  onClose: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  build() {
    Row({ space: 8 }) {
      Circle()
        .width(7)
        .height(7)
        .fill(Tokens.accent)
      Text('计划模式已开启 · 先规划后执行')
        .fontSize(Tokens.fsFoot)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.accent)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('×')
        .fontSize(15)
        .fontColor(Tokens.accent)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .borderRadius(Tokens.rPill)
        .opacity(this.busy ? 0.45 : 1)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('关闭计划模式')
        .onClick(() => {
          if (this.busy) {
            return;
          }
          Haptics.tap();
          this.onClose();
        })
    }
    .width('100%')
    .height(32)
    .padding({ left: 12, right: 6 })
    .margin({ bottom: 8 })
    .borderRadius(Tokens.rMd)
    .backgroundColor(this.hdsOn ? Tokens.accentSoft : Tokens.surface)
    .border({ width: this.hdsOn ? 0.5 : 1, color: this.hdsOn ? Tokens.accentGlass : Tokens.accent })
    .alignItems(VerticalAlign.Center)
    .transition(Motion.panelTransition(this.motionMode))
  }
}

@Component
export struct ScrollBottomFab {
  @Prop bottomOffset: number = 120;
  onTap: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @State private bounceTrigger: number = 0;

  build() {
    Stack() {
      if (Motion.isVivid(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor([Tokens.fg])
          .symbolEffect(Motion.bounceEffect(EffectDirection.DOWN), this.bounceTrigger)
      } else {
        Image($r('app.media.ic_down')).width(17).height(17).fillColor(Tokens.fg).draggable(false)
      }
    }
    .width(42)
    .height(42)
    .borderRadius(Tokens.rPill)
    .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
    .backgroundEffect(Mat.glassEffect(this.hdsOn, false))
    .border(Mat.glassRimBorder(this.hdsOn))
    .shadow(Mat.glassFloatShadow(this.hdsOn))
    .position({ right: 18, bottom: this.bottomOffset })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
    .transition(Motion.fabTransition(this.motionMode))
    .onClick(() => {
      Haptics.tap();
      this.bounceTrigger += 1;
      this.onTap();
    })
  }
}

@Component
export struct ChatEmptyWelcome {
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      Image($r('app.media.ic_chat'))
        .width(44)
        .height(44)
        .fillColor(Tokens.dim2)
        .objectFit(ImageFit.Contain)
      Text('开始对话')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.fg)
        .margin({ top: 12 })
      Text('在下面输入消息，或点 + 号添加文件、目标、计划与指令')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .margin({ top: 6 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 80, bottom: 40 })
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 紧凑上下文进度胶囊（F07）：
 * 左侧 15x15 细线空心圆环（环内绝不塞文字），右侧等宽百分比，按占用率自动分级变色，点击直达上下文统计面板。
 */
@Component
export struct ContextPill {
  @Prop hasCtx: boolean = false;
  @Prop pct: number = 0;
  onTap: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private clampedPct(): number {
    if (!this.hasCtx) {
      return 0;
    }
    if (this.pct < 0) return 0;
    if (this.pct > 100) return 100;
    return this.pct;
  }

  private ringColor(): string {
    if (!this.hasCtx) {
      return Tokens.dim2;
    }
    const p: number = this.clampedPct();
    if (p >= 90) {
      return Tokens.err;
    }
    if (p >= 75) {
      return Tokens.intrInk;
    }
    return Tokens.accent;
  }

  private labelColor(): string {
    if (!this.hasCtx) {
      return Tokens.dim2;
    }
    const p: number = this.clampedPct();
    if (p >= 90) {
      return Tokens.err;
    }
    if (p >= 75) {
      return Tokens.intrInk;
    }
    return Tokens.dim;
  }

  build() {
    Row({ space: 6 }) {
      Progress({
        value: this.clampedPct(),
        total: 100,
        type: ProgressType.Ring
      })
        .style({ strokeWidth: 2.2 })
        .color(this.ringColor())
        .backgroundColor(Tokens.surface3)
        .width(15)
        .height(15)

      if (this.hasCtx) {
        Row() {
          Text(String(this.clampedPct()))
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(this.labelColor())
            .contentTransition(Motion.numTransition(this.motionMode))
          Text('%')
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(this.labelColor())
        }
        .alignItems(VerticalAlign.Center)
      } else {
        Text('--')
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.labelColor())
      }
    }
    .height(28)
    .padding({ left: 8, right: 10 })
    .borderRadius(Tokens.rPill)
    .backgroundColor(Mat.subCardBg(this.hdsOn))
    .border(Mat.subCardBorder(this.hdsOn))
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .accessibilityText('上下文占用 ' + (this.hasCtx ? String(this.clampedPct()) + '%' : '暂无'))
    .onClick(() => {
      Haptics.tap();
      this.onTap();
    })
  }
}

@Component
export struct ComposerSendCluster {
  @Prop @Watch('onActionStateChange') running: boolean = false;
  @Prop @Watch('onActionStateChange') sending: boolean = false;
  @Prop hasContent: boolean = false;
  @Prop @Watch('onAttachStateChange') attachOn: boolean = false;
  onToggleAttach: () => void = () => {};
  onSendNormal: () => void = () => {};
  onSendQueue: () => void = () => {};
  onSendSteer: () => void = () => {};
  onStop: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @State private attachTrigger: number = -1;
  @State private actionTrigger: number = -1;

  private onAttachStateChange(): void {
    if (Motion.isVivid(this.motionMode)) {
      this.attachTrigger += 1;
    }
  }

  private onActionStateChange(): void {
    if (Motion.isVivid(this.motionMode)) {
      this.actionTrigger += 1;
    }
  }

  private sendShadow(): ShadowOptions {
    if (this.hasContent && !(this.running && !this.hasContent)) {
      const active: ShadowOptions = { radius: 14, color: Tokens.accentGlow, offsetY: 3 };
      return active;
    }
    const none: ShadowOptions = { radius: 0, color: Color.Transparent };
    return none;
  }

  private primarySymbol(): Resource {
    if (this.running && !this.hasContent) {
      return $r('sys.symbol.square_fill');
    }
    if (this.sending) {
      return $r('sys.symbol.ellipsis_circle');
    }
    return $r('sys.symbol.arrow_up');
  }

  private primarySymbolColor(): string {
    if (this.running && !this.hasContent) {
      return Tokens.fg;
    }
    return this.hasContent ? '#FFFFFF' : Tokens.dim2;
  }

  private primaryBtnBg(): ResourceColor {
    if (this.running && !this.hasContent) {
      return Tokens.surface3;
    }
    return this.hasContent ? Tokens.accent : Color.Transparent;
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        if (Motion.isVivid(this.motionMode)) {
          SymbolGlyph(this.attachOn ? $r('sys.symbol.xmark') : $r('sys.symbol.plus'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor([this.attachOn ? Tokens.accent : Tokens.dim])
            .symbolEffect(Motion.replaceEffect(), this.attachTrigger)
        } else {
          Text(this.attachOn ? '×' : '+')
            .fontSize(this.attachOn ? 20 : 22)
            .fontColor(this.attachOn ? Tokens.accent : Tokens.dim)
            .textAlign(TextAlign.Center)
        }
      }
      .width(36)
      .height(36)
      .borderRadius(Tokens.rPill)
      .backgroundColor(this.attachOn ? Tokens.accentSoft : Color.Transparent)
      .margin({ left: 4 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .accessibilityText('添加与指令')
      .onClick(() => {
        Haptics.tap();
        this.onToggleAttach();
      })

      if (this.running && this.hasContent) {
        Text('排队')
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .margin({ left: 6 })
          .onClick(() => {
            Haptics.confirm();
            this.onSendQueue();
          })
        Text('插队')
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .padding({ left: 13, right: 13, top: 7, bottom: 7 })
          .backgroundColor(Tokens.err)
          .borderRadius(Tokens.rPill)
          .shadow({ radius: 12, color: '#4DD4380D', offsetY: 2 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .margin({ left: 6 })
          .onClick(() => {
            Haptics.confirm();
            this.onSendSteer();
          })
      } else if (Motion.isVivid(this.motionMode)) {
        // 灵动档合并发送/停止为同一胶囊按钮，通过 ReplaceSymbolEffect 实现原生图标形变
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.primarySymbol())
            .fontSize(this.running && !this.hasContent ? 15 : (this.hasContent ? 19 : 17))
            .fontWeight(FontWeight.Bold)
            .fontColor([this.primarySymbolColor()])
            .symbolEffect(Motion.replaceEffect(), this.actionTrigger)
        }
        .width(38)
        .height(38)
        .backgroundColor(this.primaryBtnBg())
        .borderRadius(Tokens.rPill)
        .shadow(this.sendShadow())
        .animation(Motion.fadeOpts(this.motionMode))
        .margin({ left: 6 })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText(this.running && !this.hasContent ? '停止生成' : '发送')
        .onClick(() => {
          if (this.running && !this.hasContent) {
            Haptics.warn();
            this.onStop();
          } else {
            Haptics.confirm();
            this.onSendNormal();
          }
        })
      } else if (this.running && !this.hasContent) {
        Text('■')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor(Tokens.surface3)
          .borderRadius(Tokens.rPill)
          .margin({ left: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .accessibilityText('停止生成')
          .onClick(() => {
            Haptics.warn();
            this.onStop();
          })
      } else {
        Text(this.sending ? '···' : '↑')
          .fontSize(this.hasContent ? 20 : 18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.hasContent ? '#FFFFFF' : Tokens.dim2)
          .width(38)
          .height(38)
          .textAlign(TextAlign.Center)
          .backgroundColor(this.hasContent ? Tokens.accent : Color.Transparent)
          .borderRadius(Tokens.rPill)
          .shadow(this.sendShadow())
          .animation(Motion.fadeOpts(this.motionMode))
          .margin({ left: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .accessibilityText('发送')
          .onClick(() => {
            Haptics.confirm();
            this.onSendNormal();
          })
      }
    }
    .alignItems(VerticalAlign.Center)
  }
}
