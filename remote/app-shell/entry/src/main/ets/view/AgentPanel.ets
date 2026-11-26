import { Api, BackendInfo } from '../common/Api';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { SegmentOption, SlidingSegment } from '../common/SlidingSegment';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel } from '../common/Widgets';

const ANSWER_MODE_OPTIONS: SegmentOption[] = [
  { id: 'phone', label: '手机为主' },
  { id: 'desktop', label: '电脑为主' }
];

/**
 * 「Agent 引擎与控制台」面板：
 * - 多智能体后端开关（DSH / Codex / Claude Code / OpenCode / Antigravity）
 * - 谁来回答提问归属切换
 * - 电脑端预设、插件、定时任务与完整网页控制台入口
 */
@Component
export struct AgentPanel {
  api: Api = new Api('', '');
  @Prop answerMode: string = 'phone';
  @Prop answerBusy: boolean = false;
  onAnswerMode: (mode: string) => void = () => {};
  onOpenPresets: () => void = () => {};
  onOpenExtras: (mode: string) => void = () => {};
  onOpenWebConsole: () => void = () => {};

  @State private backends: BackendInfo[] = [];
  @State private backendsLoading: boolean = false;
  @State private backendsHint: string = '';
  @State private togglingBackend: string = '';

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  aboutToAppear(): void {
    void this.loadBackends(false);
  }

  private async loadBackends(refresh: boolean): Promise<void> {
    this.backendsLoading = true;
    this.backendsHint = '';
    try {
      this.backends = await this.api.backends(refresh);
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      this.backends = [];
      if (msg.indexOf('404') >= 0) {
        this.backendsHint = '电脑端网关尚未加载多引擎模块，重启电脑端 Agent Mobile 网关后点右上角「刷新检测」即可启用 Codex / Claude / OpenCode / Antigravity。';
      } else if (msg !== '') {
        this.backendsHint = '检测失败：' + msg;
      }
    } finally {
      this.backendsLoading = false;
    }
  }

  private async onToggleBackend(b: BackendInfo, want: boolean): Promise<void> {
    if (b.id === 'dsh' || this.togglingBackend !== '') {
      return;
    }
    this.togglingBackend = b.id;
    try {
      const updated: BackendInfo | null = await this.api.toggleBackend(b.id, want);
      if (updated !== null) {
        this.backends = this.backends.map((x: BackendInfo): BackendInfo => x.id === updated.id ? updated : x);
        AppStorage.setOrCreate('backendsDirty', Date.now());
        AppStorage.setOrCreate('listDirty', Date.now());
        Toast.ok(updated.label + (want ? ' 已开启' : ' 已关闭'));
      }
    } catch (e) {
      Toast.err('切换失败：' + (e as Error).message);
      void this.loadBackends(false);
    } finally {
      this.togglingBackend = '';
    }
  }

  private backendSubText(b: BackendInfo): string {
    if (b.id === 'dsh') {
      return '默认宿主引擎 · 需保持启动' + (b.version !== '' ? (' · ' + b.version) : '');
    }
    if (!b.installed) {
      return '电脑未检测到该引擎';
    }
    const ver: string = b.version !== '' ? b.version : '已就绪';
    return b.enabled ? ('已开启 · ' + ver) : ('未开启 · ' + ver);
  }

