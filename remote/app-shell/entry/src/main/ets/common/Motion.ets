import curves from '@ohos.curves';

export const MOTION_VIVID: string = 'vivid';
export const MOTION_CLASSIC: string = 'classic';

/**
 * 全 App 统一动效引擎（双档实时切换，零重启）：
 * - 灵动（vivid，默认）：HarmonyOS 原生弹簧物理曲线（springMotion / responsiveSpringMotion）、
 *   非对称出入场、首屏卡片错峰瀑布流、NumericTextTransition 数字翻滚、
 *   HdsVisualComponent AI 思考双边流光、geometryTransition 一镜到底与 SymbolGlyph 图标形变；
 * - 经典（classic）：100% 保留简洁干脆的经典贝塞尔动画（160 / 220 / 320ms），关闭上述高阶视效。
 */
export class Motion {
  static readonly fade: number = 160;
  static readonly move: number = 220;
  static readonly emph: number = 320;

  static readonly std = curves.cubicBezierCurve(0.2, 0.72, 0.32, 1);
  static readonly spring = curves.springCurve(0.42, 0.62, 200, 12);

  /** 灵动档物理弹簧曲线：自然阻尼与速度继承 */
  static readonly springPhysics = curves.springMotion(0.36, 0.84);
  /** 灵动档轻弹曲线：用于浮层、按钮、新消息气泡 */
  static readonly springSnappy = curves.springMotion(0.30, 0.80);
  /** 灵动档跟手曲线：用于打断与快速状态响应 */
  static readonly springFollow = curves.responsiveSpringMotion();

  private static cachedNumTrans: NumericTextTransition | undefined = undefined;
  private static cachedReplaceFx: ReplaceSymbolEffect | undefined = undefined;
  private static cachedHdsVisual: boolean | undefined = undefined;

  static normalize(raw: string): string {
    return raw === MOTION_CLASSIC ? MOTION_CLASSIC : MOTION_VIVID;
  }

  static isVivid(mode?: string): boolean {
    if (mode !== undefined) {
      return mode !== MOTION_CLASSIC;
    }
    const stored: string | undefined = AppStorage.get<string>('motionMode');
    return stored !== MOTION_CLASSIC;
  }

  /** 位移、展开、尺寸类显式/属性动画参数 */
  static moveOpts(mode: string): AnimateParam {
    if (Motion.isVivid(mode)) {
      const vivid: AnimateParam = { curve: Motion.springPhysics };
      return vivid;
    }
    const classic: AnimateParam = { duration: Motion.move, curve: Motion.std };
    return classic;
  }

  /** 轻状态切换动画参数（颜色、旋转、徽标） */
  static fadeOpts(mode: string): AnimateParam {
    if (Motion.isVivid(mode)) {
      const vivid: AnimateParam = { curve: Motion.springSnappy };
      return vivid;
    }
    const classic: AnimateParam = { duration: Motion.fade, curve: Motion.std };
    return classic;
  }

  /** 沉底悬浮按钮等圆形悬浮控件转场 */
  static fabTransition(mode: string): TransitionEffect {
    if (Motion.isVivid(mode)) {
      return TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.76, y: 0.76 }).animation({ curve: Motion.springSnappy }))
          .combine(TransitionEffect.translate({ y: 10 }).animation({ curve: Motion.springSnappy })),
        TransitionEffect.OPACITY.animation({ duration: 140, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }).animation({ duration: 140, curve: Motion.std }))
      );
    }
    return TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std });
  }

  /** 展开面板、横条、多选栏、输入提示等转场 */
  static panelTransition(mode: string): TransitionEffect {
    if (Motion.isVivid(mode)) {
      return TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ curve: Motion.springSnappy }))
          .combine(TransitionEffect.translate({ y: 10 }).animation({ curve: Motion.springSnappy })),
        TransitionEffect.OPACITY.animation({ duration: 140, curve: Motion.std })
          .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 140, curve: Motion.std }))
      );
    }
    return TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
      .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: Motion.move, curve: Motion.std }));
  }

  /** 对话流新消息气泡入场转场 */
  static bubbleTransition(mode: string): TransitionEffect {
    if (Motion.isVivid(mode)) {
      return TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }).animation({ curve: Motion.springPhysics }))
          .combine(TransitionEffect.translate({ y: 12 }).animation({ curve: Motion.springPhysics })),
        TransitionEffect.IDENTITY
      );
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
        .combine(TransitionEffect.translate({ y: 8 }).animation({ duration: Motion.move, curve: Motion.std })),
      TransitionEffect.IDENTITY
    );
  }

  /** 首屏列表卡片阶梯错峰入场（仅前 8 项生效，后续滚动复用零延迟、零掉帧） */
  static staggerCard(idx: number, mode: string): TransitionEffect {
    if (!Motion.isVivid(mode) || idx < 0 || idx >= 8) {
      return TransitionEffect.IDENTITY;
    }
    const wait: number = idx * 24;
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 200, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.translate({ y: 14 }).animation({ curve: Motion.springPhysics, delay: wait }))
        .combine(TransitionEffect.scale({ x: 0.98, y: 0.98 }).animation({ curve: Motion.springPhysics, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /** 鸿蒙原生正整数数字翻滚转场（仅灵动档生效，经典档返回 undefined） */
  static numTransition(mode: string): Optional<ContentTransition> {
    if (!Motion.isVivid(mode)) {
      return undefined;
    }
    if (Motion.cachedNumTrans === undefined) {
      const opts: NumericTextTransitionOptions = {
        flipDirection: FlipDirection.DOWN,
        enableBlur: false
      };
      Motion.cachedNumTrans = new NumericTextTransition(opts);
    }
    return Motion.cachedNumTrans;
  }

  /** geometryTransition 一镜到底绑定 ID（仅灵动档生效，经典档返回空串解绑） */
  static geoId(id: string, mode: string): string {
    return Motion.isVivid(mode) ? id : '';
  }

  /** SymbolGlyph 交叉淡入替换形变实例（复用单例避免高频重建） */
  static replaceEffect(): ReplaceSymbolEffect {
    if (Motion.cachedReplaceFx === undefined) {
      Motion.cachedReplaceFx = new ReplaceSymbolEffect(EffectScope.WHOLE, ReplaceEffectType.CROSS_FADE);
    }
    return Motion.cachedReplaceFx;
  }

  /** SymbolGlyph 轻弹形变实例 */
  static bounceEffect(dir: EffectDirection): BounceSymbolEffect {
    return new BounceSymbolEffect(EffectScope.WHOLE, dir);
  }

  /** 检测当前系统是否具备 HDS 视觉流光能力（HarmonyOS 6 / API 20+） */
  static hdsVisualReady(): boolean {
    if (Motion.cachedHdsVisual === undefined) {
      try {
        Motion.cachedHdsVisual = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
      } catch (_e) {
        Motion.cachedHdsVisual = false;
      }
    }
    return Motion.cachedHdsVisual === true;
  }
}
