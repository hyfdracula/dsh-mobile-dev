import { AppCtx } from '../common/AppCtx';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { MdBlock, MdSeg, parseInline, parseMd } from '../common/Md';
import { Tokens } from '../common/Tokens';

function fastHash(s: string): string {
  let h: number = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(36);
}

/**
 * 全量 GFM 消息正文渲染（F13）：
 * - 块级：h1~h6 阶梯标题、hr 分割线、多级缩进无序/有序列表与任务复选框、多行引用块、
 *   等高自适应网格表格（Flex Stretch 杜绝锯齿断线 + 指纹 Key 实时流式刷新）、
 *   代码块（语言头栏 + 一键复制 + 横向滚动）、独立公式块与普通段落；
 * - 行内：粗体、斜体、删除线、等宽行内代码、超链接（蓝色下划线 + 点击复制弹窗）；
 * - 用户气泡保留 maxWidth: 270 不裁切。
 */
@Component
export struct MdBody {
  /** true 时按用户气泡渲染：白字、整段一个 Text、保留换行。 */
  @Prop user: boolean = false;
  /** 用户气泡的原文。 */
  @Prop userText: string = '';
  /** 已解析块（用户气泡与助手气泡均可由外层缓存传入）。 */
  @Prop blocks: MdBlock[] = [];
  @StorageLink('textScale') textScale: number = 1;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('wideScreen') wideScreen: boolean = false;

  private static inlineCache: Map<string, MdSeg[]> = new Map<string, MdSeg[]>();
  private static userMdCache: Map<string, MdBlock[]> = new Map<string, MdBlock[]>();

  private inlineOf(raw: string): MdSeg[] {
    const hit: MdSeg[] | undefined = MdBody.inlineCache.get(raw);
    if (hit !== undefined) {
      return hit;
    }
    const segs: MdSeg[] = parseInline(raw);
    if (MdBody.inlineCache.size > 512) {
      MdBody.inlineCache.clear();
    }
    MdBody.inlineCache.set(raw, segs);
    return segs;
  }

  private userBlocksOf(src: string): MdBlock[] {
    if (this.blocks.length > 0) {
      return this.blocks;
    }
    const hit: MdBlock[] | undefined = MdBody.userMdCache.get(src);
    if (hit !== undefined) {
      return hit;
    }
    const parsed: MdBlock[] = parseMd(src);
    if (MdBody.userMdCache.size > 160) {
      MdBody.userMdCache.clear();
    }
    MdBody.userMdCache.set(src, parsed);
    return parsed;
  }

  private richSegs(b: MdBlock): MdSeg[] {
    if (b.segs.length > 0) {
      return b.segs;
    }
    if (b.kind === 'table') {
      const lines: string[] = [];
      if (b.head.length > 0) {
        lines.push(b.head.join(' | '));
      }
      for (let i = 0; i < b.rows.length; i++) {
        lines.push(b.rows[i].join(' | '));
      }
      const tbl: MdSeg = { t: lines.join('\n'), b: false, c: false };
      return [tbl];
    }
    if (b.kind === 'hr') {
      const hr: MdSeg = { t: '────────', b: false, c: false };
      return [hr];
    }
    const one: MdSeg = { t: b.text, b: false, c: false };
    return [one];
  }

  private isHref(s: MdSeg): boolean {
    return s.href !== undefined && s.href !== '';
  }

  private segKey(prefix: string, i: number, s: MdSeg): string {
    const flags: string = (s.b ? 'b' : '') + (s.i === true ? 'i' : '') +
      (s.s === true ? 's' : '') + (s.c ? 'c' : '') + (this.isHref(s) ? 'l' : '');
    return prefix + String(i) + '_' + String(s.t.length) + '_' + flags + '_' + fastHash(s.t);
  }

  private spanColor(s: MdSeg, forUser: boolean): string {
    if (forUser) {
      return '#FFFFFF';
    }
    if (s.s === true) {
      return Tokens.dim;
    }
    return Tokens.fg;
  }

