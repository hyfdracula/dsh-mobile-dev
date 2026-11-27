import { KeyboardAvoidMode, UIContext, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppCtx } from './AppCtx';

/**
 * 窗口安全区、系统状态栏/导航条前景色与默认软键盘避让。
 *
 * 统一维护 AppStorage 中的 topInset / bottomInset（单位 vp），
 * 并在深浅色切换时同步系统栏文字与手势条颜色，避免浅色底配白字看不清时钟电量。
 */
export class SafeArea {
  private static mainWin: window.Window | null = null;
  private static avoidBound: boolean = false;
  private static hasPendingBar: boolean = false;
  private static lastDark: boolean = true;
  private static lastBg: string = '#0A0C10';
  private static kbNoneTokenSeq: number = 0;
  private static kbNoneHolders: Set<number> = new Set<number>();

  private static readonly onAvoidChange: (opts: window.AvoidAreaOptions) => void =
    (opts: window.AvoidAreaOptions): void => {
      if (SafeArea.mainWin === null) {
        return;
      }
      if (opts.type === window.AvoidAreaType.TYPE_SYSTEM ||
        opts.type === window.AvoidAreaType.TYPE_CUTOUT ||
        opts.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
        SafeArea.refreshInsets(SafeArea.mainWin);
      }
    };

  private static toVp(win: window.Window, px: number): number {
    if (px <= 0) {
      return 0;
    }
    try {
      const uiCtx = win.getUIContext();
      if (uiCtx !== undefined && uiCtx !== null) {
        const v: number = uiCtx.px2vp(px);
        if (Number.isFinite(v) && v > 0) {
          return Math.ceil(v);
        }
      }
    } catch (e) {
    }
    const fallback: number = AppCtx.px2vp(px);
    return fallback > 0 ? Math.ceil(fallback) : Math.ceil(px / 3.25);
  }

