import {
  BackendCapabilities,
  SessionRow,
  backendIdOfSession,
  backendLabelOf,
  defaultBackendCapabilities
} from '../../common/Api';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { Motion } from '../../common/Motion';
import { ago } from '../../common/Format';
import { Marks } from '../../common/Marks';
import { Unread } from '../../common/Unread';
import { Haptics } from '../../common/Haptics';
import { PopupItem, PopupSection, UnifiedPopupCard } from '../../common/UnifiedPopup';
import { wsLeafName } from './SessionModels';

/**
 * 单条会话卡片（K4 / I2 / I4 / F05 / F12）：
 * - 点按整卡：普通态进入会话，多选态切换勾选
 * - 长按整卡：进入多选模式并勾选本条
 * - 标题左侧未读蓝点（F12）：订阅 unreadVer 实时显示未读新回复并加粗标题
 * - 右侧 ... 按钮：弹出统一风格 UnifiedPopupCard 操作菜单（F05）
 */
@Component
export struct SessionTile {
  @Prop row: SessionRow = { id: '', title: '', updatedAt: 0, cwd: '', running: false };
  @Prop preview: string = '';
  @Prop count: number = 0;
  @Prop archivedView: boolean = false;
  @Prop selectMode: boolean = false;
  @Prop checked: boolean = false;
  @Prop caps: BackendCapabilities = defaultBackendCapabilities('dsh');

  onToggle: () => void = () => {};
  onLongSelect: () => void = () => {};
  onTap: () => void = () => {};
  onRename: () => void = () => {};
  onPin: () => void = () => {};
  onArchive: () => void = () => {};
  onCopyId: () => void = () => {};
  onFork: () => void = () => {};

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('marksVer') marksVer: number = 0;
  @StorageLink('unreadVer') unreadVer: number = 0;
  @State private menuOn: boolean = false;
  private menuAt: number = 0;

  private isUnread(): boolean {
    if (this.unreadVer < 0) {
      return false;
    }
    return Unread.has(this.row.id);
  }

  private statusKind(): string {
    if (this.marksVer < 0) {
      return '';
    }
    if (this.row.asking === true) {
      return 'asking';
    }
    if (this.row.running === true) {
      return 'running';
    }
    const m: string = Marks.get(this.row.id);
    if (m === 'interrupted') {
      return 'interrupted';
    }
    if (m === 'done') {
      return 'done';
    }
    return '';
  }

  private statusLabel(): string {
    const k: string = this.statusKind();
    if (k === 'running') {
      return '进行中';
    }
    if (k === 'asking') {
      return '等你回答';
    }
    if (k === 'interrupted') {
      return '已中断';
    }
    if (k === 'done') {
      return '已完成';
    }
    return '';
  }

  private statusInk(): string {
    const k: string = this.statusKind();
    if (k === 'running') {
      return Tokens.runInk;
    }
    if (k === 'asking') {
      return Tokens.askInk;
    }
    if (k === 'interrupted') {
      return Tokens.intrInk;
    }
    return Tokens.doneInk;
  }

  private statusBg(): string {
    const k: string = this.statusKind();
    if (k === 'running') {
      return Tokens.runBg;
    }
    if (k === 'asking') {
      return Tokens.askBg;
    }
    if (k === 'interrupted') {
      return Tokens.intrBg;
    }
    return Tokens.doneBg;
  }

  @Builder
  statusBadge() {
    Row({ space: 5 }) {
      Row()
        .width(7)
        .height(7)
        .borderRadius(Tokens.rPill)
        .backgroundColor(this.statusInk())
      Text(this.statusLabel())
        .fontSize(Tokens.fsCaption)
        .fontColor(this.statusInk())
    }
    .height(21)
    .padding({ left: 7, right: 7 })
    .borderRadius(Tokens.rPill)
    .backgroundColor(this.statusBg())
  }

  private backendTag(): string {
    const bid: string = (this.row.backend !== undefined && this.row.backend !== '')
      ? this.row.backend
      : backendIdOfSession(this.row.id);
    return bid !== 'dsh' ? backendLabelOf(bid) : '';
  }

