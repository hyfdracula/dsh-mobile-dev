import { Api, BackendInfo, HostDirEntry, HostDirsResp } from '../../common/Api';
import { Mat } from '../../common/Mat';
import { Tokens } from '../../common/Tokens';
import { Haptics } from '../../common/Haptics';
import { joinHostPath, tidyCwd, wsLeafName, wsShortLabel } from './SessionModels';

/**
 * 工作区选择、可视化电脑目录浏览与手动新建工作区半模态面板（K4 / U5 / I4 / G6）：
 * - 常用工作区：一键在最近使用的工作区新建会话
 * - 浏览电脑目录（G6）：调用 api.hostDirs(curPath) 支持盘符 roots、最近目录 recent、上级目录 .. 与子目录逐级下钻；
 *   旧宿主返回 404 时友好降级提示手动输入路径
 * - 手动输入路径（U5 / I4）：包裹在 Scroll 内配合 bindSheet(FIT_CONTENT) 自动避让键盘，支持跨平台分隔符
 */
@Component
export struct WorkspaceSheet {
  api: Api = new Api('', '');
  @Prop initialTab: string = 'pick';
  @Prop wsChoices: string[] = [];
  @Prop defaultDir: string = '';
  @Prop creating: boolean = false;
  @Prop enabledBackends: BackendInfo[] = [];

  onClose: () => void = () => {};
  onCreateInDir: (cwd: string, backend: string) => void = () => {};

  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private tab: string = 'pick';
  @State private selectedBackend: string = 'dsh';
  @State private curPath: string = '';
  @State private parentPath: string = '';
  @State private roots: HostDirEntry[] = [];
  @State private dirs: HostDirEntry[] = [];
  @State private recentDirs: string[] = [];
  @State private dirBusy: boolean = false;
  @State private dir404: boolean = false;
  @State private dirErr: string = '';

  @State private manualDir: string = '';
  @State private manualSub: string = '';

  aboutToAppear(): void {
    this.tab = this.initialTab !== '' ? this.initialTab : 'pick';
    this.manualDir = tidyCwd(this.defaultDir);
    if (this.enabledBackends.length > 0 &&
      !this.enabledBackends.some((b: BackendInfo): boolean => b.id === this.selectedBackend)) {
      this.selectedBackend = this.enabledBackends[0].id;
    }
    if (this.tab === 'browse') {
      void this.loadHostDirs(this.manualDir);
    }
  }

  private switchTab(next: string): void {
    if (this.tab === next) {
      return;
    }
    Haptics.tap();
    this.tab = next;
    if (next === 'browse' && !this.dirBusy && this.dirs.length === 0 && this.roots.length === 0 && !this.dir404) {
      void this.loadHostDirs(this.curPath !== '' ? this.curPath : this.manualDir);
    }
  }

  private async loadHostDirs(target: string): Promise<void> {
    this.dirBusy = true;
    this.dirErr = '';
    try {
      const r: HostDirsResp = await this.api.hostDirs(target);
      this.curPath = r.path;
      this.parentPath = r.parent;
      this.roots = r.roots !== undefined ? r.roots : [];
      this.dirs = r.dirs;
      this.recentDirs = r.recent;
      this.dir404 = false;
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (msg.indexOf('HTTP 404') >= 0) {
        this.dir404 = true;
        this.dirErr = '';
      } else {
        this.dirErr = msg !== '' ? msg : '读取电脑目录失败';
      }
    } finally {
      this.dirBusy = false;
    }
  }

  private resolvedManualPath(): string {
    return joinHostPath(this.manualDir, this.manualSub);
  }

  @Builder
  private tabPill(key: string, label: string) {
    Text(label)
      .fontSize(Tokens.fsFoot)
      .fontWeight(this.tab === key ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.tab === key ? Tokens.accentInk : Tokens.dim)
      .backgroundColor(this.tab === key ? Tokens.accent : Tokens.surface2)
      .borderRadius(Tokens.rPill)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
      .onClick(() => {
        this.switchTab(key);
      })
  }