  private static topPxOf(win: window.Window, kind: window.AvoidAreaType): number {
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(kind);
      if (area === undefined || area.topRect === undefined || area.topRect.height <= 0) {
        return 0;
      }
      return area.topRect.top + area.topRect.height;
    } catch (e) {
      return 0;
    }
  }

  private static bottomPxOf(win: window.Window, kind: window.AvoidAreaType): number {
    try {
      const area: window.AvoidArea = win.getWindowAvoidArea(kind);
      if (area === undefined || area.bottomRect === undefined || area.bottomRect.height <= 0) {
        return 0;
      }
      return area.bottomRect.height;
    } catch (e) {
      return 0;
    }
  }

  private static clampTop(rawVp: number): number {
    if (!Number.isFinite(rawVp) || rawVp <= 0) {
      return 40;
    }
    const ceiled: number = Math.ceil(rawVp);
    if (ceiled < 28) {
      return 28;
    }
    if (ceiled > 72) {
      return 72;
    }
    return ceiled;
  }

  private static clampBottom(rawVp: number): number {
    if (!Number.isFinite(rawVp) || rawVp <= 0) {
      return 20;
    }
    const ceiled: number = Math.ceil(rawVp);
    if (ceiled < 12) {
      return 12;
    }
    if (ceiled > 44) {
      return 44;
    }
    return ceiled;
  }

  static refreshInsets(win: window.Window): void {
    const sysTop: number = SafeArea.topPxOf(win, window.AvoidAreaType.TYPE_SYSTEM);
    const cutTop: number = SafeArea.topPxOf(win, window.AvoidAreaType.TYPE_CUTOUT);
    const topVp: number = SafeArea.clampTop(SafeArea.toVp(win, Math.max(sysTop, cutTop)));

    const sysBottom: number = SafeArea.bottomPxOf(win, window.AvoidAreaType.TYPE_SYSTEM);
    const navBottom: number = SafeArea.bottomPxOf(win, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const bottomVp: number = SafeArea.clampBottom(SafeArea.toVp(win, Math.max(sysBottom, navBottom)));

    AppStorage.setOrCreate('topInset', topVp);
    AppStorage.setOrCreate('bottomInset', bottomVp);
  }

  /**
   * 绑定主窗口，初始化安全区高度并监听系统避让区动态变化。
   */
  static attach(win: window.Window): void {
    if (SafeArea.mainWin !== null && SafeArea.mainWin !== win && SafeArea.avoidBound) {
      try {
        SafeArea.mainWin.off('avoidAreaChange', SafeArea.onAvoidChange);
      } catch (e) {
        // 旧窗口可能已销毁
      }
      SafeArea.avoidBound = false;
    }
    SafeArea.mainWin = win;
    SafeArea.refreshInsets(win);
    if (!SafeArea.avoidBound) {
      try {
        win.on('avoidAreaChange', SafeArea.onAvoidChange);
        SafeArea.avoidBound = true;
      } catch (e) {
        console.info('DSH_SAFE avoidArea listener failed: ' + JSON.stringify(e));
      }
    }
    if (SafeArea.hasPendingBar) {
      SafeArea.syncSystemBar(SafeArea.lastDark, SafeArea.lastBg);
    }
  }

  static detach(): void {
    if (SafeArea.mainWin !== null && SafeArea.avoidBound) {
      try {
        SafeArea.mainWin.off('avoidAreaChange', SafeArea.onAvoidChange);
      } catch (e) {
      }
      SafeArea.avoidBound = false;
    }
    SafeArea.kbNoneHolders.clear();
    SafeArea.mainWin = null;
  }

  /**
   * 同步状态栏与底部导航条的前景文字/图标颜色。
   */
  static syncSystemBar(dark: boolean, bg: string = ''): void {
    SafeArea.lastDark = dark;
    if (bg !== '') {
      SafeArea.lastBg = bg;
    }
    SafeArea.hasPendingBar = true;
    if (SafeArea.mainWin === null) {
      return;
    }
    const contentColor: string = dark ? '#F2F4FA' : '#10131A';
    const props: window.SystemBarProperties = {
      statusBarColor: '#00000000',
      statusBarContentColor: contentColor,
      isStatusBarLightIcon: dark,
      navigationBarColor: '#00000000',
      navigationBarContentColor: contentColor,
      isNavigationBarLightIcon: dark
    };
    try {
      SafeArea.mainWin.setWindowSystemBarProperties(props).catch((e: BusinessError) => {
        console.info('DSH_SAFE systemBar failed: ' + JSON.stringify(e));
      });
    } catch (e) {
      console.info('DSH_SAFE systemBar throw: ' + JSON.stringify(e));
    }
  }

  static nextKbToken(): number {
    SafeArea.kbNoneTokenSeq += 1;
    return SafeArea.kbNoneTokenSeq;
  }

  private static applyKeyboardAvoidMode(uiCtx?: UIContext): void {
    const mode: KeyboardAvoidMode = SafeArea.kbNoneHolders.size > 0
      ? KeyboardAvoidMode.NONE
      : KeyboardAvoidMode.RESIZE;
    if (uiCtx !== undefined) {
      try {
        uiCtx.setKeyboardAvoidMode(mode);
      } catch (e) {
        console.info('DSH_SAFE keyboardMode uiCtx failed: ' + JSON.stringify(e));
      }
    }
    if (SafeArea.mainWin !== null) {
      try {
        SafeArea.mainWin.getUIContext().setKeyboardAvoidMode(mode);
      } catch (e) {
        console.info('DSH_SAFE keyboardMode mainWin failed: ' + JSON.stringify(e));
      }
    }
  }

  static holdKeyboardNone(token: number, uiCtx?: UIContext): void {
    SafeArea.kbNoneHolders.add(token);
    SafeArea.applyKeyboardAvoidMode(uiCtx);
  }

  static releaseKeyboardNone(token: number, uiCtx?: UIContext): void {
    SafeArea.kbNoneHolders.delete(token);
    SafeArea.applyKeyboardAvoidMode(uiCtx);
  }

  static enforceKeyboardAvoidMode(uiCtx?: UIContext): void {
    SafeArea.applyKeyboardAvoidMode(uiCtx);
  }

  /**
   * 页面加载完成后默认启用软键盘 RESIZE 避让，使配对页、设置页、弹窗表单在呼出键盘时可滚可见。
   * 若已有页面持有 kbNone 令牌则维持 KeyboardAvoidMode.NONE，避免晚到的初始化回写覆盖。
   */
  static setKeyboardResize(win: window.Window): void {
    try {
      SafeArea.applyKeyboardAvoidMode(win.getUIContext());
    } catch (e) {
      console.info('DSH_SAFE keyboardResize skipped: ' + JSON.stringify(e));
    }
  }
}
