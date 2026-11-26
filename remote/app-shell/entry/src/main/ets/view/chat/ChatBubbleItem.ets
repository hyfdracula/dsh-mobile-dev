import { Api, Message, TurnInfo } from '../../common/Api';
import { AppIcon, ICON_DARK } from '../../common/AppIcon';
import { copyText } from '../../common/Clipboard';
import { Haptics } from '../../common/Haptics';
import { heartbeatBodyOf, isHeartbeatText } from '../../common/Heartbeat';
import { Mat } from '../../common/Mat';
import { MdBlock, parseMd } from '../../common/Md';
import { Motion, MOTION_VIVID } from '../../common/Motion';
import { Tokens } from '../../common/Tokens';
import { MdBody } from '../MdBody';
import { MessageImages } from '../MessageImages';
import { TrajectoryCard } from './TrajectoryCard';

const EMPTY_MSG: Message = { role: 'assistant', text: '', time: 0, seq: 0 };
const COLLAPSE_LINE_LIMIT: number = 40;
const COLLAPSE_PREVIEW_LINES: number = 24;

function turnLabel(t: TurnInfo): string {
  if (t.status === 'completed') return '已完成';
  if (t.status === 'aborted' || t.status === 'interrupted') return '已中断';
  if (t.status === 'error') return '出错';
  if (t.status === 'max-tokens') return '达到输出上限';
  if (t.status === 'blocked') return '受阻';
  return t.status === '' ? '已结束' : t.status;
}

function turnColor(t: TurnInfo): string {
  if (t.status === 'completed') return Tokens.ok;
  if (t.status === 'aborted' || t.status === 'interrupted' || t.status === 'error') return Tokens.err;
  return Tokens.dim2;
}

function durText(ms: number): string {
  if (ms <= 0) return '';
  const s: number = Math.round(ms / 1000);
  if (s < 60) return String(s) + ' 秒';
  const m: number = Math.floor(s / 60);
  const rest: number = s % 60;
  return rest === 0 ? String(m) + ' 分钟' : String(m) + ' 分 ' + String(rest) + ' 秒';
}

