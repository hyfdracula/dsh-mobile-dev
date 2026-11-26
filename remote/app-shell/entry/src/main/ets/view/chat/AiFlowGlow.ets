import {
  DualEdgeFlowLightWithMaskParam,
  HdsSceneController,
  HdsSceneType,
  HdsVisualComponent,
  hdsEffect
} from '@kit.UIDesignKit';
import { Motion } from '../../common/Motion';

/**
 * HarmonyOS 6 原生 HdsVisualComponent 双边边缘流光装饰层（仅灵动档 AI 思考/生成态挂载）：
 * - 使用 DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK 呈现克制的蓝青双边流光；
 * - 全程 hitTestBehavior(HitTestMode.None) 透传触控，不阻挡任何点击与滑动；
 * - 组件销毁时立即 stop() 停止 GPU 渲染并释放帧率占用，不支持该能力的设备自动静默降级。
 */
@Component
export struct AiFlowGlow {
  @Prop radius: number = 18;
  @Prop glowOpacity: number = 0.85;
  @StorageLink('themeDark') @Watch('onThemeChange') themeDark: boolean = true;

  private sceneCtrl: HdsSceneController = new HdsSceneController();
  private started: boolean = false;

  private buildParams(): DualEdgeFlowLightWithMaskParam {
    const maskColors: Array<ResourceColor> = this.themeDark
      ? ['#1A3B6EF6', '#1438D9F5']
      : ['#163B6EF6', '#1238B6FF'];
    const first: hdsEffect.EdgeFlowLightParam = {
      startPos: 0,
      endPos: 0.5,
      color: this.themeDark ? '#5B8CFF' : '#3B6EF6'
    };
    const second: hdsEffect.EdgeFlowLightParam = {
      startPos: 0,
      endPos: -0.5,
      color: this.themeDark ? '#45D9F8' : '#38B6FF'
    };
    const params: DualEdgeFlowLightWithMaskParam = {
      backgroundMaskColors: maskColors,
      firstEdgeFlowLight: first,
      secondEdgeFlowLight: second
    };
    return params;
  }

  private frameRate(): hdsEffect.ExpectedFrameRateRange {
    const range: hdsEffect.ExpectedFrameRateRange = {
      expected: hdsEffect.FrameRateType.FRAME_RATE_30,
      min: hdsEffect.FrameRateType.FRAME_RATE_15,
      max: hdsEffect.FrameRateType.FRAME_RATE_60
    };
    return range;
  }

  private applyParams(): void {
    if (!Motion.hdsVisualReady()) {
      return;
    }
    try {
      this.sceneCtrl.setSceneParams(this.buildParams());
    } catch (_e) {}
  }

  private onThemeChange(): void {
    this.applyParams();
  }

  aboutToAppear(): void {
    this.applyParams();
  }

  aboutToDisappear(): void {
    if (this.started) {
      this.started = false;
      try {
        this.sceneCtrl.stop();
      } catch (_e) {}
    }
  }

  build() {
    if (Motion.hdsVisualReady()) {
      HdsVisualComponent()
        .scene(
          HdsSceneType.DUAL_EDGE_FLOW_LIGHT_WITH_BACKGROUND_MASK,
          this.sceneCtrl,
          undefined,
          this.frameRate()
        )
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .opacity(this.glowOpacity)
        .hitTestBehavior(HitTestMode.None)
        .onAppear(() => {
          if (!this.started) {
            this.started = true;
            try {
              this.sceneCtrl.start();
            } catch (_e) {}
          }
        })
        .onDisAppear(() => {
          if (this.started) {
            this.started = false;
            try {
              this.sceneCtrl.stop();
            } catch (_e) {}
          }
        })
    }
  }
}
