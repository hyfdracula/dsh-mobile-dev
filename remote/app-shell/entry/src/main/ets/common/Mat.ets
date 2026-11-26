import uiMaterial from '@ohos.arkui.uiMaterial';
import { hdsMaterial } from '@kit.UIDesignKit';
import { Tokens } from './Tokens';

/**
 * 双皮肤视觉引擎：
 * - `hdsOn = true` ：沉浸光感 · 液态玻璃皮肤（原生 ImmersiveMaterial 折射 + 柔霜玻璃层级）
 * - `hdsOn = false`：经典实色 · 高对比皮肤（零模糊纯实色卡片 + 1px 清晰边框 + 品牌实色按钮）
 */
export class Mat {
  private static cache: uiMaterial.Material | undefined = undefined;
  private static whiteCache: uiMaterial.Material | undefined = undefined;
  private static chatHeaderCache: uiMaterial.Material | undefined = undefined;
  private static fabCache: uiMaterial.Material | undefined = undefined;
  private static composerCache: uiMaterial.Material | undefined = undefined;
  private static popupCache: uiMaterial.Material | undefined = undefined;
  private static sheetCache: uiMaterial.Material | undefined = undefined;
  private static drawerCache: uiMaterial.Material | undefined = undefined;

  private static hwImmersive: boolean | undefined = undefined;
  private static hwMaterial: boolean | undefined = undefined;

  static invalidate(): void {
    Mat.cache = undefined;
    Mat.whiteCache = undefined;
    Mat.chatHeaderCache = undefined;
    Mat.fabCache = undefined;
    Mat.composerCache = undefined;
    Mat.popupCache = undefined;
    Mat.sheetCache = undefined;
    Mat.drawerCache = undefined;
  }

  private static checkHwImmersive(): boolean {
    if (Mat.hwImmersive === undefined) {
      try {
        const types: hdsMaterial.MaterialType[] = hdsMaterial.getSystemMaterialTypes();
        Mat.hwImmersive = types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0;
      } catch (_e) {
        Mat.hwImmersive = false;
      }
    }
    return Mat.hwImmersive === true;
  }

  static isNativeSupported(): boolean {
    if (Mat.hwMaterial === undefined) {
      try {
        Mat.hwMaterial = uiMaterial.isImmersiveMaterialSupported();
      } catch (_e) {
        Mat.hwMaterial = false;
      }
    }
    return Mat.hwMaterial === true;
  }

  /** 是否启用全屏 HdsNavigation / HdsTabs 沉浸光感 */
  static isImmersiveReady(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('hdsOn');
    if (v === false) {
      return false;
    }
    return Mat.checkHwImmersive();
  }

  static isGlass(hdsOn: boolean): boolean {
    return hdsOn;
  }

  static empty(): uiMaterial.Material {
    return uiMaterial.Material.empty;
  }

  private static make(
    style: uiMaterial.ImmersiveStyle,
    tintColor: string,
    interactive: boolean,
    applyShadow: boolean,
    lightColor?: string
  ): uiMaterial.Material {
    try {
      const opts: uiMaterial.ImmersiveOptions = {
        style: style,
        materialColor: tintColor,
        applyShadow: applyShadow,
        interactive: interactive
      };
      if (lightColor !== undefined) {
        const light: uiMaterial.LightEffectOptions = { color: lightColor };
        opts.lightEffect = light;
      }
      return new uiMaterial.ImmersiveMaterial(opts);
    } catch (_e) {
      return uiMaterial.Material.empty;
    }
  }

  /** 顶栏 / 底栏液态玻璃材质 */
  static bar(): uiMaterial.Material {
    if (Mat.cache === undefined) {
      Mat.cache = Mat.make(
        uiMaterial.ImmersiveStyle.REGULAR,
        Tokens.isDark ? '#8C121620' : '#A6FFFFFF',
        false,
        false,
        Tokens.isDark ? '#66FFFFFF' : '#CCFFFFFF'
      );
    }
    return Mat.cache as uiMaterial.Material;
  }

  /** 头部玻璃胶囊按钮材质（与对话页顶栏保持 100% 统一的高通透 ULTRA_THIN 液态玻璃） */
  static white(): uiMaterial.Material {
    if (Mat.whiteCache === undefined) {
      Mat.whiteCache = Mat.make(
        uiMaterial.ImmersiveStyle.ULTRA_THIN,
        Tokens.isDark ? '#24161B26' : '#26FFFFFF',
        true,
        true,
        Tokens.isDark ? '#99FFFFFF' : '#FFFFFFFF'
      );
    }
    return Mat.whiteCache as uiMaterial.Material;
  }

