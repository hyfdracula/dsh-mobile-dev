import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Tokens } from '../common/Tokens';

/**
 * 「这台电脑」卡片列表：名称 / 地址 / 插件版本 / 会话数 + 重连 + 移除（逐条独立卡片）。
 */
@Component
export struct DeviceCard {
  @Prop name: string = '';
  @Prop base: string = '';
  @Prop pluginVersion: string = '';
  @Prop sessions: number = -1;
  @Prop startIdx: number = 7;
  onReconnect: () => void = () => {};
  onRemove: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @Builder
  devRowCard(label: string, value: string, mono: boolean, copyable: boolean, idx: number) {
    Row() {
      Text(label)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.dim)
        .width(84)
      Text(value)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .fontFamily(mono ? 'monospace' : 'sans-serif')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.End)
      if (copyable && this.base !== '') {
        Image($r('app.media.ic_copy'))
          .width(14)
          .height(14)
          .fillColor(Tokens.dim2)
          .objectFit(ImageFit.Contain)
          .margin({ left: 6 })
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
    .clickEffect(copyable && this.base !== '' ? { level: ClickEffectLevel.LIGHT, scale: 0.98 } : null)
    .transition(Motion.bloomCard(idx, this.motionMode))
    .onClick(() => {
      if (copyable && this.base !== '') {
        void copyText(this.base, '已复制当前地址');
      }
    })
  }

  build() {
    Column() {
      Text('这台电脑')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
        .letterSpacing(1.4)
        .width('100%')
        .margin({ left: 6, top: 16, bottom: 8 })
        .transition(Motion.bloomHeader(this.startIdx, this.motionMode))

      Column({ space: 9 }) {
        this.devRowCard('名称', this.name !== '' ? this.name : '-', false, false, this.startIdx)
        this.devRowCard('地址', this.base !== '' ? this.base : '-', true, true, this.startIdx + 1)
        this.devRowCard('连接插件', this.pluginVersion !== '' ? this.pluginVersion : '-', false, false, this.startIdx + 2)
        this.devRowCard('会话', this.sessions >= 0 ? (String(this.sessions) + ' 个') : '-', false, false, this.startIdx + 3)

        Row() {
          Text('重新连接')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.accent)
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
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .transition(Motion.bloomCard(this.startIdx + 4, this.motionMode))
        .onClick(() => {
          Haptics.tap();
          this.onReconnect();
        })

        Row() {
          Text('移除此电脑')
            .fontSize(Tokens.fsBodyLg)
            .fontColor(Tokens.err)
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
        .padding({ left: 16, right: 16, top: 14, bottom: 14 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(Mat.cardBg(this.hdsOn))
        .border(Mat.cardBorder(this.hdsOn))
        .shadow(Mat.rowShadow(this.hdsOn))
        .borderRadius(Tokens.rRow)
        .clip(true)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .transition(Motion.bloomCard(this.startIdx + 5, this.motionMode))
        .onClick(() => {
          Haptics.tap();
          this.onRemove();
        })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
