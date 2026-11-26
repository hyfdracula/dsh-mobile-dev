import { AppCtx } from '../common/AppCtx';
import { Drafts } from '../common/Drafts';
import { Haptics } from '../common/Haptics';
import { Marks } from '../common/Marks';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
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
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  aboutToAppear(): void {
    this.reloadCounts();
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
  dataRow(label: string, n: number, what: string) {
    Row() {
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
  }

  @Builder
  note(k: string, v: string, mono: boolean) {
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
  }

  build() {
    Column() {
      Text('空间管理')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 6, bottom: 8 })

      Column() {
        Row() {
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
          this.onStorage();
        })
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(0, this.motionMode))

      Text('应用数据')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        this.dataRow('草稿', this.draftN, 'draft')
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.dataRow('待发送（重启兜底）', this.outN, 'outbox')
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.dataRow('阅读标记', this.markN, 'marks')
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(1, this.motionMode))

      Text('数据说明')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .margin({ left: 6, top: 18, bottom: 8 })

      Column() {
        this.note('本地设置', '服务器地址 · 令牌 · 主题', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('会话快照缓存', '可随时在存储空间清理，不影响电脑端记录', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('本地缓存', '可按分类清理，不影响电脑与配对信息', false)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('上传文件', '保存在电脑 .dsh/mobile-uploads', true)
        Divider().color(Tokens.lineSoft).margin({ left: 16 })
        this.note('归档状态', '与桌面控制台共享同一份数据', false)
      }
      .width('100%')
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.cardShadow(this.hdsOn))
      .borderRadius(Tokens.rGroup)
      .clip(true)
      .transition(Motion.bloomCard(2, this.motionMode))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
