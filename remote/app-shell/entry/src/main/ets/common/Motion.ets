import curves from '@ohos.curves';

export const MOTION_VIVID: string = 'vivid';
export const MOTION_CLASSIC: string = 'classic';

/**
 * 卡片瀑布绽放的空间距离追踪器：
 * 通过 onAreaChange 记录各卡片与分组标题的真实纵向中心坐标（globalPosition.y + height / 2），
 * 以恒定空间传播速度按真实纵向距离换算起播延时（不再使用固定每卡常数间隔），
 * 仅写入普通 Map，不触发任何多余状态重绘。
 */
export class BloomWaveTracker {
  private centers: Map<string, number> = new Map<string, number>();

  /** 记录元素在窗口中的真实纵向中心坐标（vp） */
  record(key: string, area: Area): void {
    const gy: number = Number(area.globalPosition.y);
    const h: number = Number(area.height);
    if (!Number.isFinite(gy) || !Number.isFinite(h)) {
      return;
    }
    const centerY: number = gy + (h > 0 ? h * 0.5 : 0);
    this.centers.set(key, centerY);
  }

  /** 清空坐标缓存（如列表数据集切换或重置） */
  reset(): void {
    this.centers.clear();
  }

  /**
   * 计算元素中心相对当前首屏最上方可见元素中心的真实纵向距离（vp）。
   * 若首次尚未完成测量，则回退到调用方提供的布局估算距离。
   */
  distanceOf(key: string, fallbackDistanceVp: number): number {
    const cy: number | undefined = this.centers.get(key);
    if (cy === undefined) {
      return fallbackDistanceVp > 0 ? fallbackDistanceVp : 0;
    }
    let originY: number = cy;
    let hasVisible: boolean = false;
    this.centers.forEach((v: number) => {
      if (v >= 0) {
        if (!hasVisible || v < originY) {
          originY = v;
          hasVisible = true;
        }
      }
    });
    if (!hasVisible) {
      this.centers.forEach((v: number) => {
        if (v < originY) {
          originY = v;
        }
      });
    }
    const dist: number = cy - originY;
    return dist > 0 ? dist : 0;
  }

  /** 返回当前已测量元素中最大的首屏纵向跨度（vp），供估算总落定时长 */
  maxVisibleSpan(fallbackSpanVp: number): number {
    let minY: number = Number.POSITIVE_INFINITY;
    let maxY: number = Number.NEGATIVE_INFINITY;
    this.centers.forEach((v: number) => {
      if (v >= 0) {
        if (v < minY) {
          minY = v;
        }
        if (v > maxY) {
          maxY = v;
        }
      }
    });
    if (!Number.isFinite(minY) || !Number.isFinite(maxY) || maxY <= minY) {
      return fallbackSpanVp > 0 ? fallbackSpanVp : 0;
    }
    return maxY - minY;
  }
}

/**
 * 全 App 统一动效引擎（双档实时切换，零重启）：
 * - 全应用基础物理曲线统一收口至专属欠阻尼弹簧 unifiedElastic（springMotion(0.54, 0.80)）：
 *   顶栏控件滑入、卡片按空间距离绽放、聊天页软键盘推起气泡、浮层弹出与容器展开共享同一物理节奏；
 * - 经典（classic）：包含完整的 P0 + P1 基础动效（统一弹簧、数字翻滚、AI 流光、一镜到底与矢量形变）；
 * - 灵动（vivid，默认）：在经典全部能力之上，解锁全屏水平视差推拉、页内按空间距离逐卡绽放、
 *   锚点悬浮下拉卡片展开、悬浮阅读卡片以及液态玻璃弹簧 Toast。
 */
export class Motion {
  static readonly fade: number = 160;
  static readonly move: number = 220;
  static readonly emph: number = 320;

