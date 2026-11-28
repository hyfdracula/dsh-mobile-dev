import { CardIcon } from '../common/CardIcon';
import { Haptics } from '../common/Haptics';
import { Mat } from '../common/Mat';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { Pairing } from '../common/Pairing';
import { Tokens } from '../common/Tokens';
import { ConnectionStageCard } from '../common/Widgets';

const SAVE_STAGES: string[] = [
  '保存地址与令牌',
  '探测局域网与公网入口',
  '验证令牌与电脑状态'
];

/**
 * 「连接地址」表单：地址 + 访问令牌 + 校验与连通性探测。
 * 两个字段用 @Link 与父级双向绑定；校验不通过或探测失败时以红色错误卡明确提示。
 */
@Component
export struct ConnectForm {
  @Link base: string;
  @Link token: string;
  @Prop saved: string = '';
  @Prop errMsg: string = '';
  @Prop saving: boolean = false;
  @Prop stageIdx: number = 0;
  @Prop stageDetail: string = '';
  @Prop elapsedSec: number = 0;
  onSave: () => void = () => {};
  onRePair?: () => void;

  @State private localErr: string = '';
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;

  private activeErr(): string {
    return this.localErr !== '' ? this.localErr : this.errMsg;
  }

  private validateAndSubmit(): void {
    if (this.saving) {
      return;
    }
    const rawBase: string = this.base.trim();
    const rawToken: string = this.token.trim();
    if (rawBase === '') {
      Haptics.tap();
      this.localErr = '请填写电脑连接地址（例如 http://192.168.1.10:8901 或 https://域名）。';
      return;
    }
    if (rawBase.indexOf('://') >= 0 &&
      !/^https?:\/\//i.test(rawBase)) {
      Haptics.tap();
      this.localErr = '地址协议不受支持，请使用 http:// 或 https:// 开头。';
      return;
    }
    const norm: string = Pairing.normalizeBase(rawBase);
    if (!/^https?:\/\/[^\s/]+/i.test(norm)) {
      Haptics.tap();
      this.localErr = '连接地址格式不正确，请检查域名或 IP 端口是否填写完整且不含空格。';
      return;
    }
    if (rawToken === '') {
      Haptics.tap();
      this.localErr = '请填写访问令牌，或点下方「重新扫码配对」自动获取。';
      return;
    }
    Haptics.tap();
    this.localErr = '';
    this.base = norm;
    this.token = rawToken;
    this.onSave();
  }

  build() {
    Column() {
      Text('地址')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim)
        .margin({ bottom: 6 })
      TextInput({ text: this.base, placeholder: 'https://your-tunnel.example.com 或 192.168.1.3:8901' })
        .height(44)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .enabled(!this.saving)
        .onChange((v: string) => {
          this.base = v;
          if (this.localErr !== '') {
            this.localErr = '';
          }
        })

      Text('访问令牌')
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim)
        .margin({ top: 12, bottom: 6 })
      TextInput({ text: this.token, placeholder: '电脑端面板上的访问令牌' })
        .type(InputType.Password)
        .height(44)
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .placeholderColor(Tokens.dim2)
        .borderRadius(Tokens.rInput)
        .backgroundColor(Tokens.surface2)
        .enabled(!this.saving)
        .onChange((v: string) => {
          this.token = v;
          if (this.localErr !== '') {
            this.localErr = '';
          }
        })