  static bySwitch(): uiMaterial.Material {
    return Mat.isImmersiveReady() ? Mat.bar() : uiMaterial.Material.empty;
  }

  static whiteOn(on: boolean): uiMaterial.Material {
    if (!on) {
      return uiMaterial.Material.empty;
    }
    return Mat.isNativeSupported() ? Mat.white() : uiMaterial.Material.empty;
  }

  /** 对话页顶部悬浮胶囊（复用与首页顶栏完全统一的 ULTRA_THIN 高通透液态玻璃） */
  static chatHeader(glass: boolean): uiMaterial.Material {
    if (!glass || !Mat.isNativeSupported()) {
      return uiMaterial.Material.empty;
    }
    if (Mat.chatHeaderCache === undefined) {
      Mat.chatHeaderCache = Mat.make(
        uiMaterial.ImmersiveStyle.ULTRA_THIN,
        Tokens.isDark ? '#24161B26' : '#26FFFFFF',
        true,
        true,
        Tokens.isDark ? '#99FFFFFF' : '#FFFFFFFF'
      );
    }
    return Mat.chatHeaderCache as uiMaterial.Material;
  }

  /** 首页悬浮新建对话按钮（液态玻璃模式使用超厚高密磨砂+交互微形变；实色模式关闭） */
  static fab(glass: boolean): uiMaterial.Material {
    if (!glass || !Mat.isNativeSupported()) {
      return uiMaterial.Material.empty;
    }
    if (Mat.fabCache === undefined) {
      Mat.fabCache = Mat.make(
        uiMaterial.ImmersiveStyle.ULTRA_THICK,
        Tokens.isDark ? '#EB1C2333' : '#F5FFFFFF',
        true,
        true,
        Tokens.isDark ? '#8CFFFFFF' : '#FFFFFFFF'
      );
    }
    return Mat.fabCache as uiMaterial.Material;
  }

  /** 页面内悬浮玻璃材质（用于 HDS titleBar / 弹窗作用域之外的沉底按键、底部对话框与展开菜单）：
   * 使用 Rosen 实时 GPU 背景模糊 backgroundEffect，与顶部 HDS ULTRA_THIN 胶囊及弹窗 THIN 卡片视觉 100% 统一。
   */
  static glassEffect(glass: boolean, dense: boolean = false): BackgroundEffectOptions {
    if (!glass) {
      const off: BackgroundEffectOptions = { radius: 0, color: Color.Transparent };
      return off;
    }
    const opts: BackgroundEffectOptions = {
      radius: dense ? 30 : 22,
      saturation: Tokens.isDark ? 1.45 : 1.35,
      brightness: Tokens.isDark ? 0.96 : 1.02,
      color: dense
        ? (Tokens.isDark ? '#5C141A26' : '#6EFFFFFF')
        : (Tokens.isDark ? '#38161B26' : '#40FFFFFF'),
      adaptiveColor: AdaptiveColor.DEFAULT,
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    };
    return opts;
  }

  /**
   * 底部悬浮阅读卡（隐私政策 / 用户协议 / 开源许可 / 外网配置向导）专用沉浸光感雾面玻璃：
   * 在保持正文清晰可读的同时，透出后方景深虚化色彩，关闭沉浸光感时退回完全实色零模糊表面。
   */
  static readingGlassEffect(glass: boolean): BackgroundEffectOptions {
    if (!glass) {
      const off: BackgroundEffectOptions = { radius: 0, color: Color.Transparent };
      return off;
    }
    const opts: BackgroundEffectOptions = {
      radius: 32,
      saturation: Tokens.isDark ? 1.50 : 1.38,
      brightness: Tokens.isDark ? 0.94 : 1.03,
      color: Tokens.isDark ? '#4F141A26' : '#5EFFFFFF',
      adaptiveColor: AdaptiveColor.DEFAULT,
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    };
    return opts;
  }

  /** 页面内悬浮玻璃边框（高光细边，与顶部沉浸胶囊一致） */
  static glassRimBorder(glass: boolean): BorderOptions {
    const b: BorderOptions = {
      width: 1,
      color: glass ? (Tokens.isDark ? '#4DFFFFFF' : '#CCFFFFFF') : Tokens.line
    };
    return b;
  }

