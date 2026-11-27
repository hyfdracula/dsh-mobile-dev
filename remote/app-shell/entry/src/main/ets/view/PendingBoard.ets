import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Motion } from '../common/Motion';
import { Tokens } from '../common/Tokens';

export interface PendRow {
  key: string;
  kind: string;
  idx: number;
  id: string;
  title: string;
  sub: string;
  thumb: string;
}

/**
 * 待发送与排队消息的可回收高可读抽屉（收起仅占 40vp 把手条，向上展开最多 4 行并可滚）。
 */
@Component
export struct PendingBoard {
  @Prop @Watch('onRowsChange') rows: PendRow[] = [];
  @Prop cardH: number = 0;
  onFire: (r: PendRow) => void = () => {};
  onEdit: (r: PendRow) => void = () => {};
  onRemove: (r: PendRow) => void = () => {};
  onMove: (from: number, to: number) => void = () => {};
  onHeight: (h: number) => void = () => {};

  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  @State private expanded: boolean = false;
  private lastCount: number = 0;

  aboutToAppear(): void {
    this.lastCount = this.rows.length;
    this.expanded = false;
  }

  aboutToDisappear(): void {
    this.onHeight(0);
  }

  private onRowsChange(): void {
    const count: number = this.rows.length;
    if (count === 0) {
      this.expanded = false;
    } else if (this.lastCount === 0 && count > 0) {
      // 队列从空变成有数据时默认保持收起状态，避免遮挡对话正文
      this.expanded = false;
    }
    this.lastCount = count;
  }

  private toggleExpand(): void {
    Haptics.tap();
    this.getUIContext().animateTo({ duration: Motion.move, curve: Motion.std }, () => {
      this.expanded = !this.expanded;
    });
  }

