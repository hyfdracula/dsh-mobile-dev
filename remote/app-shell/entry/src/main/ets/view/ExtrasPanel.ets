import { Api } from '../common/Api';
import { Tokens } from '../common/Tokens';
import { Motion } from '../common/Motion';
import { PageHeader, TopFade } from '../common/Chrome';
import { Haptics } from '../common/Haptics';
import { ExtrasTabOpt } from './extras/ExtrasCommon';
import { PluginsView } from './extras/PluginsView';
import { SchedulesView } from './extras/SchedulesView';
import { TeamView } from './extras/TeamView';
import { WorkspaceFilesView } from './extras/WorkspaceFilesView';
import { GitChangesView } from './extras/GitChangesView';
import { TerminalView } from './extras/TerminalView';
import { LoopbackPreviewView } from './extras/LoopbackPreviewView';

const SESSION_MODES: ExtrasTabOpt[] = [
  { key: 'files', label: '文件', title: '工作区文件', subtitle: '浏览、上传、重命名与预览电脑工作区文件' },
  { key: 'git', label: 'Git', title: 'Git 变更', subtitle: '分支状态与红绿 Unified Diff 代码审阅' },
  { key: 'terminal', label: '终端', title: '工作区终端', subtitle: '受控远程交互式 Shell 与快捷指令' },
  { key: 'preview', label: '预览', title: '本机服务预览', subtitle: '实时内嵌预览电脑端白名单 localhost 端口' },
  { key: 'team', label: '团队', title: '智能体团队', subtitle: '多智能体协作开关、成员与任务板进度' },
  { key: 'plugins', label: '插件', title: '电脑端插件', subtitle: '管理宿主插件启停与动态参数配置' },
  { key: 'schedules', label: '定时', title: '自动化任务', subtitle: '查看、启停或立即执行电脑端计划任务' }
];

const GLOBAL_MODES: ExtrasTabOpt[] = [
  { key: 'plugins', label: '插件', title: '电脑端插件', subtitle: '管理宿主插件启停与动态参数配置' },
  { key: 'schedules', label: '定时', title: '自动化任务', subtitle: '查看、启停或立即执行电脑端计划任务' }
];

/**
 * 电脑侧扩展能力统一全屏壳（K4 / C1 / U3 / M1 / M2 / R8）：
 * - 完整兼容外部契约：ExtrasPanel({ mode, sessionId, api, onExit })
 * - 支持全部 7 种模式：plugins | schedules | team | files | git | terminal | preview
 * - 当 sessionId === ''（设置页打开）时聚焦展示「插件 / 定时」；会话内进入支持全量横向切换
 */
@Component
export struct ExtrasPanel {
  @Prop @Watch('onExternalMode') mode: string = 'plugins';
  @Prop sessionId: string = '';
  api: Api = new Api('', '');
  onExit: () => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private curMode: string = 'plugins';
  @State private reloadTick: number = 0;

  aboutToAppear(): void {
    this.curMode = this.resolveValidMode(this.mode);
  }

  onExternalMode(): void {
    const resolved: string = this.resolveValidMode(this.mode);
    if (resolved !== this.curMode) {
      this.curMode = resolved;
    }
  }

  private availableModes(): ExtrasTabOpt[] {
    return this.sessionId !== '' ? SESSION_MODES : GLOBAL_MODES;
  }

  private resolveValidMode(raw: string): string {
    const list: ExtrasTabOpt[] = this.availableModes();
    for (let i = 0; i < list.length; i++) {
      if (list[i].key === raw) {
        return raw;
      }
    }
    return list[0].key;
  }

  private currentMeta(): ExtrasTabOpt {
    const list: ExtrasTabOpt[] = this.availableModes();
    for (let i = 0; i < list.length; i++) {
      if (list[i].key === this.curMode) {
        return list[i];
      }
    }
    return list[0];
  }

  private title(): string {
    return this.currentMeta().title;
  }

  private subtitle(): string {
    return this.currentMeta().subtitle;
  }

  private reloadCurrent(): void {
    this.reloadTick = this.reloadTick + 1;
  }

  private contentTopPad(): number {
    return this.topInset + 104;
  }

  private switchMode(next: string): void {
    if (this.curMode === next) {
      return;
    }
    Haptics.tap();
    this.curMode = next;
  }

  @Builder
  private modeSwitcherBar() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.availableModes(), (opt: ExtrasTabOpt) => {
          Text(opt.label)
            .fontSize(Tokens.fsFoot)
            .fontWeight(this.curMode === opt.key ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.curMode === opt.key ? Tokens.accentInk : Tokens.dim)
            .backgroundColor(this.curMode === opt.key ? Tokens.accent : Tokens.glassBtnBg)
            .border({
              width: 1,
              color: this.curMode === opt.key ? Tokens.accent : Tokens.glassBtnLine
            })
            .borderRadius(Tokens.rPill)
            .padding({ left: 13, right: 13, top: 6, bottom: 6 })
            .animation({ duration: Motion.fade, curve: Motion.std })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              this.switchMode(opt.key);
            })
        }, (opt: ExtrasTabOpt) => opt.key)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(38)
    .margin({ top: 4 })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // 子功能视图层（带面板切换过渡动画 M2）
      if (this.curMode === 'files' && this.sessionId !== '') {
        Column() {
          WorkspaceFilesView({
            api: this.api,
            sessionId: this.sessionId,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.curMode === 'git' && this.sessionId !== '') {
        Column() {
          GitChangesView({
            api: this.api,
            sessionId: this.sessionId,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.curMode === 'terminal' && this.sessionId !== '') {
        Column() {
          TerminalView({
            api: this.api,
            sessionId: this.sessionId,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.curMode === 'preview' && this.sessionId !== '') {
        Column() {
          LoopbackPreviewView({
            api: this.api,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.curMode === 'team' && this.sessionId !== '') {
        Column() {
          TeamView({
            api: this.api,
            sessionId: this.sessionId,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.curMode === 'schedules') {
        Column() {
          SchedulesView({
            api: this.api,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else {
        Column() {
          PluginsView({
            api: this.api,
            reloadTick: this.reloadTick,
            topPad: this.contentTopPad()
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeBg)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }

      // 顶部渐隐层
      Column() {
        TopFade({ fadeHeight: this.topInset + 68 })
      }
      .width('100%')
      .hitTestBehavior(HitTestMode.None)

      // 统一顶栏 + 模式横向切换胶囊栏（左右内边距 16）
      Column() {
        Column() {
          PageHeader({
            title: this.title(),
            subtitle: this.subtitle(),
            padTop: true,
            subPageDepth: 2,
            rightKind: 'glyph',
            rightGlyph: '\u21bb',
            onBack: () => {
              this.onExit();
            },
            onRight: () => {
              this.reloadCurrent();
            }
          })

          this.modeSwitcherBar()
        }
        .width('100%')
        .constraintSize({ maxWidth: 860 })
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
  }
}
