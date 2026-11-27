import {
  DualEdgeFlowLightWithMaskParam,
  HdsSceneController,
  HdsSceneType,
  HdsVisualComponent,
  hdsEffect
} from '@kit.UIDesignKit';
import { Motion } from '../../common/Motion';

export const AI_FLOW_VARIANT_COUNT: number = 5;

/**
 * 为每次 AI 待回复流式轮次切换不同风格的水波/流光变体（0..4），保证相邻两次绝不重复。
 */
export function pickNextAiFlowVariant(prev: number): number {
  if (prev < 0 || prev >= AI_FLOW_VARIANT_COUNT) {
    return 0;
  }
  const cur: number = prev % AI_FLOW_VARIANT_COUNT;
  const step: number = 1 + (Date.now() % (AI_FLOW_VARIANT_COUNT - 1));
  return (cur + step) % AI_FLOW_VARIANT_COUNT;
}

@Component
struct RippleRing {
  @Prop startDelayMs: number = 0;
  @Prop cx: string = '50%';
  @Prop cy: string = '50%';
  @Prop themeDark: boolean = true;

  @State private armed: boolean = false;
  @State private ringScale: number = 0.14;
  @State private ringOp: number = 0.58;
  private startTimer: number = -1;
  private animTimer: number = -1;

  aboutToAppear(): void {
    if (this.startDelayMs <= 0) {
      this.armed = true;
    } else {
      this.startTimer = setTimeout(() => {
        this.startTimer = -1;
        this.armed = true;
      }, this.startDelayMs);
    }
  }

  aboutToDisappear(): void {
    if (this.startTimer >= 0) {
      clearTimeout(this.startTimer);
      this.startTimer = -1;
    }
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
      this.animTimer = -1;
    }
  }

  private beginExpand(): void {
    this.ringScale = 0.14;
    this.ringOp = 0.58;
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
    }
    this.animTimer = setTimeout(() => {
      this.animTimer = -1;
      try {
        this.getUIContext().animateTo({
          duration: 2700,
          iterations: -1,
          curve: Curve.EaseOut,
          playMode: PlayMode.Normal
        }, () => {
          this.ringScale = 2.35;
          this.ringOp = 0;
        });
      } catch (_e) {}
    }, 16);
  }

  build() {
    if (this.armed) {
      Row()
        .width(190)
        .height(190)
        .borderRadius(95)
        .position({ x: this.cx, y: this.cy })
        .translate({ x: -95, y: -95 })
        .scale({ x: this.ringScale, y: this.ringScale })
        .opacity(this.ringOp)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 95,
          colors: this.themeDark
            ? [
                ['#005B8CFF', 0.0],
                ['#005B8CFF', 0.54],
                ['#265B8CFF', 0.72],
                ['#5445D9F8', 0.84],
                ['#0045D9F8', 1.0]
              ]
            : [
                ['#003B6EF6', 0.0],
                ['#003B6EF6', 0.54],
                ['#1F2F6BFF', 0.72],
                ['#4238B6FF', 0.84],
                ['#0038B6FF', 1.0]
              ]
        })
        .hitTestBehavior(HitTestMode.None)
        .onAppear(() => {
          this.beginExpand();
        })
    }
  }
}

@Component
struct ConcentricRippleOverlay {
  @Prop radius: number = 18;
  @Prop themeDark: boolean = true;