  /** 页面内悬浮玻璃柔和投影 */
  static glassFloatShadow(glass: boolean): ShadowOptions {
    if (glass) {
      const s: ShadowOptions = {
        radius: 20,
        color: Tokens.isDark ? '#52000000' : '#1C1C2C4D',
        offsetX: 0,
        offsetY: 6
      };
      return s;
    }
    return Mat.floatShadow(false);
  }

  /** 对话输入区底座材质（保留供系统作用域控件调用） */
  static composer(glass: boolean): uiMaterial.Material {
    if (!glass || !Mat.isNativeSupported()) {
      return uiMaterial.Material.empty;
    }
    if (Mat.composerCache === undefined) {
      Mat.composerCache = Mat.make(
        uiMaterial.ImmersiveStyle.ULTRA_THIN,
        Tokens.isDark ? '#24161B26' : '#26FFFFFF',
        false,
        true,
        Tokens.isDark ? '#99FFFFFF' : '#FFFFFFFF'
      );
    }
    return Mat.composerCache as uiMaterial.Material;
  }

  /** 全站统一弹出与展开卡片沉浸光感材质（模型选择 / 上下文统计 / 分组方式 / 选择电脑 / 远控工作台 / 目标 / 权限等共用） */
  static overlay(glass: boolean): uiMaterial.Material {
    if (!glass || !Mat.isNativeSupported()) {
      return uiMaterial.Material.empty;
    }
    if (Mat.popupCache === undefined) {
      Mat.popupCache = Mat.make(
        uiMaterial.ImmersiveStyle.THIN,
        Tokens.isDark ? '#38141A26' : '#3BFFFFFF',
        false,
        true,
        Tokens.isDark ? '#73FFFFFF' : '#F2FFFFFF'
      );
    }
    return Mat.popupCache as uiMaterial.Material;
  }

  /** 弹出气泡菜单材质（指向全站统一 overlay 沉浸光感） */
  static popup(glass: boolean): uiMaterial.Material {
    return Mat.overlay(glass);
  }

  /** 半模态底部卡片材质（指向全站统一 overlay 沉浸光感，与所有弹出菜单透明度 100% 一致） */
  static sheet(glass: boolean): uiMaterial.Material {
    return Mat.overlay(glass);
  }

  /** 待发送排队抽屉高密厚玻璃材质（确保遮盖下方消息文本不透字） */
  static drawer(glass: boolean): uiMaterial.Material {
    if (!glass || !Mat.isNativeSupported()) {
      return uiMaterial.Material.empty;
    }
    if (Mat.drawerCache === undefined) {
      Mat.drawerCache = Mat.make(
        uiMaterial.ImmersiveStyle.ULTRA_THICK,
        Tokens.isDark ? '#F0121620' : '#F6FFFFFF',
        false,
        true,
        Tokens.isDark ? '#47FFFFFF' : '#A6FFFFFF'
      );
    }
    return Mat.drawerCache as uiMaterial.Material;
  }

  // ===================== 双皮肤统一视觉 Token Helpers =====================

  static cardBg(glass: boolean): string {
    return glass ? Tokens.glassStrong : Tokens.surface;
  }

  /** 带左滑底层按钮的列表卡片底色：在液态玻璃下保持高不透明度以完全遮盖底层按钮 */
  static tileBg(glass: boolean): string {
    if (!glass) {
      return Tokens.surface;
    }
    return Tokens.isDark ? '#FA171B24' : '#FCFFFFFF';
  }

  static cardBorderColor(glass: boolean): string {
    if (glass) {
      return Tokens.isDark ? '#2EFFFFFF' : '#BAFFFFFF';
    }
    return Tokens.line;
  }

  static cardBorder(glass: boolean): BorderOptions {
    const b: BorderOptions = {
      width: 1,
      color: Mat.cardBorderColor(glass)
    };
    return b;
  }

  static cardShadow(glass: boolean): ShadowOptions {
    if (glass) {
      const s: ShadowOptions = {
        radius: 18,
        color: Tokens.isDark ? '#42000000' : '#1A1C2C4D',
        offsetX: 0,
        offsetY: 6
      };
      return s;
    }
    const empty: ShadowOptions = {
      radius: 0,
      color: Color.Transparent
    };
    return empty;
  }

  static subCardBg(glass: boolean): string {
    if (glass) {
      return Tokens.isDark ? '#1CFFFFFF' : '#42FFFFFF';
    }
    return Tokens.surface2;
  }

  static subCardBorderColor(glass: boolean): string {
    if (glass) {
      return Tokens.isDark ? '#2BFFFFFF' : '#8CFFFFFF';
    }
    return Tokens.line;
  }