  static readonly BLOOM_SCALE_START: number = 0.04;
  static readonly BLOOM_HEADER_SCALE_START: number = 0.76;
  /** 二级子页卡片默认起播基准延时（ms），与 Navigation 右推入场对齐，保证顶部卡片在视口内完整绽放 */
  static readonly BLOOM_SUB_BASE_DELAY: number = 92;
  /** 图标滞后宿主卡片起播时间（ms），在卡片放大到约 60% 时于原位旋转绽放 */
  static readonly ICON_FLY_LAG_MS: number = 78;
  static readonly ICON_FLY_ROTATE_START: number = 180;
  static readonly ICON_FLY_SCALE_START: number = 0.0;
  static readonly ICON_FLY_ROTATE_DURATION_MS: number = 450;
  /** 空间波纹传播速率：每 vp 纵向中心距对应的起播延时（ms/vp）与最大首屏错峰上限（ms） */
  static readonly BLOOM_MS_PER_VP: number = 0.32;
  static readonly BLOOM_MAX_STAGGER_MS: number = 340;
  static readonly BLOOM_FALLBACK_STEP_VP: number = 78;

  static readonly HEADER_SLIDE_RIGHT_OUTER_X: number = -280;
  static readonly HEADER_SLIDE_RIGHT_INNER_X: number = -240;
  static readonly HEADER_SLIDE_TITLE_X: number = -210;
  static readonly HEADER_SLIDE_SUB_TITLE_X: number = -110;
  static readonly HEADER_SLIDE_BACK_X: number = -64;
  static readonly HEADER_DELAY_RIGHT_OUTER: number = 10;
  static readonly HEADER_DELAY_RIGHT_INNER: number = 52;
  static readonly HEADER_DELAY_TITLE: number = 118;
  static readonly HEADER_DELAY_SUB_TITLE: number = 78;
  static readonly HEADER_DELAY_BACK: number = 160;
  static readonly KB_LIST_LAG_RISE_MS: number = 40;
  static readonly KB_LIST_LAG_DISMISS_MS: number = 28;

  static readonly std = curves.cubicBezierCurve(0.2, 0.72, 0.32, 1);
  static readonly growCurve = curves.cubicBezierCurve(0.16, 0.90, 0.28, 1.0);

  /**
   * 专属弹性入场曲线（response=0.44s, dampingFraction=0.82）：
   * 仅用于顶部控件横扫、页内卡片按距离绽放，以及聊天页键盘推起输入框与气泡；
   * 其余点击弹窗、搜索栏、抽屉、面板均保持利落短曲线，做到全站快慢有序。
   */
  static readonly unifiedElastic = curves.springMotion(0.44, 0.82);

  /** 卡片内纯蓝图标随卡片长大而原位放大绽放的利落弹簧曲线 */
  static readonly iconFlyScaleSpring = curves.springMotion(0.36, 0.82);

  /** 卡片内图标 +180° -> 0° 丝滑减速归正曲线（无回弹抖动） */
  static readonly iconFlyRotateCurve = curves.cubicBezierCurve(0.16, 0.94, 0.28, 1.0);

  /**
   * 与 unifiedElastic（response=0.44s, dampingFraction=0.82）严格数学等价的插值弹簧曲线：
   * ω0 = 2π / 0.44 ≈ 14.2800 rad/s, stiffness = ω0² ≈ 203.917, damping = 2 * 0.82 * ω0 ≈ 23.419。
   * 专供 Scroller.scrollTo 气泡跟随使用，与顶部控件及输入框曲线严格一致。
   */
  static readonly unifiedElasticScroll = curves.interpolatingSpring(0, 1, 203.917, 23.419);

  static readonly spring = curves.springCurve(14, 1, 180, 22);
  /** 容器展开、通用交互的利落物理弹簧（快慢有序，不拖沓） */
  static readonly springPhysics = curves.springMotion(0.34, 0.88);
  /** 锚点弹窗菜单、下拉选择卡、搜索栏与按压反馈的轻快弹跳曲线 */
  static readonly springSnappy = curves.springMotion(0.24, 0.84);
  /** 跟手曲线：用于拖拽跟手反馈 */
  static readonly springFollow = curves.responsiveSpringMotion(0.28, 0.88);

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

