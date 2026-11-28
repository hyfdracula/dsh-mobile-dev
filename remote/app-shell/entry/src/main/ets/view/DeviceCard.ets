import { CardIcon } from '../common/CardIcon';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
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
  @Prop entered: boolean = true;
  wave: BloomWaveTracker = new BloomWaveTracker();
  onReconnect: () => void = () => {};
  onRemove: () => void = () => {};
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;

  @Builder
  devRowCard(label: string, value: string, mono: boolean, copyable: boolean, waveKey: string, fallbackDistVp: number) {
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
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('dev:hdr', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf('dev:hdr', this.startIdx * 78), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_HEADER_SCALE_START,
          centerX: '0%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf('dev:hdr', this.startIdx * 78), this.motionMode)
          : null)

      Column({ space: 9 }) {
        this.devRowCard('名称', this.name !== '' ? this.name : '-', false, false, 'dev:name', (this.startIdx + 1) * 78)
        this.devRowCard('地址', this.base !== '' ? this.base : '-', true, true, 'dev:base', (this.startIdx + 2) * 78)
        this.devRowCard('连接插件', this.pluginVersion !== '' ? this.pluginVersion : '-', false, false, 'dev:ver', (this.startIdx + 3) * 78)
        this.devRowCard('会话', this.sessions >= 0 ? (String(this.sessions) + ' 个') : '-', false, false, 'dev:sess', (this.startIdx + 4) * 78)

        Row() {
          CardIcon({
            symbol: $r('sys.symbol.arrow_clockwise'),
            tone: 'blue',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('dev:reconn', (this.startIdx + 5) * 78)
          })
          .margin({ right: 12 })

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
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('dev:reconn', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('dev:reconn', (this.startIdx + 5) * 78), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('dev:reconn', (this.startIdx + 5) * 78), this.motionMode)
          : null)
        .onClick(() => {
          Haptics.tap();
          this.onReconnect();
        })

        Row() {
          CardIcon({
            symbol: $r('sys.symbol.trash'),
            tone: 'danger',
            entered: this.entered,
            distanceVp: this.wave.distanceOf('dev:remove', (this.startIdx + 6) * 78)
          })
          .margin({ right: 12 })

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
        .onAreaChange((_old: Area, area: Area) => {
          this.wave.record('dev:remove', area);
        })
        .animation(null)
        .opacity(this.entered ? 1 : 0)
        .animation(this.entered
          ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('dev:remove', (this.startIdx + 6) * 78), this.motionMode)
          : null)
        .scale({
          x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
          centerX: '50%',
          centerY: '50%'
        })
        .animation(this.entered
          ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('dev:remove', (this.startIdx + 6) * 78), this.motionMode)
          : null)
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
