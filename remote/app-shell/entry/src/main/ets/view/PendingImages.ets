import { Tokens } from '../common/Tokens';
import { Haptics } from '../common/Haptics';
import { ImagePart } from '../common/Images';
import { Motion, MOTION_VIVID } from '../common/Motion';

/**
 * 输入框上方那条「待发送图片」：横向滚动、点图预览、右上角叉掉。
 * 从 ChatPage 抽出来，只依赖 images 与两个回调，聊天页少一段模板。
 */
@Component
export struct PendingImages {
  @Prop images: ImagePart[] = [];
  onPreview: (dataUrl: string, geoId: string) => void = () => {};
  onRemove: (index: number) => void = () => {};
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('bigImg') bigImg: string = '';
  @StorageLink('bigImgGeoId') bigImgGeoId: string = '';

  private geoKey(it: ImagePart, i: number): string {
    return 'pend_img_' + String(i) + '_' + it.name;
  }

  build() {
    Scroll() {
      Row({ space: 10 }) {
        ForEach(this.images, (it: ImagePart, i: number) => {
          Stack({ alignContent: Alignment.TopEnd }) {
            Image('data:' + it.mediaType + ';base64,' + it.data)
              .width(72)
              .height(72)
              .borderRadius(14)
              .objectFit(ImageFit.Cover)
              .backgroundColor(Tokens.surface2)
              .geometryTransition(Motion.geoId(this.geoKey(it, i), this.motionMode), { follow: false })
              .opacity(Motion.isVivid(this.motionMode) && this.bigImg !== '' && this.bigImgGeoId === this.geoKey(it, i) ? 0 : 1)
              .onClick(() => {
                Haptics.tap();
                this.onPreview('data:' + it.mediaType + ';base64,' + it.data, this.geoKey(it, i));
              })
            Row() {
              Image($r('app.media.ic_close'))
                .width(9)
                .height(9)
                .fillColor('#FFFFFF')
            }
            .width(20)
            .height(20)
            .borderRadius(10)
            .backgroundColor('#99000000')
            .justifyContent(FlexAlign.Center)
            .offset({ x: 5, y: -5 })
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .onClick(() => {
              Haptics.tap();
              this.onRemove(i);
            })
          }
        }, (it: ImagePart, i: number) => 'pi' + String(i) + it.name)
      }
      .padding({ left: 10, right: 10 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(84)
    .padding({ top: 8, bottom: 2 })
  }
}
