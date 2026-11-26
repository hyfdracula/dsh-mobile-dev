import { isLanUrl } from '../common/ApiUtil';
import { ago } from '../common/Format';
import { Haptics } from '../common/Haptics';
import { Machine, Machines } from '../common/Machines';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';

/**
 * 已配对的电脑列表（F08 / L6）：
 * - 清晰展示单台电脑已合并关联的通路标签（局域网 + 公网 / 局域网 / 公网）
 * - 支持端到端加密的电脑展示「端到端加密」微标
 * - 点一行切换、长按重命名/忘记、右上角 × 直接移除；由 @StorageLink('machinesVer') 驱动刷新。
 */
@Component
export struct MachineList {
  @StorageLink('machinesVer') ver: number = 0;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  onPick: (id: string) => void = () => {};
  onRemove: (id: string) => void = () => {};
  onRename: (id: string, name: string) => void = () => {};

  private hasWanChannel(m: Machine): boolean {
    const w: string = m.wan !== undefined ? m.wan.trim() : '';
    return w !== '' && !isLanUrl(w);
  }

  private hasLanChannel(m: Machine): boolean {
    if (m.lan !== undefined && m.lan.length > 0) {
      return true;
    }
    const w: string = m.wan !== undefined ? m.wan.trim() : '';
    return w !== '' && isLanUrl(w);
  }

  private isDualChannel(m: Machine): boolean {
    return this.hasWanChannel(m) && this.hasLanChannel(m);
  }

  private channelLabel(m: Machine): string {
    const wan: boolean = this.hasWanChannel(m);
    const lan: boolean = this.hasLanChannel(m);
    if (wan && lan) {
      return '局域网 + 公网';
    }
    if (lan) {
      return '局域网';
    }
    if (wan) {
      return '公网';
    }
    return '';
  }

  private hasE2ee(m: Machine): boolean {
    return m.e2eePub !== undefined && m.e2eePub.trim() !== '';
  }

  private primaryAddress(m: Machine): string {
    if (m.wan !== undefined && m.wan.trim() !== '') {
      return m.wan.trim();
    }
    if (m.lan !== undefined && m.lan.length > 0) {
      return m.lan[0];
    }
    return '';
  }

  private rowKey(m: Machine): string {
    const lanCnt: number = m.lan !== undefined ? m.lan.length : 0;
    const pubFlag: string = this.hasE2ee(m) ? '1' : '0';
    return m.id + '@' + String(m.at) + ':' + m.name + ':' + m.wan + ':' +
      String(lanCnt) + ':' + pubFlag + ':' + String(this.ver);
  }

  @Builder
  rowMenu(m: Machine) {
    Menu() {
      MenuItem({ content: '重命名' })
        .onClick(() => {
          Haptics.tap();
          this.onRename(m.id, m.name);
        })
      MenuItem({ content: '忘记这台电脑' })
        .onClick(() => {
          Haptics.tap();
          this.onRemove(m.id);
        })
    }
  }

  @Builder
  row(m: Machine) {
    Row() {
      Column() {
        Row() {
          Text(m.name)
            .fontSize(Tokens.fsBodyLg)
            .fontWeight(m.id === Machines.activeId() ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(Tokens.fg)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (m.id === Machines.activeId()) {
            Text('当前')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .backgroundColor(Tokens.accentSoft)
              .borderRadius(Tokens.rPill)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.channelLabel(m) !== '' || this.hasE2ee(m)) {
          Flex({ wrap: FlexWrap.Wrap }) {
            if (this.channelLabel(m) !== '') {
              Text(this.channelLabel(m))
                .fontSize(Tokens.fsCaption)
                .fontWeight(this.isDualChannel(m) ? FontWeight.Medium : FontWeight.Normal)
                .fontColor(this.isDualChannel(m) ? Tokens.runInk : Tokens.dim)
                .backgroundColor(this.isDualChannel(m) ? Tokens.runBg : Tokens.surface2)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .margin({ right: 6, top: 4 })
            }
            if (this.hasE2ee(m)) {
              Text('端到端加密')
                .fontSize(Tokens.fsCaption)
                .fontColor(Tokens.doneInk)
                .backgroundColor(Tokens.doneBg)
                .borderRadius(Tokens.rPill)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .margin({ right: 6, top: 4 })
            }
          }
          .width('100%')
          .margin({ top: 2 })
        }

        Text(this.primaryAddress(m) + ' · ' + ago(m.at))
          .fontSize(Tokens.fsFoot)
          .fontColor(Tokens.dim2)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (Machines.list().length > 1) {
        Text('×')
          .fontSize(17)
          .fontColor(Tokens.dim2)
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .borderRadius(Tokens.rPill)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
          .onClick(() => {
            Haptics.tap();
            this.onRemove(m.id);
          })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 8, top: 11, bottom: 11 })
    .borderRadius(Tokens.rRow)
    .backgroundColor(m.id === Machines.activeId() ? Tokens.accentSoft : Mat.cardBg(this.hdsOn))
    .border({
      width: 1,
      color: m.id === Machines.activeId() ? Tokens.accent : Mat.cardBorderColor(this.hdsOn)
    })
    .shadow(Mat.rowShadow(this.hdsOn))
    .margin({ bottom: 9 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onClick(() => {
      Haptics.tap();
      this.onPick(m.id);
    })
    .bindContextMenu(this.rowMenu(m), ResponseType.LongPress)
  }

  build() {
    Column() {
      ForEach(Machines.list(), (m: Machine) => {
        this.row(m)
      }, (m: Machine) => this.rowKey(m))
    }
    .width('100%')
  }
}