  /** 全 App 基础空间弹性动画参数（统一使用 unifiedElastic） */
  static baseElastic(delayMs: number = 0): AnimateParam {
    if (delayMs > 0) {
      const delayed: AnimateParam = { delay: delayMs, curve: Motion.unifiedElastic };
      return delayed;
    }
    const opts: AnimateParam = { curve: Motion.unifiedElastic };
    return opts;
  }

  /** 旗舰空间弹性曲线：用于容器高度形变与布局过渡（利落短弹簧） */
  static flagshipSpring(): AnimateParam {
    const opts: AnimateParam = { curve: Motion.springPhysics };
    return opts;
  }

  /** 旗舰灵巧弹跳曲线：用于按压回弹、锚点下拉展开、搜索栏、分段滑块与轻量角标 */
  static flagshipSnappy(): AnimateParam {
    const opts: AnimateParam = { curve: Motion.springSnappy };
    return opts;
  }

  /** 旗舰悬浮阅读卡弹出与拖拽回弹曲线 */
  static flagshipSheet(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.32, 0.88) };
    return opts;
  }

  /** 旗舰全屏双层视差推拉与步骤横滑曲线 */
  static flagshipParallax(): AnimateParam {
    const opts: AnimateParam = { curve: curves.springMotion(0.38, 0.90) };
    return opts;
  }

  /** 位移、展开、尺寸类显式/属性动画参数（按钮点击展开保持轻快干脆） */
  static moveOpts(_mode: string): AnimateParam {
    const opts: AnimateParam = { curve: Motion.springSnappy };
    return opts;
  }

  /** 轻状态切换动画参数（颜色、旋转、徽标） */
  static fadeOpts(_mode: string): AnimateParam {
    const opts: AnimateParam = { duration: Motion.fade, curve: Motion.std };
    return opts;
  }

  /** 键盘弹出/收起时底部输入框的物理弹簧动画参数（与顶栏及页内卡片绽放一致） */
  static kbComposerAnim(_mode: string): AnimateParam {
    return Motion.baseElastic();
  }

  /** 键盘推动消息气泡列表上移/回落的跟随曲线（与顶部控件 unifiedElastic 严格同曲线） */
  static kbListFollowCurve(_mode: string): ICurve {
    return Motion.unifiedElasticScroll;
  }

  /** 沉底悬浮按钮等圆形悬浮控件转场 */
  static fabTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 150, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.76, y: 0.76 }).animation({ curve: Motion.springSnappy }))
        .combine(TransitionEffect.translate({ y: 10 }).animation({ curve: Motion.springSnappy })),
      TransitionEffect.OPACITY.animation({ duration: 120, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.86, y: 0.86 }).animation({ duration: 120, curve: Motion.std }))
    );
  }

  /** 展开面板、横条、多选栏、输入提示等转场 */
  static panelTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 150, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 }).animation({ curve: Motion.springSnappy }))
        .combine(TransitionEffect.translate({ y: 8 }).animation({ curve: Motion.springSnappy })),
      TransitionEffect.OPACITY.animation({ duration: 120, curve: Motion.std })
        .combine(TransitionEffect.translate({ y: 6 }).animation({ duration: 120, curve: Motion.std }))
    );
  }

  /** 对话流新消息气泡入场转场 */
  static bubbleTransition(_mode: string): TransitionEffect {
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 160, curve: Motion.std })
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
      TransitionEffect.OPACITY.animation({ duration: 175, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.scale({ x: Motion.BLOOM_SCALE_START, y: Motion.BLOOM_SCALE_START })
          .animation({ curve: Motion.unifiedElastic, delay: wait })),
      TransitionEffect.IDENTITY
    );
  }

  /** 根据真实纵向中心距离（vp）动态计算卡片开始长大的延时（ms） */
  static bloomDelayByDistance(distanceVp: number, baseDelay: number = 16): number {
    const d: number = distanceVp > 0 ? distanceVp : 0;
    const raw: number = Math.round(d * Motion.BLOOM_MS_PER_VP);
    const clamped: number = raw > Motion.BLOOM_MAX_STAGGER_MS ? Motion.BLOOM_MAX_STAGGER_MS : raw;
    return baseDelay + clamped;
  }

  /** 兼容旧调用的序号延时换算（按默认卡片间距估算距离） */
  static bloomDelay(idx: number, baseDelay: number = 16): number {
    const clamped: number = idx < 0 ? 0 : (idx > 16 ? 16 : idx);
    return Motion.bloomDelayByDistance(clamped * Motion.BLOOM_FALLBACK_STEP_VP, baseDelay);
  }

  /** 按首屏纵向跨度计算瀑布绽放完全落定的总时长 */
  static bloomTotalMsBySpan(spanVp: number, baseDelay: number = 16): number {
    return Motion.bloomDelayByDistance(spanVp, baseDelay) + 640;
  }

  /** 计算瀑布绽放动画完全落定所需的总时长，供延迟合流刷新避免半途重构闪烁 */
  static bloomTotalMs(count: number, baseDelay: number = 16): number {
    const lastIdx: number = count <= 1 ? 0 : (count - 1 > 16 ? 16 : count - 1);
    return Motion.bloomDelay(lastIdx, baseDelay) + 640;
  }

  /** 按真实距离计算的卡片显隐动画参数（纯中心缩放 + 淡入） */
  static bloomOpacityAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: 175,
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay),
      curve: Motion.std
    };
    return opts;
  }

  /** 按真实距离计算的卡片纯中心等比绽放动画参数（0.04 -> 1.0，共享 unifiedElastic） */
  static bloomScaleAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay),
      curve: Motion.unifiedElastic
    };
    return opts;
  }

  /** 按真实距离计算的卡片图标原位显隐动画（滞后卡片绽放 ICON_FLY_LAG_MS） */
  static iconFlyOpacityAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: 155,
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay) + Motion.ICON_FLY_LAG_MS,
      curve: Motion.std
    };
    return opts;
  }

  /** 按真实距离计算的卡片图标原位绽放缩放动画（0 -> 1） */
  static iconFlyScaleAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay) + Motion.ICON_FLY_LAG_MS,
      curve: Motion.iconFlyScaleSpring
    };
    return opts;
  }

  /** 按真实距离计算的卡片图标原位 180° 丝滑旋正动画（+180° -> 0°） */
  static iconFlyRotateAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: Motion.ICON_FLY_ROTATE_DURATION_MS,
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay) + Motion.ICON_FLY_LAG_MS,
      curve: Motion.iconFlyRotateCurve
    };
    return opts;
  }

  /** 按真实距离计算的分组小标题显隐动画参数 */
  static bloomHeaderOpacityAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      duration: 160,
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay),
      curve: Motion.std
    };
    return opts;
  }

  /** 按真实距离计算的分组小标题缩放动画参数 */
  static bloomHeaderScaleAnimByDist(distanceVp: number, mode: string,
    baseDelay: number = Motion.BLOOM_SUB_BASE_DELAY): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || distanceVp < 0) {
      return undefined;
    }
    const opts: AnimateParam = {
      delay: Motion.bloomDelayByDistance(distanceVp, baseDelay),
      curve: Motion.unifiedElastic
    };
    return opts;
  }

  /** 卡片从小到大长大显隐动画参数（纯中心缩放 + 淡入） */
  static bloomOpacityAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    return Motion.bloomOpacityAnimByDist(idx * Motion.BLOOM_FALLBACK_STEP_VP, mode, baseDelay);
  }

  /** 卡片从小到大纯中心等比绽放动画参数（0.04 -> 1.0，与顶栏共享 unifiedElastic 物理弹簧曲线） */
  static bloomScaleAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    return Motion.bloomScaleAnimByDist(idx * Motion.BLOOM_FALLBACK_STEP_VP, mode, baseDelay);
  }

  /** 分组小标题显隐动画参数 */
  static bloomHeaderOpacityAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    return Motion.bloomHeaderOpacityAnimByDist(idx * Motion.BLOOM_FALLBACK_STEP_VP, mode, baseDelay);
  }

  /** 分组小标题缩放动画参数 */
  static bloomHeaderScaleAnim(idx: number, mode: string, baseDelay: number = 16): AnimateParam | undefined {
    if (!Motion.isFlagship(mode) || idx < 0 || idx >= 18) {
      return undefined;
    }
    return Motion.bloomHeaderScaleAnimByDist(idx * Motion.BLOOM_FALLBACK_STEP_VP, mode, baseDelay);
  }

  /** 顶栏控件左->右弹性推出透明度动画参数 */
  static headerPopOpacityAnim(delayMs: number, mode: string, durationMs: number = 220): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { duration: durationMs, delay: delayMs, curve: Motion.std };
    return opts;
  }

  /** 顶栏控件左->右弹性推出物理弹簧参数（与全 App 共用 unifiedElastic） */
  static headerPopScaleAnim(delayMs: number, mode: string): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { delay: delayMs, curve: Motion.unifiedElastic };
    return opts;
  }

  /** 顶栏标题左->右弹性滑入动画参数（与全 App 共用 unifiedElastic） */
  static headerTitleSlideAnim(delayMs: number, mode: string): AnimateParam | undefined {
    if (!Motion.isFlagship(mode)) {
      return undefined;
    }
    const opts: AnimateParam = { delay: delayMs, curve: Motion.unifiedElastic };
    return opts;
  }

  /**
   * 由上到下逐卡景深绽放（供仍依赖 TransitionEffect 的辅助场景复用）：
   * 卡片从 0.04 倍居中缩放入场 + 淡入，共用 unifiedElastic。
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
    const wait: number = Motion.bloomDelayByDistance(clamped * Motion.BLOOM_FALLBACK_STEP_VP, baseDelay);
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 180, curve: Motion.std, delay: wait })
        .combine(TransitionEffect.translate({ y: 8 }).animation({ curve: Motion.unifiedElastic, delay: wait })),
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
   * 锚点下拉卡片展开转场：点击按钮后利落弹出，采用轻快 springSnappy，快慢有序。
   */
  static popupMenuTransition(mode: string, anchorRight: boolean = true): TransitionEffect {
    const cx: string = anchorRight ? '94%' : '6%';
    if (!Motion.isFlagship(mode)) {
      return TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 120, curve: Motion.std })
          .combine(TransitionEffect.scale({ x: 0.94, y: 0.94, centerX: cx, centerY: '0%' })
            .animation({ curve: Motion.springSnappy })),
        TransitionEffect.OPACITY.animation({ duration: 100, curve: Motion.std })
      );
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 130, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.84, y: 0.84, centerX: cx, centerY: '0%' }).animation({ curve: Motion.springSnappy }))
        .combine(TransitionEffect.translate({ y: -5 }).animation({ curve: Motion.springSnappy })),
      TransitionEffect.OPACITY.animation({ duration: 100, curve: Motion.std })
        .combine(TransitionEffect.scale({ x: 0.90, y: 0.90, centerX: cx, centerY: '0%' })
          .animation({ duration: 100, curve: Motion.std }))
    );
  }

  /** 同构双屏/多步骤容器整体横滑动画参数 */
  static stepPaneAnim(_mode: string): AnimateParam {
    return Motion.flagshipParallax();
  }

  /**
   * 步骤页 / 同构选项卡左右横推转场（零渐变淡入淡出，整页等速退场防止重合）：
   * 用于配对流程「电脑端准备 <-> 连接电脑」以及反馈中心内部页面切换。
   */
  static stepSlide(forward: boolean, _mode: string): TransitionEffect {
    const anim: AnimateParam = Motion.flagshipParallax();
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