  static subCardBorder(glass: boolean): BorderOptions {
    const b: BorderOptions = {
      width: 1,
      color: Mat.subCardBorderColor(glass)
    };
    return b;
  }

  static floatBg(glass: boolean): ResourceColor {
    if (!glass) {
      return Tokens.surface;
    }
    return Mat.isNativeSupported() ? Color.Transparent : Tokens.popBg;
  }

  static floatBlur(glass: boolean): number {
    if (!glass) {
      return 0;
    }
    return Mat.isNativeSupported() ? 0 : 24;
  }

  static floatBorderColor(glass: boolean): string {
    if (glass) {
      return Tokens.isDark ? '#47FFFFFF' : '#B8FFFFFF';
    }
    return Tokens.line;
  }

  static floatBorder(glass: boolean): BorderOptions {
    const b: BorderOptions = {
      width: 1,
      color: Mat.floatBorderColor(glass)
    };
    return b;
  }

  static floatShadow(glass: boolean): ShadowOptions {
    if (glass) {
      const s: ShadowOptions = {
        radius: 24,
        color: Tokens.popShadow,
        offsetX: 0,
        offsetY: 8
      };
      return s;
    }
    const flat: ShadowOptions = {
      radius: 8,
      color: Tokens.isDark ? '#24000000' : '#10101828',
      offsetX: 0,
      offsetY: 2
    };
    return flat;
  }

  static drawerBg(glass: boolean): ResourceColor {
    if (!glass) {
      return Tokens.surface;
    }
    if (Mat.isNativeSupported()) {
      return Tokens.isDark ? '#F0121620' : '#F6FFFFFF';
    }
    return Tokens.isDark ? '#F2151A25' : '#F7FFFFFF';
  }

  static drawerBlur(glass: boolean): number {
    return glass ? 28 : 0;
  }

  static popupBg(glass: boolean): ResourceColor {
    if (!glass) {
      return Tokens.surface;
    }
    return Mat.isNativeSupported() ? Color.Transparent : (Tokens.isDark ? '#66141A26' : '#73FFFFFF');
  }

  /** 统一弹出卡片 CustomPopupOptions：直接将原生 API 26 systemMaterial 挂在弹窗窗口上，与 bindSheet 透明度 100% 一致 */
  static popupOpts(
    glass: boolean,
    builder: CustomBuilder,
    placement: Placement,
    offset: Position,
    onStateChange: (visible: boolean) => void,
    radius: number = 20,
    transition?: TransitionEffect
  ): CustomPopupOptions {
    const native: boolean = glass && Mat.isNativeSupported();
    const opts: CustomPopupOptions = {
      builder: builder,
      placement: placement,
      popupColor: glass
        ? (native ? Color.Transparent : (Tokens.isDark ? '#66141A26' : '#73FFFFFF'))
        : Tokens.surface,
      backgroundBlurStyle: glass
        ? (native ? BlurStyle.NONE : BlurStyle.COMPONENT_THIN)
        : BlurStyle.NONE,
      systemMaterial: native ? Mat.overlay(true) : uiMaterial.Material.empty,
      enableArrow: false,
      radius: radius,
      offset: offset,
      onStateChange: (e) => {
        onStateChange(e.isVisible);
      }
    };
    if (transition !== undefined) {
      opts.transition = transition;
    }
    return opts;
  }

  static sheetOpts(
    glass: boolean,
    height: SheetSize | Length,
    onDisappear?: () => void,
    showClose: boolean = false,
    dragBar: boolean = true
  ): SheetOptions {
    const native: boolean = glass && Mat.isNativeSupported();
    const opts: SheetOptions = {
      height: height,
      dragBar: dragBar,
      showClose: showClose,
      backgroundColor: glass
        ? (native ? Color.Transparent : (Tokens.isDark ? '#66141A26' : '#73FFFFFF'))
        : Tokens.surface,
      blurStyle: glass ? (native ? BlurStyle.NONE : BlurStyle.COMPONENT_THIN) : BlurStyle.NONE,
      maskColor: glass
        ? (Tokens.isDark ? '#2B000000' : '#140F172A')
        : (Tokens.isDark ? '#73000000' : '#400F172A'),
      borderWidth: 1,
      borderColor: glass ? Mat.floatBorderColor(true) : Tokens.line,
      systemMaterial: native ? Mat.overlay(true) : uiMaterial.Material.empty,
      onDisappear: onDisappear
    };
    return opts;
  }
}