      Row() {
        if (!this.saving && this.activeErr() === '' && this.saved !== '') {
          Text('√ ' + this.saved)
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.ok)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ right: 10 })
        } else {
          Blank()
        }

        Button(this.saving ? '正在验证…' : '保存并重连')
          .fontSize(Tokens.fsBody)
          .height(38)
          .padding({ left: 18, right: 18 })
          .backgroundColor(this.saving ? Tokens.surface3 : Tokens.accent)
          .fontColor(this.saving ? Tokens.dim : Tokens.accentInk)
          .enabled(!this.saving)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.validateAndSubmit();
          })
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(VerticalAlign.Center)

      if (this.saving) {
        Column() {
          ConnectionStageCard({
            stages: SAVE_STAGES,
            currentStage: this.stageIdx,
            elapsedSec: this.elapsedSec,
            detail: this.stageDetail,
            errorText: ''
          })
        }
        .width('100%')
        .margin({ top: 12 })
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      } else if (this.activeErr() !== '') {
        Column() {
          Text(this.activeErr())
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.err)
            .lineHeight(18)
            .maxLines(5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (this.onRePair !== undefined) {
            Row() {
              Text('重新扫码配对 ›')
                .fontSize(Tokens.fsFoot)
                .fontColor(Tokens.accent)
                .backgroundColor(Tokens.accentSoft)
                .borderRadius(Tokens.rPill)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                .onClick(() => {
                  Haptics.tap();
                  if (this.onRePair !== undefined) {
                    this.onRePair();
                  }
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }
        }
        .width('100%')
        .padding(12)
        .margin({ top: 12 })
        .backgroundColor(Tokens.intrBg)
        .border({ width: 1, color: Tokens.err })
        .borderRadius(Tokens.rMd)
        .alignItems(HorizontalAlign.Start)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .clip(true)
  }
}

/**
 * 「连接地址与外网」二级菜单页面：
 * 将手动地址与访问令牌输入框从「连接与设备」主页收纳至此二级页，配合逐卡绽放与图标旋转飞入入场。
 */
@Component
export struct ConnectAddressPanel {
  @Link base: string;
  @Link token: string;
  @Prop saved: string = '';
  @Prop errMsg: string = '';
  @Prop saving: boolean = false;
  @Prop stageIdx: number = 0;
  @Prop stageDetail: string = '';
  @Prop elapsedSec: number = 0;
  onSave: () => void = () => {};
  onRePair?: () => void;

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
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        CardIcon({
          symbol: $r('sys.symbol.link'),
          tone: 'violet',
          badgeSize: 36,
          glyphSize: 18,
          entered: this.entered,
          distanceVp: this.wave.distanceOf('addr:tip', 0)
        })
        Column({ space: 2 }) {
          Text('手动修改电脑地址与访问令牌')
            .fontSize(Tokens.fsBody)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.fg)
          Text('仅需在更换公网域名、端口或手动维护长期令牌时修改，日常建议直接扫码或粘贴连接令牌。')
            .fontSize(Tokens.fsFoot)
            .fontColor(Tokens.dim2)
            .lineHeight(18)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding(14)
      .backgroundColor(Mat.cardBg(this.hdsOn))
      .border(Mat.cardBorder(this.hdsOn))
      .shadow(Mat.rowShadow(this.hdsOn))
      .borderRadius(Tokens.rRow)
      .clip(true)
      .alignItems(VerticalAlign.Top)
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('addr:tip', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('addr:tip', 0), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('addr:tip', 0), this.motionMode)
        : null)

      Column() {
        ConnectForm({
          base: $base,
          token: $token,
          saved: this.saved,
          errMsg: this.errMsg,
          saving: this.saving,
          stageIdx: this.stageIdx,
          stageDetail: this.stageDetail,
          elapsedSec: this.elapsedSec,
          onSave: (): void => {
            this.onSave();
          },
          onRePair: this.onRePair
        })
      }
      .width('100%')
      .onAreaChange((_old: Area, area: Area) => {
        this.wave.record('addr:form', area);
      })
      .animation(null)
      .opacity(this.entered ? 1 : 0)
      .animation(this.entered
        ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf('addr:form', 120), this.motionMode)
        : null)
      .scale({
        x: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        y: this.entered ? 1 : Motion.BLOOM_SCALE_START,
        centerX: '50%',
        centerY: '50%'
      })
      .animation(this.entered
        ? Motion.bloomScaleAnimByDist(this.wave.distanceOf('addr:form', 120), this.motionMode)
        : null)
    }
    .width('100%')
    .margin({ top: 6 })
  }
}
