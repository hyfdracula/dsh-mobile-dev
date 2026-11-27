import { Tokens } from '../../common/Tokens';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Machine, Machines } from '../../common/Machines';
import { isLanUrl } from '../../common/ApiUtil';
import { Marks } from '../../common/Marks';
import { Unread } from '../../common/Unread';
import { Toast } from '../../common/Toast';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { PopupItem, PopupSection, UnifiedPopupCard } from '../../common/UnifiedPopup';
import { WsOpt } from './SessionModels';
import { SessionViewMenu } from './SessionViewMenu';

/**
 * 会话列表浮动玻璃顶栏（F01 / F02 / F05 / L3 / L4）：
 * 包含工作区筛选胶囊（内置极简链路状态徽标）、多电脑切换、统一弹出视图菜单与流式搜索框。
 */
@Component
export struct SessionHeaderBar {
  @Prop wsOpts: WsOpt[] = [];
  @Prop wsFilter: string = '';
  @Prop wsFilterLabel: string = '';
  @Prop archivedView: boolean = false;
  @Prop groupBy: string = 'time';
  @Prop sortBy: string = 'recent';
  @Prop listState: string = 'all';
  @Prop searching: boolean = false;
  @Prop q: string = '';

  onSearchingChange: (v: boolean) => void = () => {};
  onQueryChange: (v: string) => void = () => {};
  onSheetActiveChange: (active: boolean) => void = () => {};
  onPickWs: (opt: WsOpt) => void = () => {};
  onOpenNewWs: () => void = () => {};
  onExitArchived: () => void = () => {};
  onPickMachine: (id: string) => void = () => {};
  onSelectGroupBy: (g: string) => void = () => {};
  onSelectSortBy: (sb: string) => void = () => {};
  onSetArchived: (want: boolean) => void = () => {};
  onSelectListState: (st: string) => void = () => {};
  onEnterSelect: () => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('machinesVer') machinesVer: number = 0;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('online') online: boolean = true;
  @StorageLink('linkMode') linkMode: string = 'lan';
  @StorageLink('linkEncrypted') linkEncrypted: boolean = false;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('shellTab') @Watch('onShellTabChange') shellTab: number = 0;

  @State private hdrEntered: boolean = false;
  @State private searchGrow: number = 1;
  @State private searchGlyphTrigger: number = -1;
  @State private wsMenuOn: boolean = false;
  @State private viewOn: boolean = false;
  @State private devOn: boolean = false;
  private hdrTimer: number = -1;
  private lastTab: number = 0;

  aboutToAppear(): void {
    this.lastTab = this.shellTab;
    if (!Motion.isFlagship(this.motionMode)) {
      this.hdrEntered = true;
      return;
    }
    this.hdrEntered = false;
    if (this.shellTab === 0 && !this.searching) {
      this.scheduleHeaderEnter(24);
    }
  }

  aboutToDisappear(): void {
    if (this.hdrTimer >= 0) {
      clearTimeout(this.hdrTimer);
      this.hdrTimer = -1;
    }
  }

  private clearHeaderTimer(): void {
    if (this.hdrTimer >= 0) {
      clearTimeout(this.hdrTimer);
      this.hdrTimer = -1;
    }
  }

  private scheduleHeaderEnter(waitMs: number): void {
    this.clearHeaderTimer();
    this.hdrTimer = setTimeout(() => {
      this.hdrTimer = -1;
      if (this.shellTab === 0) {
        this.hdrEntered = true;
      }
    }, waitMs);
  }

  private onShellTabChange(): void {
    this.clearHeaderTimer();
    if (!Motion.isFlagship(this.motionMode)) {
      this.hdrEntered = true;
      this.lastTab = this.shellTab;
      return;
    }
    if (this.shellTab !== 0) {
      // 离开首页时在离屏态无动画归位，切回时零闪现、零反向回弹
      if (!this.searching) {
        this.hdrEntered = false;
      }
    } else if (this.lastTab !== 0) {
      if (this.searching) {
        this.hdrEntered = true;
      } else {
        this.hdrEntered = false;
        this.scheduleHeaderEnter(20);
      }
    }
    this.lastTab = this.shellTab;
  }

