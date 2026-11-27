import { Api, BackendInfo } from '../common/Api';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { HintLabel } from '../common/Widgets';

/**
 * 电脑端多智能体引擎管理二级子页（DSH / Codex / Claude Code / OpenCode / Antigravity）：
 * - 进入时立刻读取 Api.cachedBackends() 静态缓存，零等待零白屏闪烁；
 * - 后台静默向网关拉取最新状态，支持手动「刷新检测」实时重扫。
 */
@Component
export struct AgentEnginesPanel {
  api: Api = new Api('', '');

  @State private backends: BackendInfo[] = [];
  @State private backendsLoading: boolean = false;
  @State private backendsHint: string = '';
  @State private togglingBackend: string = '';
  @State private entered: boolean = true;

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  private enterTimer: number = -1;

  aboutToAppear(): void {
    const cached: BackendInfo[] = Api.cachedBackends();
    if (cached.length > 0) {
      this.backends = cached;
    }
    if (Motion.isFlagship(this.motionMode)) {
      this.entered = false;
      this.enterTimer = setTimeout(() => {
        this.enterTimer = -1;
        this.entered = true;
      }, 16);
    } else {
      this.entered = true;
    }
    void this.loadBackends(false);
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private async loadBackends(refresh: boolean): Promise<void> {
    if (refresh || this.backends.length === 0) {
      this.backendsLoading = true;
    }
    this.backendsHint = '';
    try {
      const rows: BackendInfo[] = await this.api.backends(refresh);
      this.backends = rows;
      if (refresh) {
        Toast.ok('已刷新电脑端智能体引擎');
      }
    } catch (e) {
      const msg: string = (e as Error).message ?? '';
      if (this.backends.length === 0) {
        if (msg.indexOf('404') >= 0) {
          this.backendsHint = '电脑端网关尚未加载多引擎模块，重启电脑端 Agent Mobile 网关后点击「刷新检测」即可启用 Codex / Claude / OpenCode / Antigravity。';
        } else if (msg !== '') {
          this.backendsHint = '检测失败：' + msg;
        }
      } else if (refresh && msg !== '') {
        Toast.err('刷新失败：' + msg);
      }
    } finally {
      this.backendsLoading = false;
    }
  }

  private async onToggleBackend(b: BackendInfo, want: boolean): Promise<void> {
    if (b.id === 'dsh' || this.togglingBackend !== '') {
      return;
    }
    Haptics.toggle(want);
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

  build() {
    Column() {
      Row() {
        Row() {
          Text('已检测引擎')
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
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accent)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accentSoft)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            if (this.backendsLoading) {
              return;
            }
            Haptics.tap();
            void this.loadBackends(true);
          })
      }
      .width('100%')
      .padding({ left: 6, right: 4, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(Motion.bloomHeaderOpacityAnim(0, this.motionMode))
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(Motion.bloomHeaderScaleAnim(0, this.motionMode))

      if (this.backends.length > 0) {
        Column({ space: 9 }) {
          ForEach(this.backends, (b: BackendInfo, idx: number) => {
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
            .backgroundColor(Mat.cardBg(this.hdsOn))
            .border(Mat.cardBorder(this.hdsOn))
            .shadow(Mat.rowShadow(this.hdsOn))
            .borderRadius(Tokens.rRow)
            .clip(true)
            .animation(null)
            .opacity(this.entered ? 1 : 0)
            .animation(Motion.bloomOpacityAnim(idx, this.motionMode))
            .scale({
              x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
              y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
              centerX: '50%',
              centerY: '50%'
            })
            .animation(Motion.bloomScaleAnim(idx, this.motionMode))
          }, (b: BackendInfo) => b.id + ':' + String(b.enabled) + ':' + String(b.installed))
        }
        .width('100%')
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
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(Motion.bloomOpacityAnim(0, this.motionMode))
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(Motion.bloomScaleAnim(0, this.motionMode))
      }

      Column() {
        Text('说明：电脑端 DSH 需保持启动状态，Codex、Claude Code、OpenCode、Antigravity 等引擎均通过 DSH 内置网关中转连接；开启后的引擎会自动出现在首页「全部工作区 / 引擎筛选」与新建会话入口中。')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .lineHeight(18)
          .width('100%')
      }
      .width('100%')
      .padding({ left: 6, right: 6, top: 10 })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(Motion.bloomHeaderOpacityAnim(this.backends.length > 0 ? this.backends.length : 1, this.motionMode))
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .animation(Motion.bloomHeaderScaleAnim(this.backends.length > 0 ? this.backends.length : 1, this.motionMode))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
