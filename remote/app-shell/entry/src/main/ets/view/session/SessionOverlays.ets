import { Mat } from '../../common/Mat';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { EmptyState } from '../../common/Widgets';
import { Haptics } from '../../common/Haptics';

/**
 * 重命名会话半模态内容（U5：Scroll + FIT_CONTENT 自动避让软键盘）。
 */
@Component
export struct SessionRenameSheet {
  @Prop initialTitle: string = '';
  onCancel: () => void = () => {};
  onConfirm: (nextTitle: string) => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @State private draft: string = '';

  aboutToAppear(): void {
    this.draft = this.initialTitle;
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('重命名会话')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .width('100%')
        TextInput({ text: this.draft, placeholder: '输入新的会话标题' })
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .placeholderColor(Tokens.dim2)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .borderRadius(Tokens.rInput)
          .height(46)
          .onChange((v: string) => {
            this.draft = v;
          })
          .onSubmit(() => {
            this.onConfirm(this.draft);
          })
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.dim)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(44)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Mat.subCardBg(this.hdsOn))
            .border(Mat.subCardBorder(this.hdsOn))
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.onCancel();
            })
          Text('保存')
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accentInk)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .height(44)
            .borderRadius(Tokens.rInput)
            .backgroundColor(Tokens.accent)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Haptics.tap();
              this.onConfirm(this.draft);
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: this.bottomInset + 18 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .scrollBar(BarState.Off)
    .backgroundColor(Color.Transparent)
  }
}

/**
 * 底部多选操作栏（U1 / I2 / R8：同时支持正常归档与归档视图下的批量恢复）。
 */
@Component
export struct SessionBatchBar {
  @Prop selectedCount: number = 0;
  @Prop archivedView: boolean = false;
  onSelectAll: () => void = () => {};
  onBatchAct: () => void = () => {};
  onCancel: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  build() {
    Column() {
      Row() {
        Row() {
          Text('已选 ')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
          Text(String(this.selectedCount))
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
            .contentTransition(Motion.numTransition(this.motionMode))
          Text(' 项')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
        }
        .alignItems(VerticalAlign.Center)
        Blank()
        Text('全选')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.onSelectAll();
          })
        Text(this.archivedView ? '恢复' : '归档')
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.selectedCount > 0 ? Tokens.accentInk : Tokens.dim2)
          .backgroundColor(this.selectedCount > 0 ? Tokens.accent : Tokens.surface2)
          .borderRadius(Tokens.rPill)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .margin({ left: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.onBatchAct();
          })
        Text('取消')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim)
          .padding({ left: 10, right: 6, top: 6, bottom: 6 })
          .margin({ left: 4 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.onCancel();
          })
      }
      .width('100%')
      .constraintSize({ maxWidth: 740 })
      .padding({ left: 16, right: 12, top: 10, bottom: 10 })
      .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
      .backgroundEffect(Mat.glassEffect(this.hdsOn, false))
      .borderRadius(Tokens.rXl)
      .border(Mat.glassRimBorder(this.hdsOn))
      .shadow(Mat.glassFloatShadow(this.hdsOn))
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: this.bottomInset + 14 })
    .alignItems(HorizontalAlign.Center)
    .transition(Motion.panelTransition(this.motionMode))
  }
}

/**
 * 会话列表多分支空态包装组件。
 */
@Component
export struct SessionListEmptyView {
  @Prop hasQuery: boolean = false;
  @Prop archivedView: boolean = false;
  @Prop timedOut: boolean = false;
  @Prop hasWsFilterOnly: boolean = false;
  @Prop hasBackendFilterOnly: boolean = false;
  onAction: () => void = () => {};