  @Builder
  answerChip(label: string, mode: string) {
    Text(label)
      .fontSize(Tokens.fsFoot)
      .fontColor(this.answerMode === mode ? Tokens.accentInk : Tokens.dim)
      .backgroundColor(this.answerMode === mode ? Tokens.accent : Tokens.surface2)
      .borderRadius(Tokens.rPill)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .margin({ left: 6 })
      .opacity(this.answerBusy ? 0.65 : 1)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        if (this.answerBusy || this.answerMode === mode) {
          return;
        }
        Haptics.tap();
        this.onAnswerMode(mode);
      })
  }

  @Builder
  entryRow(title: string, subtitle: string, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(Tokens.fsBodyLg)
          .fontColor(Tokens.fg)
          .width('100%')
        Text(subtitle)
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(17)
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 12 })

      Text('›')
        .fontSize(17)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      Haptics.tap();
      onTap();
    })
  }

  build() {
    Column() {
      // 1. 多引擎开关
      Row() {
        Row() {
          Text('电脑端智能体引擎')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .letterSpacing(1.4)
          HintLabel({
            title: '',
            tipText: '电脑端 DSH 是所有引擎的宿主网关，使用 Codex、Claude Code、OpenCode、Antigravity 时也必须保持电脑端 DSH 启动并在线。'
          })
          .margin({ left: 6 })
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)

        Text(this.backendsLoading ? '检测中…' : '刷新检测')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.accent)
          .onClick(() => {
            Haptics.tap();
            void this.loadBackends(true);
          })
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      if (this.backends.length > 0) {
        Column() {
          ForEach(this.backends, (b: BackendInfo, idx: number) => {
            Column() {
              if (idx > 0) {
                Divider().color(Tokens.lineSoft).margin({ left: 16 })
              }
              Row() {
                Column() {
                  Text(b.label)
                    .fontSize(Tokens.fsBodyLg)
                    .fontColor(Tokens.fg)
                  Text(this.backendSubText(b))
                    .fontSize(Tokens.fsFoot)
                    .fontColor(b.installed ? Tokens.dim2 : Tokens.err)
                    .margin({ top: 2 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (b.id === 'dsh') {
                  Text('默认')
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.accent)
                    .backgroundColor(Tokens.accentSoft)
                    .borderRadius(Tokens.rPill)
                    .padding({ left: 9, right: 9, top: 4, bottom: 4 })
                } else {
                  Toggle({ type: ToggleType.Switch, isOn: b.enabled })
                    .selectedColor(Tokens.accent)
                    .enabled(b.installed && this.togglingBackend !== b.id)
                    .opacity(b.installed ? 1 : 0.4)
                    .onChange((v: boolean) => {
                      if (v !== b.enabled) {
                        void this.onToggleBackend(b, v);
                      }
                    })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
            }
          }, (b: BackendInfo) => b.id + ':' + String(b.enabled) + ':' + String(b.installed))
        }
        .width('100%')
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.cardShadow(this.hdsOn))
        .borderRadius(Tokens.rGroup)
        .clip(true)
      } else {
        Column() {
          Text(this.backendsLoading
            ? '正在检测电脑端已安装的智能体引擎…'
            : (this.backendsHint !== '' ? this.backendsHint : '暂未获取到电脑端引擎列表，请点右上角「刷新检测」。'))
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim)
            .lineHeight(19)
            .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.cardShadow(this.hdsOn))
        .borderRadius(Tokens.rGroup)
      }

      Text('提示：电脑端 DSH 需保持启动状态，Codex、Claude Code、OpenCode、Antigravity 等引擎均通过 DSH 内置网关中转连接。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .padding({ left: 6, right: 6, top: 8 })

      // 2. 协作与提问策略
      Text('交互决策')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        Row() {
          Row() {
            Text('谁来回答提问')
              .fontSize(Tokens.fsBodyLg)
              .fontColor(Tokens.fg)
            HintLabel({
              title: '',
              tipText: '手机为主：打开 App 时模型的选择题直接弹到手机；电脑为主：始终由电脑端回答。'
            })
            .margin({ left: 6 })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)

          SlidingSegment({
            options: ANSWER_MODE_OPTIONS,
            selected: this.answerMode,
            disabled: this.answerBusy,
            compact: true,
            onSelect: (mode: string) => {
              this.onAnswerMode(mode);
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 13, bottom: 13 })
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)

      // 3. 预设、插件与网页控制台
      Row() {
        Text('预设与控制台')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .letterSpacing(1.4)
        HintLabel({
          title: '',
          tipText: '智能体预设、插件管理、自动化任务与完整网页控制台均依赖电脑端 DSH 提供服务，使用前请保持电脑端 DSH 启动。'
        })
        .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 18, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Column() {
        this.entryRow('智能体预设与权限', '查看和调整默认模型、系统预设与执行权限', () => {
          this.onOpenPresets();
        })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.entryRow('插件管理', '查看、启停与配置电脑端已安装扩展插件', () => {
          this.onOpenExtras('plugins');
        })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.entryRow('自动化任务', '管理电脑端定时任务与后台计划', () => {
          this.onOpenExtras('schedules');
        })
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.entryRow('电脑完整网页控制台', '免密打开电脑端完整面板，处理高级设置', () => {
          this.onOpenWebConsole();
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