  @Builder
  private pickTabBody() {
    Column({ space: 8 }) {
      if (this.wsChoices.length > 0) {
        Text('最近使用的工作区')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .width('100%')
          .padding({ left: 2, bottom: 2 })

        ForEach(this.wsChoices, (d: string) => {
          Row({ space: 10 }) {
            Stack({ alignContent: Alignment.Center }) {
              Image($r('app.media.ic_set_disk'))
                .width(16)
                .height(16)
                .fillColor(Tokens.accent)
                .objectFit(ImageFit.Contain)
            }
            .width(32)
            .height(32)
            .borderRadius(Tokens.rSm)
            .backgroundColor(Tokens.accentSoft)

            Column() {
              Text(wsLeafName(d))
                .fontSize(Tokens.fsBody)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.fg)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(wsShortLabel(d))
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('新建 ›')
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.accent)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(Tokens.rMd)
          .backgroundColor(Tokens.surface2)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            Haptics.tap();
            this.onCreateInDir(d, this.selectedBackend);
          })
        }, (d: string) => 'pick-' + d)
      } else {
        Text('暂无历史工作区记录，可浏览电脑目录或直接创建默认会话')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      }

      Row({ space: 8 }) {
        Text('浏览电脑目录')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.accent)
          .backgroundColor(Tokens.accentSoft)
          .borderRadius(Tokens.rMd)
          .height(42)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.switchTab('browse');
          })
        Text('手动输入 / 新建目录')
          .fontSize(Tokens.fsBody)
          .fontColor(Tokens.fg)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rMd)
          .height(42)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.switchTab('manual');
          })
      }
      .width('100%')
      .margin({ top: 4 })

      if (this.wsChoices.length === 0) {
        Text(this.creating ? '创建中...' : '在默认目录新建会话')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rMd)
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.onCreateInDir('', this.selectedBackend);
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private browseTabBody() {
    Column({ space: 8 }) {
      if (this.dir404) {
        Column({ space: 10 }) {
          Text('可手动输入路径，重启电脑端 DSH 后支持目录浏览')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.fg)
            .textAlign(TextAlign.Center)
            .width('100%')
          Text('当前电脑端网关尚未加载目录浏览接口，你可以先手动填写目录路径创建会话。')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(18)
            .textAlign(TextAlign.Center)
            .width('100%')
          Text('去手动输入路径')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.accent)
            .backgroundColor(Tokens.accentSoft)
            .borderRadius(Tokens.rPill)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.95 })
            .onClick(() => {
              this.switchTab('manual');
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 20, bottom: 20 })
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rMd)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 盘符 / 根目录横向快捷切换
        if (this.roots.length > 0) {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.roots, (rt: HostDirEntry) => {
                Text(rt.name !== '' ? rt.name : rt.path)
                  .fontSize(Tokens.fsFoot)
                  .fontColor(this.curPath === rt.path ? Tokens.accentInk : Tokens.fg)
                  .backgroundColor(this.curPath === rt.path ? Tokens.accent : Tokens.surface2)
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                  .onClick(() => {
                    Haptics.tap();
                    void this.loadHostDirs(rt.path);
                  })
              }, (rt: HostDirEntry) => 'rt-' + rt.path)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        }

        // 当前目录与一键选定栏
        Column({ space: 8 }) {
          Row() {
            Text(this.curPath !== '' ? this.curPath : '电脑根目录')
              .fontSize(Tokens.fsFoot)
              .fontFamily('monospace')
              .fontColor(Tokens.fg)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.dirBusy) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color(Tokens.accent)
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.curPath !== '') {
            Row({ space: 8 }) {
              Text(this.creating ? '创建中...' : '选定此目录创建会话')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.accentInk)
                .backgroundColor(Tokens.accent)
                .borderRadius(Tokens.rSm)
                .height(36)
                .textAlign(TextAlign.Center)
                .layoutWeight(1)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                .onClick(() => {
                  Haptics.tap();
                  this.onCreateInDir(this.curPath, this.selectedBackend);
                })
              Text('在此新建子目录')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.accent)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rSm)
                .height(36)
                .padding({ left: 10, right: 10 })
                .textAlign(TextAlign.Center)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
                .onClick(() => {
                  Haptics.tap();
                  this.manualDir = this.curPath;
                  this.tab = 'manual';
                })
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding(12)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rMd)

        if (this.dirErr !== '') {
          Text(this.dirErr)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .width('100%')
            .padding({ left: 4, right: 4 })
        }

        // 最近使用目录快捷跳转
        if (this.recentDirs.length > 0 && this.curPath === '') {
          Text('最近访问目录')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .width('100%')
            .padding({ left: 2 })
          ForEach(this.recentDirs, (rp: string) => {
            Row() {
              Text(wsShortLabel(rp))
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.fg)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('进入 ›')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.accent)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rSm)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
            .onClick(() => {
              Haptics.tap();
              void this.loadHostDirs(rp);
            })
          }, (rp: string) => 'rec-' + rp)
        }

        // 返回上级目录 ..
        if (this.curPath !== '') {
          Row() {
            Text('..')
              .fontSize(Tokens.fsBody)
              .fontFamily('monospace')
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.accent)
              .width(28)
            Text('返回上级目录')
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.dim)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rSm)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
          .onClick(() => {
            Haptics.tap();
            const nextParent: string = this.parentPath !== this.curPath ? this.parentPath : '';
            void this.loadHostDirs(nextParent);
          })
        }

        // 子目录列表
        if (this.dirs.length === 0 && !this.dirBusy) {
          Text('当前目录下没有子文件夹，可直接选定此目录')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 14, bottom: 14 })
        } else {
          ForEach(this.dirs, (d: HostDirEntry) => {
            Row() {
              Image($r('app.media.ic_set_disk'))
                .width(15)
                .height(15)
                .fillColor(Tokens.accent)
                .objectFit(ImageFit.Contain)
                .margin({ right: 8 })
              Text(d.name !== '' ? d.name : wsLeafName(d.path))
                .fontSize(Tokens.fsBody)
                .fontColor(Tokens.fg)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text('选定')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.accent)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rPill)
                .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                .margin({ left: 8, right: 6 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.onCreateInDir(d.path, this.selectedBackend);
                })
              Text('›')
                .fontSize(15)
                .fontColor(Tokens.dim2)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 9, bottom: 9 })
            .backgroundColor(Tokens.surface2)
            .borderRadius(Tokens.rSm)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
            .onClick(() => {
              Haptics.tap();
              void this.loadHostDirs(d.path);
            })
          }, (d: HostDirEntry) => 'dir-' + d.path)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private manualTabBody() {
    Column({ space: 10 }) {
      Text('电脑目录路径')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .width('100%')
      TextInput({
        text: this.manualDir,
        placeholder: '例如 D:\\work\\project 或 /Users/me/project'
      })
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rInput)
        .height(44)
        .onChange((v: string) => {
          this.manualDir = v;
        })

      Text('新建子文件夹名（可选，留空则直接使用上方目录）')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 2 })
      TextInput({
        text: this.manualSub,
        placeholder: '例如 my-new-app'
      })
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .backgroundColor(Tokens.surface2)
        .borderRadius(Tokens.rInput)
        .height(44)
        .onChange((v: string) => {
          this.manualSub = v;
        })

      Text(this.resolvedManualPath() === ''
        ? '请至少填写电脑目录路径或新工作区名称'
        : ('目标路径：' + this.resolvedManualPath()))
        .fontSize(Tokens.fsFoot)
        .fontFamily('monospace')
        .fontColor(Tokens.dim2)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.dim)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rInput)
          .height(44)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
        Text(this.creating ? '创建中...' : '创建会话')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .backgroundColor(this.resolvedManualPath() === '' ? Tokens.surface3 : Tokens.accent)
          .borderRadius(Tokens.rInput)
          .height(44)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            const target: string = this.resolvedManualPath();
            if (target === '') {
              return;
            }
            Haptics.tap();
            this.onCreateInDir(target, this.selectedBackend);
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row() {
        Text('选择或新建工作区')
          .fontSize(Tokens.fsTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        Text('×')
          .fontSize(20)
          .fontColor(Tokens.dim)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.surface2)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            Haptics.tap();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.enabledBackends.length >= 2) {
        Column({ space: 6 }) {
          Text('选择 Agent 引擎')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .width('100%')
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.enabledBackends, (b: BackendInfo) => {
                Text(b.label)
                  .fontSize(Tokens.fsFoot)
                  .fontWeight(this.selectedBackend === b.id ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.selectedBackend === b.id ? Tokens.accentInk : Tokens.dim)
                  .backgroundColor(this.selectedBackend === b.id ? Tokens.accent : Tokens.surface2)
                  .borderRadius(Tokens.rPill)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                  .onClick(() => {
                    Haptics.tap();
                    this.selectedBackend = b.id;
                  })
              }, (b: BackendInfo) => b.id)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          Text('提示：切换任意引擎均通过电脑端 DSH 内置网关中转，使用期间电脑端 DSH 需保持启动。')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 18, right: 18, bottom: 10 })
      }

      Row({ space: 6 }) {
        this.tabPill('pick', '常用工作区')
        this.tabPill('browse', '浏览电脑目录')
        this.tabPill('manual', '手动输入')
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 10 })

      Scroll() {
        Column() {
          if (this.tab === 'browse') {
            this.browseTabBody()
          } else if (this.tab === 'manual') {
            this.manualTabBody()
          } else {
            this.pickTabBody()
          }
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 2, bottom: this.bottomInset + 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 460 })
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
  }
}