  build() {
    Column() {
      if (this.hasQuery) {
        EmptyState({
          icon: $r('app.media.ic_search'),
          title: '没有匹配的会话',
          hint: '换个关键词，或清除搜索条件',
          action: '清除搜索',
          onAction: () => {
            this.onAction();
          }
        })
      } else if (this.archivedView) {
        EmptyState({
          icon: $r('app.media.ic_archive'),
          title: '归档列表是空的',
          hint: '归档过的会话会保存在这里，随时可以恢复',
          action: '返回正常列表',
          onAction: () => {
            this.onAction();
          }
        })
      } else if (this.timedOut) {
        EmptyState({
          icon: $r('app.media.ic_set_pc'),
          title: '还没拿到会话',
          hint: '电脑端暂时没有响应，可以再试一次',
          action: '重试',
          onAction: () => {
            this.onAction();
          }
        })
      } else if (this.hasBackendFilterOnly) {
        EmptyState({
          icon: $r('app.media.ic_set_agent'),
          title: '该引擎下暂无会话',
          hint: '可以切回全部引擎，或点右下角 + 在该引擎下新建',
          action: '显示全部引擎',
          onAction: () => {
            this.onAction();
          }
        })
      } else if (this.hasWsFilterOnly) {
        EmptyState({
          icon: $r('app.media.ic_chat'),
          title: '这个工作区还没有会话',
          hint: '可切换回全部工作区，或点右下角 + 在此新建',
          action: '全部工作区',
          onAction: () => {
            this.onAction();
          }
        })
      } else {
        EmptyState({
          icon: $r('app.media.ic_chat'),
          title: '还没有会话',
          hint: '点右下角 + 选择电脑目录并开始对话'
        })
      }
    }
    .width('100%')
  }
}

/**
 * 右下角新建会话玻璃悬浮按钮（U1）。
 */
@Component
export struct SessionNewFab {
  @Prop creating: boolean = false;
  onTap: () => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  build() {
    Column() {
      Stack() {
        if (this.hdsOn) {
          Row()
            .width('100%').height('100%').borderRadius(Tokens.rXl)
            .backgroundColor(this.themeDark ? '#CC1C2333' : '#DEFFFFFF')
            .hitTestBehavior(HitTestMode.None)
          Row()
            .width('100%').height('100%').borderRadius(Tokens.rXl)
            .linearGradient({
              angle: 160,
              colors: [[this.themeDark ? '#38FFFFFF' : '#B8FFFFFF', 0.0], ['#00FFFFFF', 0.62]]
            })
            .hitTestBehavior(HitTestMode.None)
        }
        Text(this.creating ? '...' : '+')
          .fontSize(28)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.hdsOn ? (this.themeDark ? '#F8FAFC' : Tokens.fg) : Tokens.accentInk)
          .textAlign(TextAlign.Center).width(56).height(56)
      }
      .width(56).height(56).borderRadius(Tokens.rXl)
      .backgroundColor(this.hdsOn
        ? (Mat.isNativeSupported() ? Color.Transparent : (this.themeDark ? '#EB1C2333' : '#F5FFFFFF'))
        : Tokens.accent)
      .backdropBlur(this.hdsOn && !Mat.isNativeSupported() ? (this.themeDark ? 20 : 26) : 0)
      .systemMaterial(Mat.fab(this.hdsOn))
      .border({
        width: this.hdsOn ? 1 : 0,
        color: this.hdsOn ? (this.themeDark ? '#47FFFFFF' : '#D9FFFFFF') : Color.Transparent
      })
      .shadow(this.hdsOn
        ? { radius: 22, color: this.themeDark ? '#66000000' : '#261C2C4D', offsetY: 8 }
        : { radius: 10, color: Tokens.accentGlow, offsetY: 4 })
      .margin({ right: 22, bottom: this.bottomInset + 94 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .accessibilityText('新建会话')
      .onClick(() => {
        Haptics.tap();
        this.onTap();
      })
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.End).alignItems(HorizontalAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
  }
}

/**
 * 首屏会话列表加载与慢连接重试指示器。
 */
@Component
export struct SessionLoadingBox {
  @Prop loadSlow: boolean = false;
  onRetry: () => void = () => {};
  @StorageLink('topInset') topInset: number = 40;

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        LoadingProgress().width(20).height(20).color(Tokens.accent)
        Text(this.loadSlow ? '还没连上电脑' : '读取会话...').fontSize(Tokens.fsBody).fontColor(Tokens.dim2)
      }
      .justifyContent(FlexAlign.Center)
      if (this.loadSlow) {
        Text('点这里重试')
          .fontSize(Tokens.fsBody).fontColor(Tokens.accent)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(Tokens.rPill).backgroundColor(Tokens.surface2)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onRetry();
          })
      }
    }
    .width('100%').justifyContent(FlexAlign.Center)
    .padding({ top: this.topInset + 112, left: 24, right: 24 })
  }
}