  private queueCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].kind === 'queue') {
        n++;
      }
    }
    return n;
  }

  private badgeText(): string {
    const q: number = this.queueCount();
    const total: number = this.rows.length;
    if (q > 0 && q === total) {
      return '排队 ' + String(total);
    }
    if (q > 0) {
      return '待发 ' + String(total) + ' · 排队 ' + String(q);
    }
    return '待发附件 ' + String(total);
  }

  private previewText(): string {
    if (this.rows.length === 0) {
      return '';
    }
    const first: string = this.rows[0].title.replace(/\s+/g, ' ').trim();
    if (first === '') {
      return '点击查看待发送列表';
    }
    return first;
  }

  private listHeight(): number {
    const rowH: number = 46;
    const rawH: number = Math.min(this.rows.length, 4) * rowH;
    if (this.cardH > rowH) {
      return Math.min(rawH, this.cardH);
    }
    return rawH;
  }

  @Builder
  dragChip(r: PendRow) {
    Row({ space: 8 }) {
      Text(r.kind === 'queue' ? '排队' : '附件')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.accent)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(Tokens.rXs)
        .backgroundColor(Tokens.accentSoft)
      Text(r.title)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 220 })
    }
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(Tokens.rMd)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
  }

  @Builder
  rowView(r: PendRow) {
    Row({ space: 8 }) {
      Text('≡')
        .fontSize(14)
        .fontColor(Tokens.dim2)
        .width(16)
        .textAlign(TextAlign.Center)

      Text(r.kind === 'queue' ? '排队' : '附件')
        .fontSize(Tokens.fsCaption)
        .fontWeight(FontWeight.Medium)
        .fontColor(r.kind === 'queue' ? Tokens.accent : Tokens.dim)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(Tokens.rXs)
        .backgroundColor(r.kind === 'queue' ? Tokens.accentSoft : Mat.subCardBg(this.hdsOn))

      Column({ space: 1 }) {
        Text(r.title)
          .fontSize(Tokens.fsFoot)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (r.sub !== '') {
          Text(r.sub)
            .fontSize(10.5)
            .fontColor(Tokens.dim2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (r.kind === 'queue') {
        Text('编辑')
          .fontSize(Tokens.fsCaption)
          .fontColor(Tokens.fg)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Mat.subCardBg(this.hdsOn))
          .border(Mat.subCardBorder(this.hdsOn))
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onEdit(r);
          })

        Text('立即')
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accent)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accentSoft)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Haptics.tap();
            this.onFire(r);
          })
      }

      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_close'))
          .width(12)
          .height(12)
          .fillColor(Tokens.dim)
          .objectFit(ImageFit.Contain)
      }
      .width(26)
      .height(26)
      .borderRadius(Tokens.rPill)
      .backgroundColor(Mat.subCardBg(this.hdsOn))
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
      .accessibilityText('移除')
      .onClick(() => {
        Haptics.tap();
        this.onRemove(r);
      })
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 8 })
    .borderRadius(Tokens.rMd)
    .backgroundColor(this.hdsOn
      ? (this.themeDark ? '#26FFFFFF' : '#B8FFFFFF')
      : Tokens.surface2)
    .border({
      width: 0.5,
      color: this.hdsOn
        ? (this.themeDark ? '#26FFFFFF' : '#CCF0F4FA')
        : Tokens.lineSoft
    })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      if (this.expanded) {
        List({ space: 4 }) {
          ForEach(this.rows, (r: PendRow) => {
            ListItem() {
              this.rowView(r)
            }
          }, (r: PendRow) => r.key)
        }
        .width('100%')
        .height(this.listHeight())
        .scrollBar(BarState.Auto)
        .padding({ left: 6, right: 6, top: 6, bottom: 4 })
        .onItemDragStart((_event: ItemDragInfo, itemIndex: number): CustomBuilder => {
          const item: PendRow | undefined = this.rows[itemIndex];
          return () => {
            if (item !== undefined) {
              this.dragChip(item);
            }
          };
        })
        .onItemDrop((_event: ItemDragInfo, itemIndex: number, insertIndex: number, isSuccess: boolean) => {
          if (!isSuccess || itemIndex < 0 || insertIndex < 0 || itemIndex === insertIndex) {
            return;
          }
          const to: number = insertIndex > itemIndex ? insertIndex - 1 : insertIndex;
          if (to !== itemIndex && to >= 0 && to < this.rows.length) {
            this.onMove(itemIndex, to);
          }
        })

        Divider()
          .color(this.hdsOn ? (this.themeDark ? '#24FFFFFF' : '#260F172A') : Tokens.lineSoft)
      }

      // 抽屉底部常驻把手条（始终贴近输入区，点击向上展开或收起）
      Row({ space: 8 }) {
        Text(this.badgeText())
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(Tokens.rPill)
          .backgroundColor(Tokens.accent)

        Text(this.expanded ? '拖拽调整顺序或立即发送' : this.previewText())
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.fg)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Row({ space: 4 }) {
          Text(this.expanded ? '收起' : '展开')
            .fontSize(Tokens.fsCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.accent)
          Image($r('app.media.ic_back'))
            .width(11)
            .height(11)
            .fillColor(Tokens.accent)
            .rotate({ angle: this.expanded ? -90 : 90 })
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(Tokens.rPill)
        .backgroundColor(Tokens.accentSoft)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(40)
      .padding({ left: 10, right: 10 })
      .alignItems(VerticalAlign.Center)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.985 })
      .onClick(() => {
        this.toggleExpand();
      })
    }
    .width('100%')
    .backgroundColor(Mat.drawerBg(this.hdsOn))
    .backdropBlur(Mat.drawerBlur(this.hdsOn))
    .systemMaterial(Mat.drawer(this.hdsOn))
    .borderRadius(Tokens.rCard)
    .border(Mat.floatBorder(this.hdsOn))
    .shadow(Mat.floatShadow(this.hdsOn))
    .clip(true)
    .margin({ left: 0, right: 0, bottom: 8 })
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const h: number = Number(newValue.height);
      this.onHeight(h >= 0 ? h : 0);
    })
  }
}