  build() {
    Stack() {
      Row()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['48%', '52%'],
          radius: 170,
          colors: this.themeDark
            ? [['#243B6EF6', 0.0], ['#1245D9F8', 0.45], ['#003B6EF6', 1.0]]
            : [['#1A2F6BFF', 0.0], ['#0F38B6FF', 0.45], ['#002F6BFF', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      RippleRing({ startDelayMs: 0, cx: '34%', cy: '56%', themeDark: this.themeDark })
      RippleRing({ startDelayMs: 900, cx: '64%', cy: '44%', themeDark: this.themeDark })
      RippleRing({ startDelayMs: 1800, cx: '50%', cy: '52%', themeDark: this.themeDark })
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.radius)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}

@Component
struct OrbitBreathingWash {
  @Prop radius: number = 18;
  @Prop themeDark: boolean = true;
  @State private washOp: number = 0.16;
  private animTimer: number = -1;

  aboutToDisappear(): void {
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
      this.animTimer = -1;
    }
  }

  private startBreath(): void {
    this.washOp = 0.16;
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
    }
    this.animTimer = setTimeout(() => {
      this.animTimer = -1;
      try {
        this.getUIContext().animateTo({
          duration: 2100,
          iterations: -1,
          curve: Curve.EaseInOut,
          playMode: PlayMode.Alternate
        }, () => {
          this.washOp = 0.42;
        });
      } catch (_e) {}
    }, 16);
  }

  build() {
    Row()
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .opacity(this.washOp)
      .radialGradient({
        center: ['72%', '35%'],
        radius: 190,
        colors: this.themeDark
          ? [['#4D5B8CFF', 0.0], ['#2645D9F8', 0.52], ['#003B6EF6', 1.0]]
          : [['#382F6BFF', 0.0], ['#1E38B6FF', 0.52], ['#002F6BFF', 1.0]]
      })
      .hitTestBehavior(HitTestMode.None)
      .onAppear(() => {
        this.startBreath();
      })
  }
}

@Component
struct DiagonalCausticRibbon {
  @Prop radius: number = 18;
  @Prop themeDark: boolean = true;
  @State private glideX: number = -220;
  private animTimer: number = -1;

  aboutToDisappear(): void {
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
      this.animTimer = -1;
    }
  }

  private startGlide(): void {
    this.glideX = -220;
    if (this.animTimer >= 0) {
      clearTimeout(this.animTimer);
    }
    this.animTimer = setTimeout(() => {
      this.animTimer = -1;
      try {
        this.getUIContext().animateTo({
          duration: 2800,
          iterations: -1,
          curve: Curve.EaseInOut,
          playMode: PlayMode.Alternate
        }, () => {
          this.glideX = 240;
        });
      } catch (_e) {}
    }, 16);
  }

  build() {
    Stack() {
      Row()
        .width(200)
        .height('160%')
        .translate({ x: this.glideX, y: -18 })
        .rotate({ angle: 16 })
        .linearGradient({
          angle: 110,
          colors: this.themeDark
            ? [
                ['#005B8CFF', 0.0],
                ['#1F5B8CFF', 0.32],
                ['#4745D9F8', 0.52],
                ['#1C94B8FF', 0.72],
                ['#0045D9F8', 1.0]
              ]
            : [
                ['#002F6BFF', 0.0],
                ['#182F6BFF', 0.32],
                ['#3838B6FF', 0.52],
                ['#1A6366F1', 0.72],
                ['#0038B6FF', 1.0]
              ]
        })
        .hitTestBehavior(HitTestMode.None)
        .onAppear(() => {
          this.startGlide();
        })
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.radius)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}

/**
 * 仅在底部输入框挂载的 5 种同风格液态玻璃水波/流光视效：
 * - 0 (`dual_split`): HdsVisualComponent 对称蓝青双边流光 + 柔光蒙层
 * - 1 (`uv_aurora_tide`): GPU UV_BACKGROUND_FLOW_LIGHT 液态潮汐漫波
 * - 2 (`orbit_chase`): DUAL_EDGE_FLOW_LIGHT 环绕追光涡纹 + 呼吸光晕
 * - 3 (`concentric_ripple`): 同心水波纹涟漪扩散（兼作非 HDS 设备静默优雅降级）
 * - 4 (`diagonal_caustic`): 逆向斜弧边缘流光 + 斜向水光折射带
 */
@Component
export struct AiFlowGlow {
  @Prop radius: number = 18;
  @Prop glowOpacity: number = 0.62;
  @Prop @Watch('onVariantChange') variant: number = 0;
  @StorageLink('themeDark') @Watch('onThemeChange') themeDark: boolean = true;

  private sceneCtrl: HdsSceneController = new HdsSceneController();
  private shaderCtrl: hdsEffect.ShaderEffectController = new hdsEffect.ShaderEffectController();
  private sceneStarted: boolean = false;
  private shaderActive: boolean = false;
  private cachedShaderFx: VisualEffect | undefined = undefined;
  private cachedFxKey: string = '';

