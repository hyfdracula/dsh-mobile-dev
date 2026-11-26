import curves from '@ohos.curves';

export const MOTION_VIVID: string = 'vivid';
export const MOTION_CLASSIC: string = 'classic';

export const SPEED_FAST: string = 'fast';
export const SPEED_NORMAL: string = 'normal';
export const SPEED_GENTLE: string = 'gentle';

/**
 * 全 App 统一动效引擎（双档实时切换，零重启）：
 * - 经典（classic）：包含完整的 P0 + P1 基础动效（物理弹簧、首屏错峰、数字翻滚、
 *   AI 思考双边流光、一镜到底与矢量图标形变），简洁克制、零侵入；
 * - 灵动（vivid，默认）：在经典全部能力之上，解锁旗舰空间级编排动效（景深高斯虚化缩退、
 *   悬浮可拖拽半模态卡片栈、栈内左右视差推拉与高度弹性形变、实体分段弹性滑块、
 *   液态玻璃弹簧 Toast 与三档动效速度细调）。
 */
export class Motion {
  static readonly fade: number = 160;
  static readonly move: number = 220;
  static readonly emph: number = 320;

  static readonly std = curves.cubicBezierCurve(0.2, 0.72, 0.32, 1);
  static readonly spring = curves.springCurve(0.42, 0.62, 200, 12);

  /** 基础物理弹簧曲线：自然阻尼与速度继承 */
  static readonly springPhysics = curves.springMotion(0.36, 0.84);
  /** 基础轻弹曲线：用于浮层、按钮、新消息气泡 */
  static readonly springSnappy = curves.springMotion(0.30, 0.80);
  /** 跟手曲线：用于打断与快速状态响应 */
  static readonly springFollow = curves.responsiveSpringMotion();

  private static cachedNumTrans: NumericTextTransition | undefined = undefined;
  private static cachedReplaceFx: ReplaceSymbolEffect | undefined = undefined;
  private static cachedHdsVisual: boolean | undefined = undefined;

  static normalize(raw: string): string {
    return raw === MOTION_CLASSIC ? MOTION_CLASSIC : MOTION_VIVID;
  }

  static normalizeSpeed(raw: string): string {
    if (raw === SPEED_FAST) {
      return SPEED_FAST;
    }
    if (raw === SPEED_GENTLE) {
      return SPEED_GENTLE;
    }
    return SPEED_NORMAL;
  }

  /** 是否启用旗舰「灵动」空间编排动效（仅 vivid 档为 true，classic 档为 false） */
  static isFlagship(mode?: string): boolean {
    if (mode !== undefined) {
      return mode !== MOTION_CLASSIC;
    }
    const stored: string | undefined = AppStorage.get<string>('motionMode');
    return stored !== MOTION_CLASSIC;
  }

  /**
   * 基础动效总开关：P0 + P1 基础能力已全面下沉为「经典」基线，经典与灵动两档均常驻启用。
   */
  static isVivid(_mode?: string): boolean {
    return true;
  }

  /** 读取当前旗舰动效速度系数（偏快 0.76x / 正常 1.0x / 柔和 1.32x） */
  static speedScale(speed?: string): number {
    const raw: string | undefined = speed !== undefined ? speed : AppStorage.get<string>('motionSpeed');
    if (raw === SPEED_FAST) {
      return 0.76;
    }
    if (raw === SPEED_GENTLE) {
      return 1.32;
    }
    return 1.0;
  }

  /** 旗舰空间弹性曲线：用于景深虚化、容器高度形变、卡片展开 */
  static flagshipSpring(speed?: string): AnimateParam {
    const k: number = Motion.speedScale(speed);
    const opts: AnimateParam = { curve: curves.springMotion(0.38 * k, 0.86) };
    return opts;
  }

  /** 旗舰灵巧弹跳曲线：用于分段实体滑块、按压回弹、轻量角标 */
  static flagshipSnappy(speed?: string): AnimateParam {
    const k: number = Motion.speedScale(speed);
    const opts: AnimateParam = { curve: curves.springMotion(0.28 * k, 0.78) };
    return opts;
  }