  private buildMenuSections(): PopupSection[] {
    const isExt: boolean = this.backendTag() !== '';
    const mainItems: PopupItem[] = [];
    if (!isExt) {
      mainItems.push({ id: 'rename', label: '重命名' });
    }
    if (this.caps.archivePin) {
      mainItems.push({ id: 'pin', label: this.row.pinned === true ? '取消置顶' : '置顶' });
    }
    if (this.caps.fork) {
      mainItems.push({ id: 'fork', label: '分支新会话' });
    }
    mainItems.push({ id: 'copy', label: '复制会话 ID' });

    const sections: PopupSection[] = [
      { title: isExt ? this.backendTag() : '', items: mainItems }
    ];
    if (this.caps.archivePin) {
      sections.push({
        title: '',
        items: [{ id: 'archive', label: this.archivedView ? '恢复' : '归档', danger: !this.archivedView }]
      });
    }
    return sections;
  }

  @Builder
  private tilePopup() {
    UnifiedPopupCard({
      sections: this.buildMenuSections(),
      cardWidth: 212,
      maxCardHeight: 340,
      onSelect: (id: string) => {
        this.menuOn = false;
        if (id === 'rename') {
          this.onRename();
        } else if (id === 'pin') {
          this.onPin();
        } else if (id === 'fork') {
          this.onFork();
        } else if (id === 'copy') {
          this.onCopyId();
        } else if (id === 'archive') {
          this.onArchive();
        }
      }
    })
  }

  build() {
    Row() {
      if (this.selectMode) {
        Stack({ alignContent: Alignment.Center }) {
          if (this.checked) {
            Text('√')
              .fontSize(Tokens.fsFoot)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.accentInk)
          }
        }
        .width(22)
        .height(22)
        .borderRadius(Tokens.rPill)
        .backgroundColor(this.checked ? Tokens.accent : Color.Transparent)
        .border({ width: 1.5, color: this.checked ? Tokens.accent : Tokens.line })
        .margin({ right: 10 })
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }

      Column() {
        Row() {
          if (this.isUnread()) {
            Row()
              .width(8)
              .height(8)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.accent)
              .margin({ right: 7 })
          }
          Text(this.row.title === '' ? '(untitled)' : this.row.title)
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(this.isUnread() ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.row.pinned === true && !this.archivedView) {
            Row() {
              Text('置顶')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.accent)
            }
            .height(21)
            .padding({ left: 7, right: 7 })
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.accentSoft)
            .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text(ago(this.row.updatedAt))
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
          if (this.row.cwd.trim() !== '') {
            Text('·')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .margin({ left: 6, right: 6 })
            Text(wsLeafName(this.row.cwd))
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 132 })
          }
          if (this.backendTag() !== '') {
            Text(this.backendTag())
              .fontSize(Tokens.fsCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .margin({ left: 6 })
          }
          Blank()
          if (this.statusKind() !== '') {
            this.statusBadge()
          }
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Center)

        if (this.preview !== '') {
          Row() {
            Text(this.preview)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.count > 0) {
              Text(String(this.count) + ' 条')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .margin({ top: 5 })
          .alignItems(VerticalAlign.Center)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (!this.selectMode) {
        Text('···')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.dim)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rPill)
          .margin({ left: 4 })
          .accessibilityText('会话操作菜单')
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            Haptics.tap();
            this.menuAt = Date.now();
            this.menuOn = !this.menuOn;
          })
          .bindPopup(this.menuOn, Mat.popupOpts(
            this.hdsOn,
            (): void => { this.tilePopup(); },
            Placement.BottomRight,
            { x: 0, y: 4 },
            (vis: boolean): void => {
              if (!vis) {
                this.menuOn = false;
              }
            },
            20,
            TransitionEffect.OPACITY
              .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: '100%', centerY: '0%' }))
              .animation({ duration: Motion.fade, curve: Motion.std })
          ))
      }
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .padding({ left: 14, right: 10, top: 12, bottom: 12 })
    .borderRadius(Tokens.rCard)
    .backgroundColor(this.checked && this.selectMode ? Mat.subCardBg(this.hdsOn) : Mat.tileBg(this.hdsOn))
    .border({
      width: 1,
      color: this.checked && this.selectMode ? Tokens.accent : Mat.cardBorderColor(this.hdsOn)
    })
    .shadow(Mat.cardShadow(this.hdsOn))
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      if (Date.now() - this.menuAt < 380) {
        return;
      }
      if (this.selectMode) {
        this.onToggle();
        return;
      }
      this.onTap();
    })
    .priorityGesture(
      LongPressGesture({ repeat: false })
        .onAction(() => {
          if (Date.now() - this.menuAt < 400) {
            return;
          }
          if (!this.selectMode) {
            Haptics.long();
            this.onLongSelect();
          }
        })
    )
  }
}
