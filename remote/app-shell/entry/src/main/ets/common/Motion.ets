import curves from '@ohos.curves';

export const MOTION_VIVID: string = 'vivid';
export const MOTION_CLASSIC: string = 'classic';

/**
 * 全 App 统一动效引擎（双档实时切换，零重启）：
 * - 经典（classic）：包含完整的 P0 + P1 基础动效（物理弹簧、首屏错峰、数字翻滚、
 *   AI 思考双边流光、一镜到底与矢量图标形变），简洁克制；
 * - 灵动（vivid，默认）：在经典全部能力之上，解锁全屏水平视差推拉（Push/Pop）、
 *   页内卡片由上到下逐卡景深绽放、锚点悬浮下拉卡片展开、阅读卡片景深高斯虚化缩退
 *   以及液态玻璃弹簧 Toast。
 */
export class Motion {
  static readonly fade: number = 160;
  static readonly move: number = 220;
  static readonly emph: number = 320;

  static readonly BLOOM_SCALE_START: number = 0.04;
  static readonly BLOOM_HEADER_SCALE_START: number = 0.76;
  static readonly HEADER_SLIDE_RIGHT_OUTER_X: number = -280;
  static readonly HEADER_SLIDE_RIGHT_INNER_X: number = -240;
  static readonly HEADER_SLIDE_TITLE_X: number = -210;
  static readonly HEADER_SLIDE_SUB_TITLE_X: number = -110;
  static readonly HEADER_SLIDE_BACK_X: number = -64;
  static readonly HEADER_DELAY_RIGHT_OUTER: number = 10;
  static readonly HEADER_DELAY_RIGHT_INNER: number = 65;
  static readonly HEADER_DELAY_TITLE: number = 145;
  static readonly HEADER_DELAY_SUB_TITLE: number = 95;
  static readonly HEADER_DELAY_BACK: number = 195;
  static readonly KB_LIST_LAG_RISE_MS: number = 46;
  static readonly KB_LIST_LAG_DISMISS_MS: number = 34;

  static readonly std = curves.cubicBezierCurve(0.2, 0.72, 0.32, 1);
  static readonly growCurve = curves.cubicBezierCurve(0.16, 0.90, 0.28, 1.0);
  /** 专属欠阻尼弹簧物理曲线（response 0.54s / dampingFraction 0.80：约 1.5% 柔和超调、~450ms 弹性顿停、~780ms 稳态落定） */
  static readonly unifiedElastic = curves.springMotion(0.54, 0.80);
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

