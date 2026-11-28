import { AppCtx } from '../common/AppCtx';
import { CardIcon } from '../common/CardIcon';
import { Drafts } from '../common/Drafts';
import { Haptics } from '../common/Haptics';
import { Marks } from '../common/Marks';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { Outbox } from '../common/Outbox';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';

/**
 * 「数据与存储」：存储空间入口 + 应用数据清理 + 数据流说明（诊断日志统一归口在关于页）。
 */
@Component
export struct DataStoragePanel {
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  onStorage: () => void = () => {};

  @State private draftN: number = 0;
  @State private outN: number = 0;
  @State private markN: number = 0;
  @State private entered: boolean = true;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
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
    this.reloadCounts();
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private onRefreshTick(): void {
    this.reloadCounts();
  }

  private reloadCounts(): void {
    this.draftN = Drafts.count();
    this.outN = Outbox.countAll();
    this.markN = Marks.count();
  }

  private confirmClearData(what: string): void {
    Haptics.tap();
    const label: string = what === 'draft' ? '草稿' : (what === 'outbox' ? '待发送' : '阅读标记');
    const msg: string = what === 'draft'
      ? '所有会话里未发送的草稿都会被删除。'
      : (what === 'outbox'
        ? '重启后尚未重发的待发消息会被清除，已发出的消息不受影响。'
        : '所有会话卡片上的「已完成 / 已中断」标记会被清除。');
    AppCtx.confirm('清空' + label, msg, '清空', () => {
      if (what === 'draft') {
        Drafts.clearAll();
      } else if (what === 'outbox') {
        Outbox.clearAll();
      } else {
        Marks.clearAll();
      }
      this.reloadCounts();
      Toast.ok('已清空' + label);
    }, true);
  }

  @Builder
  dataRowCard(label: string, n: number, what: string, waveKey: string, fallbackDistVp: number,
    iconSymbol: Resource, iconTone: string) {
    Row() {
      CardIcon({
        symbol: iconSymbol,
        tone: iconTone,
        entered: this.entered,
        distanceVp: this.wave.distanceOf(waveKey, fallbackDistVp)
      })
      .margin({ right: 12 })

      Text(label)
        .fontSize(Tokens.fsBodyLg)
        .fontColor(Tokens.fg)
        .layoutWeight(1)
      Text(String(n) + ' 条')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
      if (n > 0) {
        Text('清空')
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.err)
          .padding({ left: 10, right: 4, top: 4, bottom: 4 })
          .margin({ left: 6 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => {
            this.confirmClearData(what);
          })
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
  }

  @Builder
  noteCard(k: string, v: string, mono: boolean, waveKey: string, fallbackDistVp: number) {
    Row() {
      Text(k)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .width(96)
      Text(v)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'sans-serif')
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.rowShadow(this.hdsOn))
    .borderRadius(Tokens.rRow)
    .clip(true)
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
  }

  build() {
    Column() {
      Text('空间管理')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 6, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:space', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:space', 0), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:space', 0), this.motionMode)
          : null)

      // 0. 存储空间
      Row() {
        CardIcon({
          symbol: $r('sys.symbol.externaldrive_fill'),
          tone: 'blue',
          entered: this.entered,
          distanceVp: this.wave.distanceOf('card:storage', 54)
        })
        .margin({ right: 12 })

        Column() {
          Text('存储空间')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.fg)
          Text('本机缓存占用、分类明细与一键清理')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

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
        this.wave.record('card:storage', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('card:storage', 54), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('card:storage', 54), this.motionMode)
        : null)
      .onClick(() => {
        Haptics.tap();
        this.onStorage();
      })

      Text('应用数据')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:data', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:data', 132), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:data', 132), this.motionMode)
          : null)

      Column({ space: 9 }) {
        this.dataRowCard('草稿', this.draftN, 'draft', 'data:draft', 176, $r('sys.symbol.square_and_pencil'), 'amber')
        this.dataRowCard('待发送（重启兜底）', this.outN, 'outbox', 'data:outbox', 242, $r('sys.symbol.paperplane_fill'), 'blue')
        this.dataRowCard('阅读标记', this.markN, 'marks', 'data:marks', 308, $r('sys.symbol.checkmark_circle_fill'), 'blue')
      }
      .width('100%')

      Text('数据说明')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 16, bottom: 8 })
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('hdr:notes', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('hdr:notes', 384), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('hdr:notes', 384), this.motionMode)
          : null)

      Column({ space: 9 }) {
        this.noteCard('本地设置', '服务器地址 · 令牌 · 主题', false, 'note:0', 428)
        this.noteCard('会话快照缓存', '可随时在存储空间清理，不影响电脑端记录', false, 'note:1', 494)
        this.noteCard('本地缓存', '可按分类清理，不影响电脑与配对信息', false, 'note:2', 560)
        this.noteCard('上传文件', '保存在电脑 .dsh/mobile-uploads', true, 'note:3', 626)
        this.noteCard('归档状态', '与桌面控制台共享同一份数据', false, 'note:4', 692)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