  private spanDecoration(s: MdSeg, forUser: boolean): DecorationStyleInterface {
    if (s.s === true) {
      const deco: DecorationStyleInterface = {
        type: TextDecorationType.LineThrough,
        color: forUser ? '#CCFFFFFF' : Tokens.dim
      };
      return deco;
    }
    if (this.isHref(s)) {
      const deco: DecorationStyleInterface = {
        type: TextDecorationType.Underline,
        color: forUser ? '#FFFFFF' : Tokens.dim
      };
      return deco;
    }
    if (forUser && s.c) {
      const deco: DecorationStyleInterface = {
        type: TextDecorationType.Underline,
        color: '#CCFFFFFF'
      };
      return deco;
    }
    const none: DecorationStyleInterface = { type: TextDecorationType.None };
    return none;
  }

  private handleLinkTap(url: string): void {
    if (url === '') {
      return;
    }
    Haptics.tap();
    AppCtx.confirm(
      '链接',
      url,
      '复制链接',
      () => {
        void copyText(url, '已复制链接');
      },
      false,
      '关闭'
    );
  }

  private blockKey(b: MdBlock, i: number): string {
    if (b.fp !== undefined && b.fp !== '') {
      return 'b' + String(i) + '_' + b.fp;
    }
    return 'b' + String(i) + '_' + b.kind + '_' + String(b.text.length) + '_' + fastHash(b.text);
  }

  private headingFontSize(kind: string): number {
    if (kind === 'h1') return 21;
    if (kind === 'h2') return 18.5;
    if (kind === 'h3') return 16.5;
    if (kind === 'h4') return 15.5;
    if (kind === 'h5') return 14.5;
    return 14;
  }

  private headingLineHeight(kind: string): number {
    if (kind === 'h1') return 29;
    if (kind === 'h2') return 26;
    if (kind === 'h3') return 24;
    if (kind === 'h4') return 22;
    if (kind === 'h5') return 21;
    return 20;
  }

  private headingTopMargin(kind: string): number {
    if (kind === 'h1') return 12;
    if (kind === 'h2') return 10;
    if (kind === 'h3') return 8;
    return 6;
  }

  private headingBottomMargin(kind: string): number {
    if (kind === 'h1') return 6;
    if (kind === 'h2') return 5;
    if (kind === 'h3') return 4;
    return 3;
  }

  private indentPad(b: MdBlock): number {
    const lv: number = b.indent !== undefined && b.indent > 0 ? b.indent : 0;
    return lv * 16;
  }

  private bulletGlyph(b: MdBlock): string {
    const lv: number = b.indent !== undefined ? b.indent : 0;
    if (lv === 1) return '–';
    return '·';
  }

  private scaledTableWidths(b: MdBlock): number[] {
    const cols: number = b.head.length;
    const raw: number[] = [];
    const scale: number = Math.max(0.88, this.textScale);
    let sum: number = 0;
    for (let i = 0; i < cols; i++) {
      const base: number = (b.colWidths !== undefined && i < b.colWidths.length && b.colWidths[i] > 0)
        ? b.colWidths[i]
        : 108;
      const w: number = Math.max(60, Math.round(base * scale));
      raw.push(w);
      sum += w;
    }
    const minTableW: number = this.wideScreen ? 460 : 284;
    if (sum > 0 && sum < minTableW) {
      const out: number[] = [];
      let acc: number = 0;
      for (let i = 0; i < cols; i++) {
        if (i === cols - 1) {
          out.push(Math.max(60, minTableW - acc));
        } else {
          const nw: number = Math.max(60, Math.round((raw[i] * minTableW) / sum));
          out.push(nw);
          acc += nw;
        }
      }
      return out;
    }
    return raw;
  }

  private sumWidths(ws: number[]): number {
    let total: number = 0;
    for (let i = 0; i < ws.length; i++) {
      total += ws[i];
    }
    return total;
  }

  private colAlignAt(b: MdBlock, ci: number): string {
    if (b.aligns !== undefined && ci >= 0 && ci < b.aligns.length) {
      return b.aligns[ci];
    }
    return 'left';
  }

  private textAlignOf(align: string): TextAlign {
    if (align === 'center') return TextAlign.Center;
    if (align === 'right') return TextAlign.End;
    return TextAlign.Start;
  }

  private colHAlignOf(align: string): HorizontalAlign {
    if (align === 'center') return HorizontalAlign.Center;
    if (align === 'right') return HorizontalAlign.End;
    return HorizontalAlign.Start;
  }

