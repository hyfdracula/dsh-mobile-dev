import { BackendCapabilities, defaultBackendCapabilities } from '../../common/Api';
import { Haptics } from '../../common/Haptics';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { PopupItem, PopupSection, UnifiedPopupCard } from '../../common/UnifiedPopup';

/**
 * 聊天页右上角更多菜单（F05）：
 * 统一复用 UnifiedPopupCard，开放全量「预设与控制台」四项入口，
 * 无论当前会话引擎为 DSH、Codex、Claude Code、OpenCode 还是 Antigravity 均可直接访问。
 */
@Component
export struct ChatMenuPopup {
  @Prop pinned: boolean = false;
  @Prop backendId: string = 'dsh';
  @Prop caps: BackendCapabilities = defaultBackendCapabilities('dsh');
  onOpenExtras: (mode: string) => void = () => {};
  onStartRename: () => void = () => {};
  onTogglePin: () => void = () => {};
  onForkSession: () => void = () => {};
  onOpenSearch: () => void = () => {};
  onExportMd: () => void = () => {};
  onOpenPresets: () => void = () => {};
  onOpenWebConsole: () => void = () => {};
  onRefresh: () => void = () => {};
  onArchive: () => void = () => {};
  onDismiss: () => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;

  private buildSections(): PopupSection[] {
    const isDsh: boolean = this.backendId === '' || this.backendId === 'dsh';
    const sessionItems: PopupItem[] = [];
    if (isDsh) {
      sessionItems.push({ id: 'rename', label: '重命名会话' });
    }
    if (isDsh || this.caps.archivePin) {
      sessionItems.push({ id: 'pin', label: this.pinned ? '取消置顶' : '置顶会话' });
    }
    if (this.caps.fork) {
      sessionItems.push({ id: 'fork', label: '分支新会话' });
    }
    sessionItems.push({ id: 'search', label: '搜索消息' });
    sessionItems.push({ id: 'export', label: '导出 Markdown' });
    sessionItems.push({ id: 'refresh', label: '刷新消息' });
    if (isDsh || this.caps.archivePin) {
      sessionItems.push({ id: 'archive', label: '归档此会话', danger: true });
    }

    const consoleItems: PopupItem[] = [
      { id: 'presets', label: '智能体预设与权限' },
      { id: 'plugins', label: '插件管理' },
      { id: 'schedules', label: '自动化任务' },
      { id: 'web_console', label: '电脑完整网页控制台' }
    ];

    const sections: PopupSection[] = [];
    if (isDsh) {
      const workbenchItems: PopupItem[] = [
        { id: 'files', label: '工作区文件' },
        { id: 'git', label: 'Git 变更与对比' },
        { id: 'terminal', label: '远程终端' },
        { id: 'preview', label: '本机端口预览' },
        { id: 'team', label: '智能体团队' }
      ];
      sections.push({ title: '远控工作台', items: workbenchItems });
    }
    sections.push({ title: '预设与控制台', items: consoleItems });
    sections.push({ title: '会话管理', items: sessionItems });
    return sections;
  }

  private handleSelect(id: string): void {
    this.onDismiss();
    if (id === 'files' || id === 'git' || id === 'terminal' || id === 'preview' ||
      id === 'team' || id === 'plugins' || id === 'schedules') {
      this.onOpenExtras(id);
      return;
    }
    if (id === 'rename') {
      this.onStartRename();
    } else if (id === 'pin') {
      this.onTogglePin();
    } else if (id === 'fork') {
      this.onForkSession();
    } else if (id === 'search') {
      this.onOpenSearch();
    } else if (id === 'export') {
      this.onExportMd();
    } else if (id === 'presets') {
      this.onOpenPresets();
    } else if (id === 'web_console') {
      this.onOpenWebConsole();
    } else if (id === 'refresh') {
      this.onRefresh();
    } else if (id === 'archive') {
      this.onArchive();
    }
  }

  build() {
    UnifiedPopupCard({
      sections: this.buildSections(),
      cardWidth: 256,
      maxCardHeight: 492,
      onSelect: (id: string): void => {
        this.handleSelect(id);
      }
    })
  }
}

/**
 * 会话重命名半模态面板（F05）：
 * 配合 bindSheet(height: SheetSize.FIT_CONTENT) 与 kbH 动态避让，替代旧居中蒙层弹窗。
 */
@Component
export struct RenameSessionSheet {
  @Prop initialTitle: string = '';
  @Prop kbH: number = 0;
  onSave: (title: string) => void = () => {};
  onCancel: () => void = () => {};
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private text: string = '';

  aboutToAppear(): void {
    this.text = this.initialTitle;
  }

  build() {
    Column() {
      Row() {
        Text('重命名会话')
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
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .border(Mat.subCardBorder(this.hdsOn))
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .accessibilityText('关闭')
        .onClick(() => {
          Haptics.tap();
          this.onCancel();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 14 })

      TextInput({ text: this.text, placeholder: '输入新的会话名称' })
        .fontSize(Tokens.fsBodyLg)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .backgroundColor(Mat.subCardBg(this.hdsOn))
        .borderRadius(Tokens.rMd)
        .border(Mat.subCardBorder(this.hdsOn))
        .height(46)
        .padding({ left: 14, right: 14 })
        .onChange((v: string) => {
          this.text = v;
        })
        .onSubmit(() => {
          if (this.text.trim() !== '') {
            this.onSave(this.text);
          }
        })

      Row({ space: 10 }) {
        Blank()
        Text('取消')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.dim)
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onCancel();
          })
        Text('保存')
          .fontSize(Tokens.fsBody)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.text.trim() === '' ? Tokens.dim2 : Tokens.accentInk)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(this.text.trim() === '' ? Tokens.surface2 : Tokens.accent)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            if (this.text.trim() === '') {
              return;
            }
            Haptics.confirm();
            this.onSave(this.text);
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({
      left: 20,
      right: 20,
      top: 10,
      bottom: this.kbH > 0 ? this.kbH + 16 : this.bottomInset + 20
    })
    .alignItems(HorizontalAlign.Start)
  }
}