  private immersiveOn(): boolean {
    return this.hdsOn && Mat.isImmersiveReady();
  }

  private pillBg(): ResourceColor {
    if (!this.hdsOn) {
      return Tokens.surface;
    }
    return this.immersiveOn() ? Color.Transparent : (this.themeDark ? '#4D161C28' : '#59FFFFFF');
  }

  private pillBlur(): number {
    return this.hdsOn && !this.immersiveOn() ? 18 : 0;
  }

  private pillBorderColor(): string {
    if (!this.hdsOn) {
      return Tokens.line;
    }
    return this.immersiveOn() ? Tokens.glassLine : Tokens.pillEdge;
  }

  private pillShadow(): ShadowOptions {
    if (!this.hdsOn || this.immersiveOn()) {
      const clear: ShadowOptions = { radius: 0, color: Color.Transparent };
      return clear;
    }
    const glow: ShadowOptions = { radius: 12, color: Tokens.accentGlow, offsetY: 2 };
    return glow;
  }

  private pillMat() {
    return this.hdsOn ? Mat.whiteOn(this.immersiveOn()) : Mat.empty();
  }

  private openSearch(): void {
    if (Motion.isVivid(this.motionMode)) {
      this.searchGrow = 1;
      this.searchGlyphTrigger += 1;
      this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
        this.onSearchingChange(true);
      });
      return;
    }
    this.searchGrow = 0.12;
    this.onSearchingChange(true);
    setTimeout(() => { this.searchGrow = 1; }, 32);
  }

  private clearSearch(): void {
    this.onQueryChange('');
    this.hdrEntered = true;
    if (Motion.isVivid(this.motionMode)) {
      this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
        this.onSearchingChange(false);
      });
      return;
    }
    this.searchGrow = 0.12;
    setTimeout(() => {
      this.onSearchingChange(false);
      this.searchGrow = 1;
    }, Motion.move);
  }

  private linkDotColor(): string {
    if (!this.online || this.linkMode === 'offline') {
      return Tokens.err;
    }
    if (this.linkMode === 'lan') {
      return Tokens.ok;
    }
    return Tokens.accent;
  }

  private linkStatusText(): string {
    if (!this.online || this.linkMode === 'offline') {
      return '离线';
    }
    const base: string = this.linkMode === 'lan' ? '局域网' : '公网';
    return this.linkEncrypted ? (base + ' · 加密') : base;
  }

  private buildWsSections(): PopupSection[] {
    if (this.archivedView) {
      const archItems: PopupItem[] = [
        { id: '__exit_archived__', label: '返回正常会话列表', sub: '退出已归档视图' }
      ];
      const archSections: PopupSection[] = [
        { title: '归档视图', items: archItems }
      ];
      return archSections;
    }

    const wsItems: PopupItem[] = [];
    for (let i = 0; i < this.wsOpts.length; i++) {
      const o: WsOpt = this.wsOpts[i];
      const item: PopupItem = {
        id: 'ws:' + o.id,
        label: o.name,
        sub: String(o.count) + ' 个会话',
        checked: this.wsFilter === o.id
      };
      wsItems.push(item);
    }
    const actItems: PopupItem[] = [
      { id: '__new_ws__', label: '浏览 / 新建工作区...', sub: '选择电脑目录并开始新对话' }
    ];
    const sections: PopupSection[] = [
      { title: '工作区', items: wsItems },
      { title: '操作', items: actItems }
    ];
    return sections;
  }

  private handleWsSelect(id: string): void {
    this.wsMenuOn = false;
    if (id === '__exit_archived__') {
      this.onExitArchived();
      return;
    }
    if (id === '__new_ws__') {
      this.onOpenNewWs();
      return;
    }
    if (id.startsWith('ws:')) {
      const targetId: string = id.substring(3);
      for (let i = 0; i < this.wsOpts.length; i++) {
        if (this.wsOpts[i].id === targetId) {
          this.onPickWs(this.wsOpts[i]);
          return;
        }
      }
    }
  }

  @Builder
  private wsPopup() {
    UnifiedPopupCard({
      sections: this.buildWsSections(),
      cardWidth: 248,
      maxCardHeight: 420,
      onSelect: (id: string) => {
        this.handleWsSelect(id);
      }
    })
  }

  private machineSub(m: Machine): string {
    const hasWan: boolean = m.wan !== '' && !isLanUrl(m.wan);
    const hasLan: boolean = (m.lan !== undefined && m.lan.length > 0) || (m.wan !== '' && isLanUrl(m.wan));
    const channel: string = hasWan && hasLan ? '局域网 + 公网' : (hasLan ? '局域网' : '公网');
    const enc: string = m.e2eePub !== undefined && m.e2eePub !== '' ? ' · 加密' : '';
    return channel + enc;
  }

  private buildDevSections(): PopupSection[] {
    const _v: number = this.machinesVer;
    const list: Machine[] = _v >= 0 ? Machines.list() : [];
    const curId: string = Machines.activeId();
    if (list.length === 0) {
      const emptyItems: PopupItem[] = [
        { id: '__empty__', label: '尚未配对电脑', sub: '请到「设置 › 连接」配对', disabled: true }
      ];
      return [{ title: '切换电脑', items: emptyItems }];
    }
    const items: PopupItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const m: Machine = list[i];
      const item: PopupItem = {
        id: 'dev:' + m.id,
        label: m.name !== '' ? m.name : m.id,
        sub: this.machineSub(m),
        checked: m.id === curId
      };
      items.push(item);
    }
    const sections: PopupSection[] = [
      { title: '选择电脑', items: items }
    ];
    return sections;
  }

  private handleDevSelect(id: string): void {
    this.devOn = false;
    if (!id.startsWith('dev:')) {
      return;
    }
    const mid: string = id.substring(4);
    if (mid !== '' && Machines.activeId() !== mid) {
      this.onPickMachine(mid);
    }
  }

  @Builder
  private devPopup() {
    UnifiedPopupCard({
      sections: this.buildDevSections(),
      cardWidth: 248,
      maxCardHeight: 420,
      onSelect: (id: string) => {
        this.handleDevSelect(id);
      }
    })
  }

  @Builder
  private viewPopupBody() {
    SessionViewMenu({
      groupBy: this.groupBy,
      sortBy: this.sortBy,
      archivedView: this.archivedView,
      listState: this.listState,
      onSelectGroupBy: (g: string) => {
        this.viewOn = false;
        this.onSelectGroupBy(g);
      },
      onSelectSortBy: (sb: string) => {
        this.viewOn = false;
        this.onSelectSortBy(sb);
      },
      onSetArchived: (want: boolean) => {
        this.viewOn = false;
        this.onSetArchived(want);
      },
      onSelectListState: (st: string) => {
        this.viewOn = false;
        this.onSelectListState(st);
      },
      onEnterSelect: () => {
        this.viewOn = false;
        this.onEnterSelect();
      },
      onMarkAllRead: () => {
        Haptics.tap();
        this.viewOn = false;
        Unread.clearAll();
        Marks.clearAll();
        Toast.ok('已全部标为已读');
      }
    })
  }

  build() {
    Column() {
      Column() {
        if (this.searching) {
          Row() {
            if (Motion.isVivid(this.motionMode)) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(17)
                .fontColor([Tokens.accent])
                .symbolEffect(Motion.bounceEffect(EffectDirection.UP), this.searchGlyphTrigger)
                .margin({ left: 16, right: 10 })
            } else {
              Image($r('app.media.ic_search'))
                .width(17).height(17).fillColor(Tokens.accent)
                .objectFit(ImageFit.Contain).margin({ left: 16, right: 10 })
            }
            TextInput({ placeholder: '搜索会话标题', text: this.q })
              .fontSize(Tokens.fsBody).fontColor(Tokens.fg).placeholderColor(Tokens.dim2)
              .backgroundColor(Color.Transparent).height(46).layoutWeight(1).padding({ left: 0, right: 4 })
              .onChange((v: string) => {
                this.onQueryChange(v);
              })
            Text('取消')
              .fontSize(Tokens.fsBody).fontColor(Tokens.dim).padding({ left: 8, right: 16 })
              .onClick(() => {
                Haptics.tap();
                this.clearSearch();
              })
          }
          .width('100%').height(46)
          .backgroundColor(this.pillBg())
          .backdropBlur(this.pillBlur())
          .borderRadius(Tokens.rPill)
          .border({ width: 1, color: this.pillBorderColor() })
          .shadow(this.pillShadow())
          .systemMaterial(this.pillMat())
          .geometryTransition(Motion.geoId('session_search_bar', this.motionMode), { follow: true })
          .scale(Motion.isVivid(this.motionMode)
            ? { x: 1, y: 1 }
            : { x: this.searchGrow, y: 1, centerX: '92%', centerY: '50%' })
          .opacity(Motion.isVivid(this.motionMode) ? 1 : (this.searchGrow <= 0.12 ? 0 : 1))
          .animation(Motion.isVivid(this.motionMode) ? undefined : { duration: Motion.emph, curve: Motion.std })
          .transition(Motion.isVivid(this.motionMode)
            ? TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
            : TransitionEffect.IDENTITY)
        } else {
          Row() {
            // 工作区筛选胶囊 + 极简链路状态徽标（F05 / L3）
            Row() {
              Column() {
                Row() {
                  Text(this.archivedView ? '已归档对话' : (this.wsFilter === '' ? '全部工作区' : this.wsFilterLabel))
                    .fontSize(Tokens.fsBody)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.fg)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: this.wideScreen ? 220 : 144 })
                  Image($r('app.media.ic_down'))
                    .width(13)
                    .height(13)
                    .margin({ left: 4 })
                    .fillColor(Tokens.dim2)
                    .objectFit(ImageFit.Contain)
                }
                .alignItems(VerticalAlign.Center)

                Row({ space: 4 }) {
                  Row()
                    .width(6)
                    .height(6)
                    .borderRadius(Tokens.rPill)
                    .backgroundColor(this.linkDotColor())
                  Text(this.linkStatusText())
                    .fontSize(10)
                    .fontColor(Tokens.dim2)
                    .maxLines(1)
                }
                .alignItems(VerticalAlign.Center)
                .margin({ top: 1 })
              }
              .alignItems(HorizontalAlign.Start)
            }
            .padding({ left: 16, right: 14, top: 4, bottom: 4 })
            .height(46)
            .backgroundColor(this.pillBg())
            .backdropBlur(this.pillBlur())
            .border({ width: 1, color: this.pillBorderColor() })
            .borderRadius(Tokens.rPill)
            .shadow(this.pillShadow())
            .systemMaterial(this.pillMat())
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
            .accessibilityText('切换工作区')
            .onClick(() => {
              Haptics.tap();
              this.wsMenuOn = !this.wsMenuOn;
            })
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(this.hdrEntered ? Motion.headerPopOpacityAnim(170, this.motionMode, 200) : null)
            .translate({ x: this.hdrEntered ? 0 : -96 })
            .animation(this.hdrEntered ? Motion.headerPopScaleAnim(170, this.motionMode) : null)
            .bindPopup(this.wsMenuOn, Mat.popupOpts(
              this.hdsOn,
              (): void => { this.wsPopup(); },
              Placement.BottomLeft,
              { x: 0, y: 6 },
              (vis: boolean): void => {
                if (!vis) {
                  this.wsMenuOn = false;
                }
              },
              20,
              Motion.popupMenuTransition(this.motionMode, false)
            ))

            Blank()

            // 切换电脑圆钮（F05 统一弹出卡片，尺寸对齐聊天页 46x46 顶部控件）
            Stack() {
              Image($r('app.media.ic_pc'))
                .width(20).height(20)
                .fillColor((this.machinesVer >= 0 && Machines.list().length > 1) ? Tokens.accent : Tokens.fg)
                .objectFit(ImageFit.Contain)
            }
            .width(46).height(46).borderRadius(Tokens.rPill)
            .backgroundColor(this.pillBg())
            .backdropBlur(this.pillBlur())
            .border({ width: 1, color: this.pillBorderColor() })
            .shadow(this.pillShadow())
            .systemMaterial(this.pillMat())
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('切换电脑')
            .onClick(() => {
              Haptics.tap();
              this.devOn = !this.devOn;
            })
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(this.hdrEntered ? Motion.headerPopOpacityAnim(115, this.motionMode, 210) : null)
            .translate({ x: this.hdrEntered ? 0 : -180 })
            .animation(this.hdrEntered ? Motion.headerPopScaleAnim(115, this.motionMode) : null)
            .bindPopup(this.devOn, Mat.popupOpts(
              this.hdsOn,
              (): void => { this.devPopup(); },
              Placement.BottomRight,
              { x: 0, y: 6 },
              (vis: boolean): void => {
                if (!vis) {
                  this.devOn = false;
                }
              },
              20,
              Motion.popupMenuTransition(this.motionMode, true)
            ))

            // 分组视图设置圆钮（F05 统一弹出卡片）
            Stack() {
              Image($r('app.media.ic_group'))
                .width(20).height(20)
                .fillColor(this.archivedView ? Tokens.accent : Tokens.fg)
                .objectFit(ImageFit.Contain)
            }
            .width(46).height(46).borderRadius(Tokens.rPill).margin({ left: 9 })
            .backgroundColor(this.pillBg())
            .backdropBlur(this.pillBlur())
            .border({ width: 1, color: this.pillBorderColor() })
            .shadow(this.pillShadow())
            .systemMaterial(this.pillMat())
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('视图与分组')
            .onClick(() => {
              Haptics.tap();
              this.viewOn = !this.viewOn;
            })
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(this.hdrEntered ? Motion.headerPopOpacityAnim(Motion.HEADER_DELAY_RIGHT_INNER, this.motionMode, 220) : null)
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_RIGHT_INNER_X })
            .animation(this.hdrEntered ? Motion.headerPopScaleAnim(Motion.HEADER_DELAY_RIGHT_INNER, this.motionMode) : null)
            .bindPopup(this.viewOn, Mat.popupOpts(
              this.hdsOn,
              (): void => { this.viewPopupBody(); },
              Placement.BottomRight,
              { x: 0, y: 6 },
              (vis: boolean): void => {
                if (!vis) {
                  this.viewOn = false;
                }
              },
              20,
              Motion.popupMenuTransition(this.motionMode, true)
            ))

            // 搜索圆钮（灵动档与展开搜索栏共享 geometryTransition 实现一镜到底）
            Stack() {
              if (Motion.isVivid(this.motionMode)) {
                SymbolGlyph($r('sys.symbol.magnifyingglass'))
                  .fontSize(20)
                  .fontColor([Tokens.fg])
              } else {
                Image($r('app.media.ic_search'))
                  .width(20).height(20).fillColor(Tokens.fg).objectFit(ImageFit.Contain)
              }
            }
            .width(46).height(46).borderRadius(Tokens.rPill).margin({ left: 9 })
            .backgroundColor(this.pillBg())
            .backdropBlur(this.pillBlur())
            .border({ width: 1, color: this.pillBorderColor() })
            .shadow(this.pillShadow())
            .systemMaterial(this.pillMat())
            .geometryTransition(Motion.geoId('session_search_bar', this.motionMode), { follow: true })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('搜索会话')
            .onClick(() => {
              Haptics.tap();
              this.openSearch();
            })
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(this.hdrEntered ? Motion.headerPopOpacityAnim(Motion.HEADER_DELAY_RIGHT_OUTER, this.motionMode, 220) : null)
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_RIGHT_OUTER_X })
            .animation(this.hdrEntered ? Motion.headerPopScaleAnim(Motion.HEADER_DELAY_RIGHT_OUTER, this.motionMode) : null)
          }
          .width('100%')
          .height(50)
          .alignItems(VerticalAlign.Center)
          .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 760 })
      .padding({ left: this.wideScreen ? 12 : 0, right: this.wideScreen ? 12 : 0 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: this.topInset + 10, left: 14, right: 14, bottom: 8 })
  }
}