  private rowKey(ri: number, r: string[]): string {
    const joined: string = r.join('\t');
    return 'tr' + String(ri) + '_' + String(joined.length) + '_' + fastHash(joined);
  }

  private cellKey(prefix: string, ci: number, val: string): string {
    return prefix + String(ci) + '_' + String(val.length) + '_' + fastHash(val);
  }

  @Builder
  mdText(segs: MdSeg[], fontSz: number, lineH: number, forceBold: boolean = false) {
    Text() {
      ForEach(segs, (s: MdSeg, i: number) => {
        Span(s.t)
          .fontWeight((forceBold || s.b) ? FontWeight.Bold : (s.c ? FontWeight.Medium : FontWeight.Normal))
          .fontStyle(s.i === true ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(this.spanColor(s, false))
          .decoration(this.spanDecoration(s, false))
          .onClick(() => {
            if (this.isHref(s)) {
              this.handleLinkTap(s.href !== undefined ? s.href : '');
            }
          })
      }, (s: MdSeg, i: number) => this.segKey('p', i, s))
    }
    .fontSize(fontSz * this.textScale)
    .lineHeight(lineH * this.textScale)
    .width('100%')
    .copyOption(CopyOptions.LocalDevice)
  }

  /**
   * 放在 Row 内的正文容器（无序列表、有序列表、任务列表、引用块）：
   * 严禁写 width('100%')，使用 layoutWeight(1) 吃掉左侧标记后的剩余宽度，彻底消除右侧裁切。
   */
  @Builder
  mdRowText(segs: MdSeg[], fontSz: number, lineH: number) {
    Text() {
      ForEach(segs, (s: MdSeg, i: number) => {
        Span(s.t)
          .fontWeight(s.b ? FontWeight.Bold : (s.c ? FontWeight.Medium : FontWeight.Normal))
          .fontStyle(s.i === true ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
          .fontColor(this.spanColor(s, false))
          .decoration(this.spanDecoration(s, false))
          .onClick(() => {
            if (this.isHref(s)) {
              this.handleLinkTap(s.href !== undefined ? s.href : '');
            }
          })
      }, (s: MdSeg, i: number) => this.segKey('r', i, s))
    }
    .fontSize(fontSz * this.textScale)
    .lineHeight(lineH * this.textScale)
    .layoutWeight(1)
    .copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  userRich(src: string) {
    Text() {
      ForEach(this.userBlocksOf(src), (b: MdBlock, i: number) => {
        if (i > 0) {
          Span('\n')
        }
        ForEach(this.richSegs(b), (s: MdSeg, j: number) => {
          Span(s.t)
            .fontWeight(s.b ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(s.i === true ? FontStyle.Italic : FontStyle.Normal)
            .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
            .fontColor('#FFFFFF')
            .decoration(this.spanDecoration(s, true))
            .onClick(() => {
              if (this.isHref(s)) {
                this.handleLinkTap(s.href !== undefined ? s.href : '');
              }
            })
        }, (s: MdSeg, j: number) => this.segKey('u' + String(i) + '_', j, s))
      }, (b: MdBlock, i: number) => 'ub' + String(i) + '_' + this.blockKey(b, i))
    }
    .fontSize(15 * this.textScale)
    .lineHeight(24 * this.textScale)
    .fontColor('#FFFFFF')
    .constraintSize({ maxWidth: 270 })
    .copyOption(CopyOptions.LocalDevice)
  }

  /** 独立公式：居中，字号随 textScale 同步缩放。 */
  @Builder
  mdMath(b: MdBlock) {
    Row() {
      Text(b.text)
        .fontSize(15 * this.textScale)
        .lineHeight(26 * this.textScale)
        .fontColor(Tokens.fg)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 6, bottom: 10 })
  }

  @Builder
  private tableCellText(raw: string, align: string, isHead: boolean, prefix: string) {
    if (raw.trim() === '') {
      Text(' ')
        .fontSize(13 * this.textScale)
        .lineHeight(19 * this.textScale)
        .width('100%')
        .textAlign(this.textAlignOf(align))
    } else {
      Text() {
        ForEach(this.inlineOf(raw), (s: MdSeg, si: number) => {
          Span(s.t)
            .fontWeight(s.b ? FontWeight.Bold : ((isHead || s.c) ? FontWeight.Medium : FontWeight.Normal))
            .fontStyle(s.i === true ? FontStyle.Italic : FontStyle.Normal)
            .fontFamily(s.c ? 'monospace' : 'HarmonyOS Sans')
            .fontColor(this.spanColor(s, false))
            .decoration(this.spanDecoration(s, false))
            .onClick(() => {
              if (this.isHref(s)) {
                this.handleLinkTap(s.href !== undefined ? s.href : '');
              }
            })
        }, (s: MdSeg, si: number) => this.segKey(prefix, si, s))
      }
      .fontSize(13 * this.textScale)
      .lineHeight(19 * this.textScale)
      .width('100%')
      .textAlign(this.textAlignOf(align))
      .copyOption(CopyOptions.LocalDevice)
    }
  }

  /** 等高自适应 GFM 表格：行级 Flex Stretch + 右/底 0.5vp 细线，流式刷新零卡死。 */
  @Builder
  mdTable(b: MdBlock) {
    Column() {
      if (this.sumWidths(this.scaledTableWidths(b)) > (this.wideScreen ? 460 : 284)) {
        Text('左右滑动查看整张表')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.dim2)
          .margin({ left: 2, bottom: 4 })
      }
      Column() {
        Scroll() {
          Column() {
            // 表头行
            Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
              ForEach(b.head, (h: string, ci: number) => {
                Column() {
                  this.tableCellText(h, this.colAlignAt(b, ci), true, 'th' + String(ci) + '_')
                }
                .width(this.scaledTableWidths(b)[ci])
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .justifyContent(FlexAlign.Center)
                .alignItems(this.colHAlignOf(this.colAlignAt(b, ci)))
                .border({
                  width: { right: ci < b.head.length - 1 ? 0.5 : 0 },
                  color: Tokens.line
                })
              }, (h: string, ci: number) => this.cellKey('th', ci, h))
            }
            .width(this.sumWidths(this.scaledTableWidths(b)))
            .backgroundColor(Tokens.accentSoft)
            .border({
              width: { bottom: b.rows.length > 0 ? 0.5 : 0 },
              color: Tokens.line
            })

            // 数据行
            ForEach(b.rows, (r: string[], ri: number) => {
              Flex({ direction: FlexDirection.Row, alignItems: ItemAlign.Stretch }) {
                ForEach(r, (c: string, ci: number) => {
                  Column() {
                    this.tableCellText(c, this.colAlignAt(b, ci), false, 'td' + String(ri) + '_' + String(ci) + '_')
                  }
                  .width(ci < this.scaledTableWidths(b).length ? this.scaledTableWidths(b)[ci] : 108)
                  .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                  .justifyContent(FlexAlign.Center)
                  .alignItems(this.colHAlignOf(this.colAlignAt(b, ci)))
                  .border({
                    width: { right: ci < r.length - 1 ? 0.5 : 0 },
                    color: Tokens.line
                  })
                }, (c: string, ci: number) => this.cellKey('td' + String(ri) + '_', ci, c))
              }
              .width(this.sumWidths(this.scaledTableWidths(b)))
              .backgroundColor(ri % 2 === 1 ? (this.themeDark ? '#0DFFFFFF' : '#08000000') : Color.Transparent)
              .border({
                width: { bottom: ri < b.rows.length - 1 ? 0.5 : 0 },
                color: Tokens.line
              })
            }, (r: string[], ri: number) => this.rowKey(ri, r))
          }
          .alignItems(HorizontalAlign.Start)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .borderRadius(Tokens.rMd)
      .border({ width: 0.5, color: Tokens.line })
      .backgroundColor(Tokens.surface)
      .clip(true)
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8, bottom: 6 })
    .width('100%')
  }

  /** 代码块：顶栏显示语言名 + 一键复制按钮，下方支持横向滚动不乱折行。 */
  @Builder
  mdCode(b: MdBlock) {
    Column() {
      Row() {
        Text(b.lang !== '' ? b.lang : 'code')
          .fontSize(Tokens.fsCaption)
          .fontFamily('monospace')
          .fontColor(Tokens.dim2)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 4 }) {
          Image($r('app.media.ic_copy'))
            .width(12)
            .height(12)
            .fillColor(Tokens.dim)
            .objectFit(ImageFit.Contain)
          Text('复制')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.surface2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          void copyText(b.text, '已复制代码');
        })
      }
      .width('100%')
      .padding({ left: 12, right: 10, top: 6, bottom: 6 })
      .backgroundColor(Tokens.surface3)
      .border({ width: { bottom: 0.5 }, color: Tokens.lineSoft })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Text(b.text)
          .fontSize(13 * this.textScale)
          .lineHeight(20 * this.textScale)
          .fontFamily('monospace')
          .fontColor(Tokens.fg)
          .padding(12)
          .constraintSize({ minWidth: '100%' })
          .copyOption(CopyOptions.LocalDevice)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Auto)
      .width('100%')
      .align(Alignment.TopStart)
    }
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(Tokens.surface2)
    .borderRadius(Tokens.rMd)
    .border({ width: 0.5, color: Tokens.lineSoft })
    .clip(true)
    .margin({ top: 6, bottom: 6 })
    .width('100%')
  }

  @Builder
  mdBlock(b: MdBlock) {
    if (b.kind === 'h1' || b.kind === 'h2' || b.kind === 'h3' ||
      b.kind === 'h4' || b.kind === 'h5' || b.kind === 'h6') {
      Column() {
        this.mdText(b.segs, this.headingFontSize(b.kind), this.headingLineHeight(b.kind), true)
      }
      .width('100%')
      .margin({ top: this.headingTopMargin(b.kind), bottom: this.headingBottomMargin(b.kind) })
    } else if (b.kind === 'hr') {
      Divider()
        .color(Tokens.line)
        .margin({ top: 10, bottom: 10 })
    } else if (b.kind === 'bullet') {
      Row() {
        if (b.checked === 1) {
          Stack({ alignContent: Alignment.Center }) {
            Text('√')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.accentInk)
          }
          .width(16)
          .height(16)
          .borderRadius(4)
          .backgroundColor(Tokens.accent)
          .margin({ top: Math.round(4 * this.textScale), right: 8 })
        } else if (b.checked === 0) {
          Row()
            .width(16)
            .height(16)
            .borderRadius(4)
            .border({ width: 1.5, color: Tokens.dim2 })
            .margin({ top: Math.round(4 * this.textScale), right: 8 })
        } else {
          Text(this.bulletGlyph(b))
            .fontSize(15 * this.textScale)
            .lineHeight(24 * this.textScale)
            .fontColor(Tokens.dim)
            .width(14)
        }
        this.mdRowText(b.segs, 15, 24)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 2 + this.indentPad(b) })
      .margin({ top: 1, bottom: 1 })
    } else if (b.kind === 'ordered') {
      Row() {
        Text(String(b.ord) + '.')
          .fontSize(15 * this.textScale)
          .lineHeight(24 * this.textScale)
          .fontColor(Tokens.dim)
          .width(24)
        this.mdRowText(b.segs, 15, 24)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: 2 + this.indentPad(b) })
      .margin({ top: 1, bottom: 1 })
    } else if (b.kind === 'quote') {
      Row() {
        this.mdRowText(b.segs, 14.5, 23)
      }
      .width('100%')
      .padding({ left: 10, right: 8, top: 5, bottom: 5 })
      .backgroundColor(this.themeDark ? '#12FFFFFF' : '#07000000')
      .borderRadius({ topRight: Tokens.rSm, bottomRight: Tokens.rSm })
      .border({ width: { left: 3 }, color: Tokens.accent })
      .alignItems(VerticalAlign.Top)
      .margin({ top: 5, bottom: 5 })
    } else if (b.kind === 'code') {
      this.mdCode(b)
    } else if (b.kind === 'table') {
      this.mdTable(b)
    } else if (b.kind === 'math') {
      this.mdMath(b)
    } else {
      Column() {
        this.mdText(b.segs, 15, 24, false)
      }
      .width('100%')
      .margin({ top: 2, bottom: 2 })
    }
  }

  build() {
    if (this.user) {
      this.userRich(this.userText)
    } else {
      Column({ space: 2 }) {
        ForEach(this.blocks, (b: MdBlock, i: number) => {
          this.mdBlock(b)
        }, (b: MdBlock, i: number) => this.blockKey(b, i))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