  private effectiveVariant(): number {
    if (!Motion.hdsVisualReady()) {
      return 3;
    }
    const raw: number = Math.floor(this.variant);
    return ((raw % AI_FLOW_VARIANT_COUNT) + AI_FLOW_VARIANT_COUNT) % AI_FLOW_VARIANT_COUNT;
  }

  private frameRate(): hdsEffect.ExpectedFrameRateRange {
    const range: hdsEffect.ExpectedFrameRateRange = {
      expected: hdsEffect.FrameRateType.FRAME_RATE_30,
      min: hdsEffect.FrameRateType.FRAME_RATE_15,
      max: hdsEffect.FrameRateType.FRAME_RATE_60
    };
    return range;
  }

  private buildSceneParams(): DualEdgeFlowLightWithMaskParam {
    const maskColors: Array<ResourceColor> = this.themeDark
      ? ['#1A3B6EF6', '#1438D9F5']
      : ['#143B6EF6', '#1038B6FF'];
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

  private buildShaderEffect(v: number): VisualEffect {
    const key: string = String(v) + '_' + (this.themeDark ? 'dark' : 'light');
    if (this.cachedShaderFx !== undefined && this.cachedFxKey === key) {
      return this.cachedShaderFx;
    }
    this.cachedFxKey = key;

    if (v === 1) {
      const uvParam: hdsEffect.UVFlowLightColorParam = {
        colorSource: this.themeDark
          ? ['#243B6EF6', '#1C38D9F5', '#1A6366F1', '#1C2DD4BF']
          : ['#1E2F6BFF', '#1A38B6FF', '#166366F1', '#1806B6D4'],
        colorTarget: this.themeDark
          ? ['#1C38D9F5', '#226366F1', '#1C2DD4BF', '#245B8CFF']
          : ['#1A38B6FF', '#1C6366F1', '#1806B6D4', '#1E2F6BFF']
      };
      const anim: hdsEffect.AnimationParams = {
        duration: 4200,
        iterations: -1,
        curve: Curve.EaseInOut,
        autoPlay: true,
        expectedFrameRateRange: this.frameRate()
      };
      const cfg: hdsEffect.ShaderEffectParams = {
        effectType: hdsEffect.EffectType.UV_BACKGROUND_FLOW_LIGHT,
        animation: anim,
        controller: this.shaderCtrl,
        params: uvParam
      };
      this.cachedShaderFx = new hdsEffect.HdsEffectBuilder().shaderEffect(cfg).buildEffect();
      return this.cachedShaderFx;
    }

    if (v === 2) {
      const orbitParam: hdsEffect.DualEdgeFlowLightParam = {
        firstEdgeFlowLight: {
          startPos: 0.0,
          endPos: 1.0,
          color: this.themeDark ? '#6EA3FF' : '#2F6BFF'
        },
        secondEdgeFlowLight: {
          startPos: 0.5,
          endPos: 1.5,
          color: this.themeDark ? '#52E5FF' : '#22B8CF'
        }
      };
      const anim: hdsEffect.AnimationParams = {
        duration: 3200,
        iterations: -1,
        curve: Curve.Linear,
        autoPlay: true,
        expectedFrameRateRange: this.frameRate()
      };
      const cfg: hdsEffect.ShaderEffectParams = {
        effectType: hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT,
        animation: anim,
        controller: this.shaderCtrl,
        params: orbitParam
      };
      this.cachedShaderFx = new hdsEffect.HdsEffectBuilder().shaderEffect(cfg).buildEffect();
      return this.cachedShaderFx;
    }

    const diagParam: hdsEffect.DualEdgeFlowLightParam = {
      firstEdgeFlowLight: {
        startPos: 0.25,
        endPos: 0.85,
        color: this.themeDark ? '#5B8CFF' : '#2F6BFF'
      },
      secondEdgeFlowLight: {
        startPos: -0.25,
        endPos: -0.85,
        color: this.themeDark ? '#38D9F5' : '#06B6D4'
      }
    };
    const anim: hdsEffect.AnimationParams = {
      duration: 3600,
      iterations: -1,
      curve: Curve.EaseInOut,
      autoPlay: true,
      expectedFrameRateRange: this.frameRate()
    };
    const cfg: hdsEffect.ShaderEffectParams = {
      effectType: hdsEffect.EffectType.DUAL_EDGE_FLOW_LIGHT,
      animation: anim,
      controller: this.shaderCtrl,
      params: diagParam
    };
    this.cachedShaderFx = new hdsEffect.HdsEffectBuilder().shaderEffect(cfg).buildEffect();
    return this.cachedShaderFx;
  }

  private applySceneParams(): void {
    if (!Motion.hdsVisualReady()) {
      return;
    }
    try {
      this.sceneCtrl.setSceneParams(this.buildSceneParams());
    } catch (_e) {}
  }

  private stopScene(): void {
    if (this.sceneStarted) {
      this.sceneStarted = false;
      try {
        this.sceneCtrl.stop();
      } catch (_e) {}
    }
  }

  private stopShader(): void {
    if (this.shaderActive) {
      this.shaderActive = false;
      try {
        this.shaderCtrl.stop();
      } catch (_e) {}
    }
  }

  private syncParams(): void {
    this.cachedFxKey = '';
    const v: number = this.effectiveVariant();
    if (v === 0) {
      this.applySceneParams();
    } else if (v === 1 || v === 2 || v === 4) {
      this.buildShaderEffect(v);
    }
  }

  private onVariantChange(): void {
    this.stopScene();
    this.stopShader();
    this.syncParams();
  }

  private onThemeChange(): void {
    this.syncParams();
  }

  aboutToAppear(): void {
    this.syncParams();
  }

  aboutToDisappear(): void {
    this.stopScene();
    this.stopShader();
  }

  build() {
    Stack() {
      if (this.effectiveVariant() === 0) {
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
            this.applySceneParams();
            if (!this.sceneStarted) {
              this.sceneStarted = true;
              try {
                this.sceneCtrl.start();
              } catch (_e) {}
            }
          })
          .onDisAppear(() => {
            this.stopScene();
          })
      } else if (this.effectiveVariant() === 1) {
        Stack()
          .width('100%')
          .height('100%')
          .borderRadius(this.radius)
          .clip(true)
          .opacity(this.glowOpacity * 0.9)
          .visualEffect(this.buildShaderEffect(1))
          .hitTestBehavior(HitTestMode.None)
          .onAppear(() => {
            this.shaderActive = true;
          })
          .onDisAppear(() => {
            this.stopShader();
          })
      } else if (this.effectiveVariant() === 2) {
        Stack() {
          OrbitBreathingWash({ radius: this.radius, themeDark: this.themeDark })
          Stack()
            .width('100%')
            .height('100%')
            .borderRadius(this.radius)
            .clip(true)
            .visualEffect(this.buildShaderEffect(2))
            .hitTestBehavior(HitTestMode.None)
            .onAppear(() => {
              this.shaderActive = true;
            })
            .onDisAppear(() => {
              this.stopShader();
            })
        }
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .opacity(this.glowOpacity)
        .hitTestBehavior(HitTestMode.None)
      } else if (this.effectiveVariant() === 3) {
        Stack() {
          ConcentricRippleOverlay({ radius: this.radius, themeDark: this.themeDark })
        }
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .opacity(this.glowOpacity)
        .hitTestBehavior(HitTestMode.None)
      } else {
        Stack() {
          DiagonalCausticRibbon({ radius: this.radius, themeDark: this.themeDark })
          Stack()
            .width('100%')
            .height('100%')
            .borderRadius(this.radius)
            .clip(true)
            .visualEffect(this.buildShaderEffect(4))
            .hitTestBehavior(HitTestMode.None)
            .onAppear(() => {
              this.shaderActive = true;
            })
            .onDisAppear(() => {
              this.stopShader();
            })
        }
        .width('100%')
        .height('100%')
        .borderRadius(this.radius)
        .clip(true)
        .opacity(this.glowOpacity)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(this.radius)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }
}
