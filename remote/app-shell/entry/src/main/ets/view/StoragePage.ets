import { common } from '@kit.AbilityKit';
import { AppCtx } from '../common/AppCtx';
import { PageHeader, TopFade } from '../common/Chrome';
import { Haptics } from '../common/Haptics';
import {
  Bucket,
  CacheItem,
  clearCache,
  clearCacheBucket,
  DeviceSpace,
  deviceSpace,
  scanStorageSummary,
  sizeText,
  StorageSummary
} from '../common/Storage';
import { Toast } from '../common/Toast';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Tokens } from '../common/Tokens';
import { EmptyState } from '../common/Widgets';

const RING_WIDTH: number = 18;
const RING_SIZE: number = 172;

interface FileDetailRow {
  id: string;
  name: string;
  sizeText: string;
}

/**
 * 存储空间（F10 / L4）：
 * 异步非阻塞扫描本机沙箱存储，严格区分「可清理缓存（msgs / temp / files）」与
 * 独立的只读「应用配置与凭据（prefsBytes）」，支持分类单项清理、一键全清与手机容量进度展示。
 */
@Component
export struct StoragePage {
  onExit: () => void = () => {};

  @State private buckets: Bucket[] = [];
  @State private cacheBytes: number = 0;
  @State private prefsBytes: number = 0;
  @State private prefsCount: number = 0;
  @State private device: DeviceSpace = { free: 0, total: 0 };
  @State private loading: boolean = true;
  @State private clearing: boolean = false;
  @State private detailOn: boolean = false;
  @State private detailKey: string = '';
  @State private entered: boolean = false;

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') @Watch('onThemeChange') themeDark: boolean = true;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  private ringSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private ring: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.ringSettings);
  private canvasReady: boolean = false;
  private scanTimer: number = -1;
  private clearTimer: number = -1;
  private enterTimer: number = -1;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.entered = !Motion.isFlagship(this.motionMode);
    this.scheduleScan(true);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.scanTimer >= 0) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
    if (this.clearTimer >= 0) {
      clearTimeout(this.clearTimer);
      this.clearTimer = -1;
    }
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  private onThemeChange(): void {
    if (!this.canvasReady || this.loading) {
      return;
    }
    setTimeout(() => {
      if (!this.disposed && this.canvasReady) {
        this.drawRing();
      }
    }, 20);
  }

  private scheduleScan(showSpinner: boolean): void {
    if (this.scanTimer >= 0) {
      clearTimeout(this.scanTimer);
      this.scanTimer = -1;
    }
    if (showSpinner) {
      this.loading = true;
    }
    this.scanTimer = setTimeout(() => {
      this.scanTimer = -1;
      if (this.disposed) {
        return;
      }
      this.performScan();
    }, 30);
  }

  private performScan(): void {
    try {
      const ctx: common.UIAbilityContext = AppCtx.ability();
      const summary: StorageSummary = scanStorageSummary(ctx);
      this.buckets = summary.buckets;
      this.cacheBytes = summary.cacheBytes;
      this.prefsBytes = summary.prefsBytes;
      this.prefsCount = summary.prefsItems.length;
      this.device = deviceSpace(ctx);
    } catch (e) {
      this.buckets = [];
      this.cacheBytes = 0;
      this.prefsBytes = 0;
      this.prefsCount = 0;
      this.device = { free: 0, total: 0 };
    }
    this.loading = false;
    if (!this.entered) {
      if (Motion.isFlagship(this.motionMode)) {
        if (this.enterTimer < 0) {
          this.enterTimer = setTimeout(() => {
            this.enterTimer = -1;
            this.entered = true;
          }, 16);
        }
      } else {
        this.entered = true;
      }
    }
    setTimeout(() => {
      if (!this.disposed && this.canvasReady) {
        this.drawRing();
      }
    }, 20);
  }

  private bucketColor(key: string): string {
    if (key === 'msgs') {
      return Tokens.bucket0;
    }
    if (key === 'temp') {
      return Tokens.bucket1;
    }
    if (key === 'files') {
      return Tokens.bucket2;
    }
    return Tokens.bucket3;
  }

  private bucketOf(key: string): Bucket | null {
    for (let i = 0; i < this.buckets.length; i++) {
      if (this.buckets[i].key === key) {
        return this.buckets[i];
      }
    }
    return null;
  }

  private percentOf(bytes: number): number {
    if (this.cacheBytes <= 0 || bytes <= 0) {
      return 0;
    }
    const raw: number = Math.round((bytes / this.cacheBytes) * 100);
    if (raw === 0 && bytes > 0) {
      return 1;
    }
    return raw > 100 ? 100 : raw;
  }

  private barWidthPct(bytes: number): string {
    if (this.cacheBytes <= 0 || bytes <= 0) {
      return '0%';
    }
    const raw: number = (bytes / this.cacheBytes) * 100;
    const clamped: number = raw < 3 ? 3 : (raw > 100 ? 100 : raw);
    return String(Math.round(clamped)) + '%';
  }

  private drawRing(): void {
    const ctx: CanvasRenderingContext2D = this.ring;
    const w: number = ctx.width;
    const h: number = ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    ctx.clearRect(0, 0, w, h);
    const cx: number = w / 2;
    const cy: number = h / 2;
    const radius: number = Math.min(w, h) / 2 - RING_WIDTH / 2 - 2;

    // 底轨：深浅色主题切换时自动跟随 Tokens.surface3；0 B 时呈现干净空环
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.strokeStyle = Tokens.surface3;
    ctx.lineWidth = RING_WIDTH;
    ctx.lineCap = 'butt';
    ctx.stroke();

    const total: number = this.cacheBytes;
    if (total <= 0) {
      return;
    }

    let nonZeroCount: number = 0;
    for (let i = 0; i < this.buckets.length; i++) {
      if (this.buckets[i].bytes > 0) {
        nonZeroCount++;
      }
    }
    const gap: number = nonZeroCount > 1 ? 0.04 : 0;
    let start: number = -Math.PI / 2;
    for (let i = 0; i < this.buckets.length; i++) {
      const b: Bucket = this.buckets[i];
      if (b.bytes <= 0) {
        continue;
      }
      const sweep: number = (b.bytes / total) * Math.PI * 2;
      const from: number = start + (sweep > gap * 2 ? gap / 2 : 0);
      const to: number = start + sweep - (sweep > gap * 2 ? gap / 2 : 0);
      ctx.beginPath();
      ctx.arc(cx, cy, radius, from, to);
      ctx.strokeStyle = this.bucketColor(b.key);
      ctx.lineWidth = RING_WIDTH;
      ctx.lineCap = 'butt';
      ctx.stroke();
      start += sweep;
    }
  }

  private confirmClearAll(): void {
    if (this.cacheBytes <= 0 || this.clearing) {
      return;
    }
    Haptics.tap();
    AppCtx.confirm(
      '一键清理全部缓存',
      '将清理本机对话快照、图片与临时缓存以及下载缓存（共 ' + sizeText(this.cacheBytes) +
        '）。电脑端会话记录及手机配对凭据不会受影响。',
      '立即清理',
      () => {
        this.runClearAll();
      },
      true
    );
  }

  private runClearAll(): void {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    this.clearTimer = setTimeout(() => {
      this.clearTimer = -1;
      if (this.disposed) {
        return;
      }
      let freed: number = 0;
      try {
        freed = clearCache(AppCtx.ability());
      } catch (e) {
        freed = 0;
      }
      this.clearing = false;
      this.performScan();
      Toast.ok(freed > 0 ? '已清理 ' + sizeText(freed) : '可清理缓存已清空');
    }, 20);
  }

  private confirmClearBucket(b: Bucket): void {
    if (b.bytes <= 0 || this.clearing) {
      return;
    }
    Haptics.tap();
    AppCtx.confirm(
      '清理' + b.name,
      '将释放 ' + sizeText(b.bytes) + ' 空间，不影响电脑端数据与已配对信息。',
      '清理',
      () => {
        this.runClearBucket(b.key, b.name);
      },
      true
    );
  }

  private runClearBucket(bucketKey: string, bucketName: string): void {
    if (this.clearing) {
      return;
    }
    this.clearing = true;
    this.clearTimer = setTimeout(() => {
      this.clearTimer = -1;
      if (this.disposed) {
        return;
      }
      let freed: number = 0;
      try {
        freed = clearCacheBucket(AppCtx.ability(), bucketKey);
      } catch (e) {
        freed = 0;
      }
      this.clearing = false;
      this.performScan();
      Toast.ok(freed > 0 ? '已清理' + bucketName + ' ' + sizeText(freed) : bucketName + '已清空');
    }, 20);
  }

  private deviceUsedBytes(): number {
    if (this.device.total <= 0) {
      return 0;
    }
    const used: number = this.device.total - this.device.free;
    return used > 0 ? used : 0;
  }

  private deviceUsedPercent(): number {
    if (this.device.total <= 0) {
      return 0;
    }
    const pct: number = Math.round((this.deviceUsedBytes() / this.device.total) * 100);
    if (pct < 0) {
      return 0;
    }
    return pct > 100 ? 100 : pct;
  }

  private deviceBarColor(): string {
    const pct: number = this.deviceUsedPercent();
    if (pct >= 90) {
      return Tokens.err;
    }
    if (pct >= 75) {
      return Tokens.bucket1;
    }
    return Tokens.accent;
  }

  private deviceSpaceLabel(): string {
    if (this.device.total <= 0) {
      return '暂无法读取设备容量';
    }
    return '可用 ' + sizeText(this.device.free) + ' / 总容量 ' + sizeText(this.device.total);
  }

  private detailRows(): FileDetailRow[] {
    const b: Bucket | null = this.bucketOf(this.detailKey);
    const rows: FileDetailRow[] = [];
    if (b === null) {
      return rows;
    }
    const limit: number = Math.min(b.items.length, 30);
    for (let i = 0; i < limit; i++) {
      const it: CacheItem = b.items[i];
      const cut: number = Math.max(it.path.lastIndexOf('/'), it.path.lastIndexOf('\\'));
      const leaf: string = cut >= 0 ? it.path.slice(cut + 1) : it.path;
      const row: FileDetailRow = {
        id: String(i) + ':' + it.path,
        name: leaf !== '' ? leaf : it.path,
        sizeText: sizeText(it.size)
      };
      rows.push(row);
    }
    return rows;
  }

  @Builder
  sectionLabel(text: string, topMargin: number = 18, bloomIdx: number = 0) {
    Text(text)
      .fontSize(Tokens.fsCaption)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.4)
      .margin({ left: 6, top: topMargin, bottom: 8 })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(Motion.bloomHeaderOpacityAnim(bloomIdx, this.motionMode))
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
        centerX: '0%',
        centerY: '50%'
      })
      .translate({ y: this.entered ? 0 : 6 })
      .animation(Motion.bloomHeaderScaleAnim(bloomIdx, this.motionMode))
  }

  @Builder
  detailSheet() {
    Column() {
      Row() {
        Column() {
          Text(this.bucketOf(this.detailKey) === null ? '文件明细' : (this.bucketOf(this.detailKey) as Bucket).name)
            .fontSize(Tokens.fsTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
          Text('按占用大小排序，最多列出前 30 项')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.bucketOf(this.detailKey) !== null) {
          Text(sizeText((this.bucketOf(this.detailKey) as Bucket).bytes))
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(FontWeight.Medium)
            .fontFamily('monospace')
            .fontColor(Tokens.fg)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6, bottom: 12 })

      if (this.detailRows().length === 0) {
        EmptyState({
          icon: $r('app.media.ic_set_disk'),
          title: '这一分类当前为空',
          hint: '没有占用本地存储空间的缓存文件'
        })
      } else {
        Row() {
          Text('文件名')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .layoutWeight(1)
          Text('大小')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ bottom: 8 })

        Divider().color(Tokens.lineSoft)

        List() {
          ForEach(this.detailRows(), (row: FileDetailRow) => {
            ListItem() {
              Column() {
                Row() {
                  Text(row.name)
                    .fontSize(Tokens.fsBody)
                    .fontColor(Tokens.fg)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text(row.sizeText)
                    .fontSize(Tokens.fsFoot)
                    .fontFamily('monospace')
                    .fontColor(Tokens.dim)
                    .textAlign(TextAlign.End)
                    .margin({ left: 12 })
                }
                .width('100%')
                .padding({ top: 11, bottom: 11 })
                .alignItems(VerticalAlign.Center)

                Divider().color(Tokens.lineSoft)
              }
            }
          }, (row: FileDetailRow) => row.id)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 18, right: 18, top: 8, bottom: this.bottomInset + 20 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  cacheOverviewCard() {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        Canvas(this.ring)
          .width(RING_SIZE)
          .height(RING_SIZE)
          .onReady(() => {
            this.canvasReady = true;
            this.drawRing();
          })

        Column() {
          Text(sizeText(this.cacheBytes))
            .fontSize(Tokens.fsDisplay)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          Text(this.cacheBytes <= 0 ? '已清空' : '可清理缓存')
            .fontSize(Tokens.fsFoot)
            .fontColor(this.cacheBytes <= 0 ? Tokens.ok : Tokens.dim)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(RING_SIZE)
      .height(RING_SIZE)
      .margin({ top: 18 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(this.buckets, (b: Bucket) => {
          Row() {
            Circle()
              .width(7)
              .height(7)
              .fill(this.bucketColor(b.key))
            Text(b.name + ' ' + String(this.percentOf(b.bytes)) + '%')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim)
              .margin({ left: 5 })
          }
          .alignItems(VerticalAlign.Center)
          .margin({ left: 7, right: 7, top: 6 })
        }, (b: Bucket) => b.key + ':' + String(b.bytes) + ':' + String(this.cacheBytes) + ':' + String(this.themeDark))
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        if (this.clearing) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Tokens.accentInk)
            .margin({ right: 6 })
        }
        Text(this.clearing ? '正在清理…' : (this.cacheBytes <= 0 ? '无需清理' : '一键清理全部缓存'))
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.cacheBytes > 0 && !this.clearing ? Tokens.accentInk : Tokens.dim2)
      }
      .width('100%')
      .height(46)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.cacheBytes > 0 && !this.clearing ? Tokens.accent : Tokens.surface2)
      .borderRadius(Tokens.rPill)
      .margin({ top: 16 })
      .opacity(this.cacheBytes > 0 && !this.clearing ? 1 : 0.72)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
      .onClick(() => {
        this.confirmClearAll();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .clip(true)
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(Motion.bloomOpacityAnim(0, this.motionMode))
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .translate({ y: this.entered ? 0 : 6 })
    .animation(Motion.bloomScaleAnim(0, this.motionMode))
  }

  @Builder
  bucketDetailCard() {
    Column({ space: 9 }) {
      ForEach(this.buckets, (b: Bucket, i: number) => {
        Row() {
          Column() {
            Row() {
              Circle()
                .width(9)
                .height(9)
                .fill(this.bucketColor(b.key))
              Text(b.name)
                .fontSize(Tokens.fsBodyLg)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.fg)
                .margin({ left: 8 })
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(sizeText(b.bytes))
                .fontSize(Tokens.fsBody)
                .fontFamily('monospace')
                .fontColor(Tokens.dim)
                .margin({ left: 8 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            Text(b.hint)
              .fontSize(Tokens.fsFoot)
              .fontColor(Tokens.dim2)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 3 })

            // 迷你横向占比进度条
            Stack({ alignContent: Alignment.Start }) {
              Row()
                .width('100%')
                .height(5)
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface3)
              if (b.bytes > 0) {
                Row()
                  .width(this.barWidthPct(b.bytes))
                  .height(5)
                  .borderRadius(Tokens.rPill)
                  .backgroundColor(this.bucketColor(b.key))
              }
            }
            .width('100%')
            .height(5)
            .margin({ top: 8 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ top: 13, bottom: 13, left: 14, right: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.99 })
          .onClick(() => {
            Haptics.soft();
            this.detailKey = b.key;
            this.detailOn = true;
          })

          Row({ space: 6 }) {
            Text(b.bytes > 0 ? '清理' : '已空')
              .fontSize(Tokens.fsCaption)
              .fontWeight(FontWeight.Medium)
              .fontColor(b.bytes > 0 && !this.clearing ? Tokens.err : Tokens.dim2)
              .backgroundColor(b.bytes > 0 && !this.clearing ? Tokens.intrBg : Tokens.surface2)
              .borderRadius(Tokens.rPill)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .opacity(b.bytes > 0 && !this.clearing ? 1 : 0.65)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.confirmClearBucket(b);
              })

            if (Motion.isFlagship(this.motionMode)) {
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(13)
                .fontColor([Tokens.dim2])
                .margin({ left: 2, right: 2 })
                .onClick(() => {
                  Haptics.soft();
                  this.detailKey = b.key;
                  this.detailOn = true;
                })
            } else {
              Text('›')
                .fontSize(16)
                .fontColor(Tokens.dim2)
                .padding({ left: 2, right: 4 })
                .onClick(() => {
                  Haptics.soft();
                  this.detailKey = b.key;
                  this.detailOn = true;
                })
            }
          }
          .padding({ right: 12 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .clip(true)
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(Motion.bloomOpacityAnim(1 + i, this.motionMode))
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .translate({ y: this.entered ? 0 : 6 })
        .animation(Motion.bloomScaleAnim(1 + i, this.motionMode))
      }, (b: Bucket) => b.key + ':' + String(b.bytes) + ':' + String(this.cacheBytes) + ':' + String(this.themeDark))
    }
    .width('100%')
  }

  @Builder
  prefsProtectedCard() {
    Column() {
      Row() {
        Circle()
          .width(9)
          .height(9)
          .fill(this.bucketColor('prefs'))
        Text('应用配置与凭据')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .margin({ left: 8 })
          .layoutWeight(1)
        Text('受保护')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim)
          .backgroundColor(Tokens.surface2)
          .borderRadius(Tokens.rPill)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .margin({ right: 8 })
        Text(sizeText(this.prefsBytes))
          .fontSize(Tokens.fsBody)
          .fontFamily('monospace')
          .fontColor(Tokens.fg)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('包含配对信息、电脑列表、草稿与偏好设置（共 ' + String(this.prefsCount) + ' 项）。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim)
        .lineHeight(18)
        .width('100%')
        .margin({ top: 8 })

      Text('不包含在上方可清理缓存中，清理缓存不会丢失配对。')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .lineHeight(18)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .alignItems(HorizontalAlign.Start)
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(Motion.bloomOpacityAnim(1 + this.buckets.length, this.motionMode))
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .translate({ y: this.entered ? 0 : 6 })
    .animation(Motion.bloomScaleAnim(1 + this.buckets.length, this.motionMode))
  }

  @Builder
  deviceCapacityCard() {
    Column() {
      Row() {
        Text('手机存储容量')
          .fontSize(Tokens.fsBodyLg)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .layoutWeight(1)
        if (this.device.total > 0) {
          Text('已用 ' + String(this.deviceUsedPercent()) + '%')
            .fontSize(Tokens.fsCaption)
            .fontFamily('monospace')
            .fontColor(Tokens.dim)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.deviceSpaceLabel())
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .width('100%')
        .margin({ top: 5 })

      if (this.device.total > 0) {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(8)
            .borderRadius(Tokens.rPill)
            .backgroundColor(Tokens.surface3)
          Row()
            .width(String(this.deviceUsedPercent()) + '%')
            .height(8)
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.deviceBarColor())
        }
        .width('100%')
        .height(8)
        .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .alignItems(HorizontalAlign.Start)
    .animation(null)
    .opacity(this.entered ? 1 : 0)
    .animation(Motion.bloomOpacityAnim(2 + this.buckets.length, this.motionMode))
    .scale({
      x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
      centerX: '50%',
      centerY: '50%'
    })
    .translate({ y: this.entered ? 0 : 6 })
    .animation(Motion.bloomScaleAnim(2 + this.buckets.length, this.motionMode))
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(30)
            .height(30)
            .color(Tokens.accent)
          Text('正在统计本机存储空间…')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.dim2)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            Column() {
              this.sectionLabel('可清理缓存', 6, 0)
              this.cacheOverviewCard()

              this.sectionLabel('可清理分类明细', 16, 1)
              this.bucketDetailCard()

              this.sectionLabel('应用配置与凭据', 16, 1 + this.buckets.length)
              this.prefsProtectedCard()

              this.sectionLabel('设备存储', 16, 2 + this.buckets.length)
              this.deviceCapacityCard()

              Text('缓存仅用于本地加速首屏与预览，清理后不影响电脑端任何会话与文件；配对凭据、电脑列表与偏好设置会安全保留。')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.dim2)
                .lineHeight(18)
                .margin({ top: 12, left: 4, right: 4 })
                .animation(null)
                .opacity(this.entered ? 1 : 0)
                .animation(Motion.bloomHeaderOpacityAnim(3 + this.buckets.length, this.motionMode))
                .scale({
                  x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
                  y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
                  centerX: '0%',
                  centerY: '50%'
                })
                .translate({ y: this.entered ? 0 : 6 })
                .animation(Motion.bloomHeaderScaleAnim(3 + this.buckets.length, this.motionMode))
            }
            .width('100%')
            .constraintSize({ maxWidth: this.wideScreen ? 680 : 520 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({
            left: 16,
            right: 16,
            top: this.topInset + 64,
            bottom: this.bottomInset + 40
          })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }

      TopFade({ fadeHeight: this.topInset + 68 })
      Column() {
        PageHeader({
          title: '存储空间',
          padTop: true,
          rightKind: 'glyph',
          rightGlyph: '\u21bb',
          onBack: () => {
            this.onExit();
          },
          onRight: () => {
            Haptics.soft();
            this.scheduleScan(false);
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .bindSheet($$this.detailOn, this.detailSheet(),
      Mat.sheetOpts(this.hdsOn, SheetSize.MEDIUM, () => {
        this.detailOn = false;
      }, true, true))
  }
}