function clockText(ms: number): string {
  if (ms <= 0) return '';
  const d: Date = new Date(ms);
  const now: Date = new Date();
  const pad = (n: number): string => n < 10 ? '0' + String(n) : String(n);
  const hm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
  const isToday: boolean = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate();
  return isToday ? hm : String(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + hm;
}

function tokenText(n: number): string {
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

/**
 * 单条消息气泡组件（用户蓝底气泡 / 助手卡片 + 思考工具轨迹卡 + 图片全屏预览 + L2 一键复制/巡检净化/长文折叠 + 分叉）。
 */
@Component
export struct ChatBubbleItem {
  @Prop msg: Message = EMPTY_MSG;
  @Prop blocks: MdBlock[] = [];
  @Prop isStreaming: boolean = false;
  @Prop canFork: boolean = true;
  api: Api = new Api('', '');
  onPreviewImage: (url: string, geoId: string) => void = () => {};
  onFork: (m: Message) => void = () => {};
  onLongPress: (m: Message) => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @State private showRawHeartbeat: boolean = false;
  @State private expandedLong: boolean = false;
  @State private copied: boolean = false;
  @State private copyTrigger: number = -1;
  private copyTimer: number = -1;

  aboutToDisappear(): void {
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
  }

  private triggerCopyFeedback(): void {
    if (!Motion.isVivid(this.motionMode)) {
      return;
    }
    if (this.copyTimer >= 0) {
      clearTimeout(this.copyTimer);
      this.copyTimer = -1;
    }
    this.copied = true;
    this.copyTrigger += 1;
    this.copyTimer = setTimeout(() => {
      this.copyTimer = -1;
      this.copied = false;
      this.copyTrigger += 1;
    }, 1600);
  }

  private static derivedCache: Map<string, MdBlock[]> = new Map<string, MdBlock[]>();

  private hasTrajectory(): boolean {
    const hasThink: boolean = this.msg.thinking !== undefined && this.msg.thinking.trim() !== '';
    const hasTools: boolean = this.msg.tools !== undefined && this.msg.tools.length > 0;
    return hasThink || hasTools;
  }

  private isHeartbeat(): boolean {
    return isHeartbeatText(this.msg.text);
  }

  private effectiveText(): string {
    if (this.isHeartbeat() && !this.showRawHeartbeat) {
      return heartbeatBodyOf(this.msg.text, this.msg.role);
    }
    return this.msg.text;
  }

  private totalLines(): number {
    const t: string = this.effectiveText();
    if (t === '') {
      return 0;
    }
    return t.split('\n').length;
  }

  private isLongMessage(): boolean {
    return !this.isStreaming && this.msg.role !== 'user' && this.totalLines() > COLLAPSE_LINE_LIMIT;
  }

  private isCollapsedNow(): boolean {
    return this.isLongMessage() && !this.expandedLong;
  }

  private assistantBlocks(): MdBlock[] {
    const hb: boolean = this.isHeartbeat();
    const collapsed: boolean = this.isCollapsedNow();
    if ((!hb || this.showRawHeartbeat) && !collapsed && this.blocks.length > 0) {
      return this.blocks;
    }
    const base: string = this.effectiveText();
    let src: string = base;
    if (collapsed) {
      const lines: string[] = base.split('\n');
      src = lines.slice(0, COLLAPSE_PREVIEW_LINES).join('\n');
    }
    const key: string = String(this.msg.seq) + '|' + (this.showRawHeartbeat ? 'raw' : 'clean') +
      '|' + (collapsed ? 'col' : 'full') + '|' + String(src.length);
    const hit: MdBlock[] | undefined = ChatBubbleItem.derivedCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const parsed: MdBlock[] = parseMd(src);
    if (ChatBubbleItem.derivedCache.size > 120) {
      ChatBubbleItem.derivedCache.clear();
    }
    ChatBubbleItem.derivedCache.set(key, parsed);
    return parsed;
  }

  private userDisplayText(): string {
    if (this.isHeartbeat()) {
      return heartbeatBodyOf(this.msg.text, 'user');
    }
    return this.msg.text;
  }

  private showFooterRow(): boolean {
    return this.msg.turn !== undefined || (!this.isStreaming && this.msg.text !== '');
  }

  build() {
    if (this.msg.role === 'user') {
      Column() {
        Row() {
          Column() {
            if (this.msg.images !== undefined && this.msg.images.length > 0) {
              MessageImages({
                images: this.msg.images,
                api: this.api,
                onTap: (url: string, geoId: string): void => {
                  this.onPreviewImage(url, geoId);
                }
              })
                .margin({ bottom: this.msg.text !== '' ? 8 : 0 })
            }
            if (this.userDisplayText() !== '') {
              MdBody({
                user: true,
                userText: this.userDisplayText(),
                blocks: this.isHeartbeat() ? [] : this.blocks
              })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 15, right: 15, top: 11, bottom: 11 })
          .constraintSize({ maxWidth: 300 })
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rCard)
          .shadow({ radius: 16, color: Tokens.accentSoft, offsetY: 6 })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
      }
      .width('100%')
      .alignItems(HorizontalAlign.End)
      .margin({ bottom: 20 })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        Haptics.long();
        this.onLongPress(this.msg);
      }))
    } else {
      Column() {
        Row() {
          Image(AppIcon.res(this.appIconStyle))
            .width(20)
            .height(20)
            .borderRadius(Tokens.rXs)
            .border({ width: 0.5, color: Tokens.line })
            .objectFit(ImageFit.Cover)
          if (this.isHeartbeat()) {
            Text('自动化巡检')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.accentSoft)
              .margin({ left: 8 })
          }
          if (this.msg.turn !== undefined) {
            Row() {
              Circle()
                .width(6)
                .height(6)
                .fill(turnColor(this.msg.turn))
              Text(turnLabel(this.msg.turn) + (this.msg.turn.ms > 0 ? ' · ' + durText(this.msg.turn.ms) : ''))
                .fontSize(Tokens.fsCaption)
                .fontColor(turnColor(this.msg.turn))
                .margin({ left: 5 })
            }
            .margin({ left: 8 })
          }
          Blank()
        }
        .width('100%')
        .margin({ bottom: 6 })

        Column() {
          if (this.hasTrajectory()) {
            TrajectoryCard({
              thinking: this.msg.thinking === undefined ? '' : this.msg.thinking,
              tools: this.msg.tools === undefined ? [] : this.msg.tools
            })
              .margin({
                bottom: (this.msg.text !== '' || (this.msg.images !== undefined && this.msg.images.length > 0)) ? 10 : 0
              })
          }
          if (this.msg.images !== undefined && this.msg.images.length > 0) {
            MessageImages({
              images: this.msg.images,
              api: this.api,
              onTap: (url: string, geoId: string): void => {
                this.onPreviewImage(url, geoId);
              }
            })
              .margin({ bottom: this.msg.text !== '' ? 8 : 0 })
          }
          if (this.msg.text !== '') {
            MdBody({ blocks: this.assistantBlocks() })
          }

          if (this.isCollapsedNow()) {
            Row() {
              Text('展开全文 · 共 ' + String(this.totalLines()) + ' 行')
                .fontSize(Tokens.fsFoot)
                .fontWeight(FontWeight.Medium)
                .fontColor(Tokens.accent)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 9, bottom: 9 })
            .margin({ top: 10 })
            .borderRadius(Tokens.rMd)
            .backgroundColor(Tokens.accentSoft)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
            .onClick(() => {
              Haptics.tap();
              this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
                this.expandedLong = true;
              });
            })
          } else if (this.isLongMessage() && this.expandedLong) {
            Row() {
              Text('收起长文')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface2)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
                    this.expandedLong = false;
                  });
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 8 })
          }

          if (this.isHeartbeat()) {
            Row() {
              Text(this.showRawHeartbeat ? '收起原文' : '查看巡检原文')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(Tokens.rPill)
                .backgroundColor(Tokens.surface2)
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  this.getUIContext().animateTo(Motion.fadeOpts(this.motionMode), () => {
                    this.showRawHeartbeat = !this.showRawHeartbeat;
                  });
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .margin({ top: 8 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .borderRadius(Tokens.rCard)
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.cardShadow(this.hdsOn))
        .width('100%')

        if (this.showFooterRow()) {
          Row({ space: 10 }) {
            if (this.msg.turn !== undefined) {
              Text(tokenText(this.msg.turn.tokensIn + this.msg.turn.tokensOut) + ' tokens')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
            }
            if (this.msg.turn !== undefined
              && clockText(this.msg.turn.finishedAt === undefined ? 0 : this.msg.turn.finishedAt) !== '') {
              Text(clockText(this.msg.turn.finishedAt === undefined ? 0 : this.msg.turn.finishedAt))
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.dim2)
            }
            if (this.msg.text !== '') {
              Stack() {
                if (Motion.isVivid(this.motionMode)) {
                  SymbolGlyph(this.copied ? $r('sys.symbol.checkmark') : $r('sys.symbol.rectangle_on_rectangle'))
                    .fontSize(13)
                    .fontColor([this.copied ? Tokens.ok : Tokens.dim2])
                    .symbolEffect(Motion.replaceEffect(), this.copyTrigger)
                } else {
                  Image($r('app.media.ic_copy'))
                    .width(13)
                    .height(13)
                    .fillColor(Tokens.dim2)
                    .objectFit(ImageFit.Contain)
                    .draggable(false)
                }
              }
              .width(26)
              .height(22)
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.copied && Motion.isVivid(this.motionMode)
                ? Tokens.doneBg
                : (Tokens.isDark ? '#1FFFFFFF' : '#0F000000'))
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .accessibilityText('复制回复')
              .onClick(() => {
                this.triggerCopyFeedback();
                void copyText(this.msg.text, '已复制回复');
              })
            }
            if (this.canFork && this.msg.turn !== undefined) {
              Stack() {
                Image($r('app.media.ic_fork'))
                  .width(13)
                  .height(13)
                  .fillColor(Tokens.dim2)
                  .draggable(false)
              }
              .width(26)
              .height(22)
              .borderRadius(Tokens.rPill)
              .backgroundColor(Tokens.isDark ? '#1FFFFFFF' : '#0F000000')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .accessibilityText('从这里开新分支')
              .onClick(() => {
                this.onFork(this.msg);
              })
            }
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 20 })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        Haptics.long();
        this.onLongPress(this.msg);
      }))
    }
  }
}
