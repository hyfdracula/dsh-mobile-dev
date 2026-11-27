import { Api, BackendInfo } from '../common/Api';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { PickerOption, PopupPicker } from '../common/PopupPicker';
import { Tokens } from '../common/Tokens';
import { HintLabel } from '../common/Widgets';

const ANSWER_MODE_OPTIONS: PickerOption[] = [
  { id: 'phone', label: '手机为主', sub: '打开 App 时模型的提问优先弹到手机' },
  { id: 'desktop', label: '电脑为主', sub: '始终由电脑端回答模型提问' }
];

/**
 * 「Agent 引擎与控制台」面板：
 * - 多智能体引擎二级管理入口（实时读缓存 + 二级子页刷新切换）
 * - 谁来回答提问（64-65s 锚点下拉卡）
 * - 电脑端预设、插件、定时任务与完整网页控制台入口
 */
@Component
export struct AgentPanel {
  api: Api = new Api('', '');
  @Prop answerMode: string = 'phone';
  @Prop answerBusy: boolean = false;
  onAnswerMode: (mode: string) => void = () => {};
  onOpenEngines: () => void = () => {};
  onOpenPresets: () => void = () => {};
  onOpenExtras: (mode: string) => void = () => {};
  onOpenWebConsole: () => void = () => {};

  @State private cachedList: BackendInfo[] = [];
  @State private entered: boolean = true;

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('backendsDirty') @Watch('onBackendsDirty') backendsDirty: number = 0;
  private enterTimer: number = -1;
  private wave: BloomWaveTracker = new BloomWaveTracker();

  aboutToAppear(): void {
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 24);
    } else {
      this.entered = true;
    }
    this.syncCached();
    if (this.cachedList.length === 0) {
      void this.prefetchEngines();
    }
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private onBackendsDirty(): void {
    this.syncCached();
  }

  private syncCached(): void {
    const cached: BackendInfo[] = Api.cachedBackends();
    if (cached.length > 0) {
      this.cachedList = cached;
    }
  }

  private async prefetchEngines(): Promise<void> {
    try {
      const rows: BackendInfo[] = await this.api.backends(false);
      this.cachedList = rows;
    } catch (_e) {
      // 未连接电脑时保持默认提示文案
    }
  }

  private enginesSummary(): string {
    if (this.cachedList.length === 0) {
      return '管理 DSH / Codex / Claude / OpenCode / Antigravity';
    }
    const enabledNames: string[] = [];
    for (let i = 0; i < this.cachedList.length; i++) {
      const b: BackendInfo = this.cachedList[i];
      if (b.id === 'dsh' || (b.installed && b.enabled)) {
        enabledNames.push(b.label);
      }
    }
    if (enabledNames.length === 0) {
      return '共检测 ' + String(this.cachedList.length) + ' 个引擎';
    }
    return '已开启 ' + String(enabledNames.length) + ' 个 · ' + enabledNames.join(' / ');
  }

  @Builder
  entryCard(title: string, subtitle: string, waveKey: string, fallbackDistVp: number, onTap: () => void) {
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
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: 12 })

      if (Motion.isFlagship(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Tokens.dim2])
      } else {
        Text('›')
          .fontSize(17)
          .fontColor(Tokens.dim2)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .borderRadius(Tokens.rRow)
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onAreaChange((_old: Area, area: Area) => {
      this.wave.record(waveKey, area);
    })
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(this.entered
      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .animation(this.entered
      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf(waveKey, fallbackDistVp), this.motionMode)
      : null)
    .onClick(() => {
      Haptics.tap();
      onTap();
    })
  }

  build() {
    Column() {
      // 1. 多引擎管理（二级菜单，进入即展示缓存并在后台静默刷新）
      Row() {
        Text('智能体引擎')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .letterSpacing(1.4)
        HintLabel({
          title: '',
          tipText: '点开二级菜单即可查看并启停电脑端安装的 DSH、Codex、Claude Code、OpenCode、Antigravity 等智能体引擎。'
        })
        .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('hdr:0', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:0', 0), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:0', 0), this.motionMode)
        : null)

      this.entryCard('电脑端智能体引擎', this.enginesSummary(), 'c:engines', 46, () => {
        this.onOpenEngines();
      })

      // 2. 协作与提问策略
      Text('交互决策')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:1', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:1', 108), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:1', 108), this.motionMode)
          : null)

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

        PopupPicker({
          options: ANSWER_MODE_OPTIONS,
          selected: this.answerMode,
          title: '谁来回答提问',
          disabled: this.answerBusy,
          popupWidth: 236,
          onSelect: (mode: string) => {
            this.onAnswerMode(mode);
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rRow)
      .clip(true)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('c:answer', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('c:answer', 152), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('c:answer', 152), this.motionMode)
        : null)

      // 3. 预设、插件与网页控制台（逐条独立卡片）
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
      .padding({ left: 6, right: 6, top: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('hdr:2', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:2', 216), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:2', 216), this.motionMode)
        : null)

      Column({ space: 9 }) {
        this.entryCard('智能体预设与权限', '查看和调整默认模型、系统预设与执行权限', 'c:presets', 264, () => {
          this.onOpenPresets();
        })
        this.entryCard('插件管理', '查看、启停与配置电脑端已安装扩展插件', 'c:plugins', 338, () => {
          this.onOpenExtras('plugins');
        })
        this.entryCard('自动化任务', '管理电脑端定时任务与后台计划', 'c:sched', 412, () => {
          this.onOpenExtras('schedules');
        })
        this.entryCard('电脑完整网页控制台', '免密打开电脑端完整面板，处理高级设置', 'c:console', 486, () => {
          this.onOpenWebConsole();
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