  /** 旗舰空间弹性曲线：用于景深虚化、容器高度形变、卡片展开 */
  static flagshipSpring(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.38, 0.86) };
    return opts;
  }

  /** 旗舰灵巧弹跳曲线：用于按压回弹、锚点下拉展开、轻量角标 */
  static flagshipSnappy(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.28, 0.78) };
    return opts;
  }

  /** 旗舰悬浮阅读卡弹出与拖拽回弹曲线 */
  static flagshipSheet(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.42, 0.88) };
    return opts;
  }

  /** 旗舰全屏双层视差推拉与步骤横滑曲线 */
  static flagshipParallax(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.36, 0.90) };
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

  /** 键盘弹出/收起时底部输入框的物理弹簧动画参数 */
  static kbComposerAnim(mode: string): AnimateParam {
    if (Motion.isFlagship(mode)) {
      const opts: AnimateParam = { curve: curves.springMotion(0.38, 0.86) };
      return opts;
    }
    const base: AnimateParam = { curve: Motion.springPhysics };
    return base;
  }

  /** 键盘推动消息列表上移/回落的惯性跟随曲线（周期略重于输入框，形成被推着走的惯性滞后感） */
  static kbListFollowCurve(mode: string): ICurve {
    if (Motion.isFlagship(mode)) {
      return curves.interpolatingSpring(0, 1, 225, 25.5);
    }
    return curves.interpolatingSpring(0, 1, 260, 29);
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

  /** 首屏列表卡片阶梯错峰入场（仅前 18 项生效，后续滚动复用零延迟、零掉帧） */
  static staggerCard(idx: number, _mode: string): TransitionEffect {
    if (idx < 0 || idx >= 18) {
      return TransitionEffect.IDENTITY;
    }
    const wait: number = Motion.bloomDelay(idx, 16);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 210, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.scale({ x: Motion.BLOOM_SCALE_START, y: Motion.BLOOM_SCALE_START })
          .animation({ curve: Motion.unifiedElastic, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /** 卡片瀑布绽放统一错峰延时计算（24ms 逐卡错峰） */
  static bloomDelay(idx: number, baseDelay: number = 16): number {
    const clamped: number = idx < 0 ? 0 : (idx > 16 ? 16 : idx);
    return baseDelay + clamped * 24;
  }

  /** 计算瀑布绽放动画完全落定所需的总时长，供延迟合流刷新避免半途重构闪烁 */
  static bloomTotalMs(count: number, baseDelay: number = 16): number {
    const lastIdx: number = count <= 1 ? 0 : (count - 1 > 16 ? 16 : count - 1);
    return Motion.bloomDelay(lastIdx, baseDelay) + 820;
  }

  /** 卡片从小到大长大显隐动画参数（纯中心缩放 + 淡入） */
  static bloomOpacityAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: 210,
      delay: Motion.bloomDelay(idx, baseDelay),
      curve: Motion.std
    };
    return opts;
  }

  /** 卡片从小到大纯中心等比绽放动画参数（0.04 -> 1.0，与顶栏共享 unifiedElastic 物理弹簧曲线） */
  static bloomScaleAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    const opts: AnimateParam = {
      delay: Motion.bloomDelay(idx, baseDelay),
      curve: Motion.unifiedElastic
    };
    return opts;
  }

  /** 分组小标题显隐动画参数 */
  static bloomHeaderOpacityAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: 190,
      delay: Motion.bloomDelay(idx, baseDelay),
      curve: Motion.std
    };
    return opts;
  }

  /** 分组小标题缩放动画参数 */
  static bloomHeaderScaleAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    const opts: AnimateParam = {
      delay: Motion.bloomDelay(idx, baseDelay),
      curve: Motion.unifiedElastic
    };
    return opts;
  }

  /** 顶栏控件左->右弹性推出透明度动画参数 */
  static headerPopOpacityAnim(delayMs: number, mode: string, durationMs: number = 220): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { duration: durationMs, delay: delayMs, curve: Motion.std };
    return opts;
  }

  /** 顶栏控件左->右弹性推出物理弹簧参数（与卡片共用 unifiedElastic） */
  static headerPopScaleAnim(delayMs: number, mode: string): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { delay: delayMs, curve: Motion.unifiedElastic };
    return opts;
  }

  /** 顶栏标题左->右弹性滑入动画参数（与卡片共用 unifiedElastic） */
  static headerTitleSlideAnim(delayMs: number, mode: string): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { delay: delayMs, curve: Motion.unifiedElastic };
    return opts;
  }

  /**
   * 由上到下逐卡景深绽放（供仍依赖 TransitionEffect 的辅助场景复用）：
   * 卡片从 0.04 倍居中缩放入场 + 淡入，每张卡错峰 24ms，共用 unifiedElastic。
   */
  static bloomCard(idx: number, mode: string, baseDelay: number = 16): TransitionEffect {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return TransitionEffect.IDENTITY;
    }
    const wait: number = Motion.bloomDelay(idx, baseDelay);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 210, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.scale({ x: Motion.BLOOM_SCALE_START, y: Motion.BLOOM_SCALE_START })
          .animation({ curve: Motion.unifiedElastic, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /**
   * 分组小标题轻柔跟随同组首卡错峰淡入（仅灵动档生效）。
   */
  static bloomHeader(idx: number, mode: string, baseDelay: number = 30): TransitionEffect {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 16) {
      return TransitionEffect.IDENTITY;
    }
    const clamped: number = idx > 11 ? 11 : idx;
    const wait: number = baseDelay + clamped * 26;
    const springCurve = curves.springMotion(0.36, 0.86);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.translate({ y: 8 }).animation({ curve: springCurve, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /** 兼容旧调用的设置卡片错峰别名 */
  static flagshipCardStagger(idx: number, mode: string): TransitionEffect {
    return Motion.bloomCard(idx, mode, 16);
  }

  /**
   * 顶部 `<` 返回按钮与 Navigation 转场同步保持零冲突，不再额外延迟弹出。
   */
  static headerBackTransition(_mode: string): TransitionEffect {
    return TransitionEffect.IDENTITY;
  }

  /**
   * 64-65 秒同款锚点下拉卡片展开转场：
   * 从触发按钮锚点角向内/向下弹出。
   */
  static popupMenuTransition(mode: string, anchorRight: boolean = true): TransitionEffect {
    const cx: string = anchorRight ? '94%' : '6%';
    if (!Motion.isFlagship(mode)) {
      return TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: cx, centerY: '0%' })
            .animation({ duration: Motion.fade, curve: Motion.std })),
        TransitionEffect.OPACITY.animation({ duration: 120, curve: Motion.std })
      );
    }
    const snappy = curves.springMotion(0.28, 0.80);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 160, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.82, y: 0.82, centerX: cx, centerY: '0%' }).animation({ curve: snappy }))
        .combine(TransitionEffect.translate({ y: -6 }).animation({ curve: snappy })),
      TransitionEffect.OPACITY.animation({ duration: 120, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.90, y: 0.90, centerX: cx, centerY: '0%' })
          .animation({ duration: 120, curve: Motion.std }))
    );
  }

  /** 同构双屏/多步骤容器整体横滑动画参数（无回弹错位重叠） */
  static stepPaneAnim(mode: string): AnimateParam {
    if (Motion.isFlagship(mode)) {
      const opts: AnimateParam = { curve: curves.springMotion(0.34, 0.92) };
      return opts;
    }
    const base: AnimateParam = { duration: Motion.move, curve: Motion.std };
    return base;
  }

  /**
   * 步骤页 / 同构选项卡左右横推转场（零渐变淡入淡出，整页等速退场防止重合）：
   * 用于配对流程「电脑端准备 <-> 连接电脑」以及反馈中心内部页面切换。
   */
  static stepSlide(forward: boolean, mode: string): TransitionEffect {
    const anim: AnimateParam = Motion.isFlagship(mode)
      ? Motion.flagshipParallax()
      : { duration: Motion.move, curve: Motion.std };
    const enterX: string = forward ? '100%' : '-100%';
    const exitX: string = forward ? '-100%' : '100%';
    return TransitionEffect.asymmetric(
      TransitionEffect.translate({ x: enterX }).animation(anim),
      TransitionEffect.translate({ x: exitX }).animation(anim)
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