  /** 旗舰悬浮半模态弹出与拖拽回弹曲线 */
  static flagshipSheet(speed?: string): AnimateParam {
    const k: number = Motion.speedScale(speed);
    const opts: AnimateParam = { curve: curves.springMotion(0.42 * k, 0.88) };
    return opts;
  }

  /** 旗舰栈内左右视差推拉曲线 */
  static flagshipParallax(speed?: string): AnimateParam {
    const k: number = Motion.speedScale(speed);
    const opts: AnimateParam = { curve: curves.springMotion(0.36 * k, 0.90) };
    return opts;
  }

  /** 位移、展开、尺寸类显式/属性动画参数 */
  static moveOpts(mode: string): AnimateParam {
    if (Motion.isFlagship(mode)) {
      return Motion.flagshipSpring();
    }
    const base: AnimateParam = { curve: Motion.springPhysics };
    return base;
  }

  /** 轻状态切换动画参数（颜色、旋转、徽标） */
  static fadeOpts(mode: string): AnimateParam {
    if (Motion.isFlagship(mode)) {
      return Motion.flagshipSnappy();
    }
    const base: AnimateParam = { curve: Motion.springSnappy };
    return base;
  }

  /** 沉底悬浮按钮等圆形悬浮控件转场 */
  static fabTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.76, y: 0.76 }).animation({ curve: Motion.springSnappy }))
        .combine(TransitionEffect.translate({ y: 10 }).animation({ curve: Motion.springSnappy })),
      TransitionEffect.OPACITY.animation({ duration: 140, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }).animation({ duration: 140, curve: Motion.std }))
    );
  }

  /** 展开面板、横条、多选栏、输入提示等转场 */
  static panelTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ curve: Motion.springSnappy }))
        .combine(TransitionEffect.translate({ y: 10 }).animation({ curve: Motion.springSnappy })),
      TransitionEffect.OPACITY.animation({ duration: 140, curve: Motion.std })
        .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 140, curve: Motion.std }))
    );
  }

  /** 对话流新消息气泡入场转场 */
  static bubbleTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.97, y: 0.97 }).animation({ curve: Motion.springPhysics }))
        .combine(TransitionEffect.translate({ y: 12 }).animation({ curve: Motion.springPhysics })),
      TransitionEffect.IDENTITY
    );
  }

  /** 首屏列表卡片阶梯错峰入场（仅前 8 项生效，后续滚动复用零延迟、零掉帧） */
  static staggerCard(idx: number, _mode: string): TransitionEffect {
    if (idx < 0 || idx >= 8) {
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

  /** 旗舰设置卡片入场错峰（仅灵动档生效，经典档零延迟） */
  static flagshipCardStagger(idx: number, mode: string, speed?: string): TransitionEffect {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 6) {
      return TransitionEffect.IDENTITY;
    }
    const k: number = Motion.speedScale(speed);
    const wait: number = Math.round(idx * 34 * k);
    const springCurve = curves.springMotion(0.36 * k, 0.84);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: Math.round(210 * k), curve: Motion.std, delay: wait })
        .combine(TransitionEffect.translate({ y: 18 }).animation({ curve: springCurve, delay: wait }))
        .combine(TransitionEffect.scale({ x: 0.965, y: 0.965 }).animation({ curve: springCurve, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /** 鸿蒙原生正整数数字翻滚转场 */
  static numTransition(_mode: string): Optional<ContentTransition> {
    if (Motion.cachedNumTrans === undefined) {
      const opts: NumericTextTransitionOptions = {
        flipDirection: FlipDirection.DOWN,
        enableBlur: false
      };
      Motion.cachedNumTrans = new NumericTextTransition(opts);
    }
    return Motion.cachedNumTrans;
  }

  /** geometryTransition 一镜到底绑定 ID */
  static geoId(id: string, _mode: string): string {
    return id;
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

  /** 检测当前系统是否具备 HDS 视觉流光能力（HarmonyOS 6+ / API 20+） */
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
