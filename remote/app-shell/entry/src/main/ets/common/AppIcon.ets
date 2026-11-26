import preferences from '@ohos.data.preferences';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppCtx } from './AppCtx';

export const ICON_LIGHT: string = 'light';
export const ICON_DARK: string = 'dark';
const PREF_STORE: string = 'dsh_mobile_cfg';
const PREF_KEY: string = 'appIconStyle';

export interface IconSwitchResult {
  desktopApplied: boolean;
  errCode: number;
  errMsg: string;
}

/**
 * 桌面分层图标与 App 内品牌图标状态同步工具。
 * 默认方案 D（纯粹曜黑 · dark），可按需切换至方案 B（冷银瓷白 · light）。
 */
export class AppIcon {
  static normalize(style: string): string {
    return style === ICON_LIGHT ? ICON_LIGHT : ICON_DARK;
  }

  static res(style: string): Resource {
    return style === ICON_LIGHT ? $r('app.media.app_icon') : $r('app.media.app_icon_dark');
  }

  /** 启动时读取本地偏好，并向系统核对当前启用的备用图标状态。 */
  static async init(): Promise<string> {
    let resolved: string = AppIcon.normalize(AppStorage.get<string>(PREF_KEY) ?? ICON_DARK);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      const saved: string = (await p.get(PREF_KEY, ICON_DARK)) as string;
      resolved = AppIcon.normalize(saved);
    } catch (e) {
      // ignore preferences read errors, fallback to current state
    }
    try {
      const list: Array<bundleManager.AlternateIconInfo> = await bundleManager.getAlternateIcons();
      let lightEnabled: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].iconName === ICON_LIGHT && list[i].enabled) {
          lightEnabled = true;
          break;
        }
      }
      resolved = lightEnabled ? ICON_LIGHT : ICON_DARK;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      console.info('DSH_ICON getAlternateIcons skip code=' + String(err.code) + ' msg=' + err.message);
    }
    AppStorage.setOrCreate(PREF_KEY, resolved);
    return resolved;
  }

  /** 切换应用图标风格：同步更新全局 UI 状态、本地偏好及 HarmonyOS 桌面备用图标。 */
  static async switchTo(style: string): Promise<IconSwitchResult> {
    const target: string = AppIcon.normalize(style);
    AppStorage.setOrCreate(PREF_KEY, target);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put(PREF_KEY, target);
      await p.flush();
    } catch (e) {
      console.warn('DSH_ICON save pref failed :: ' + (e as Error).message);
    }

    try {
      await bundleManager.setAlternateIcon(target === ICON_LIGHT ? ICON_LIGHT : '');
      console.info('DSH_ICON setAlternateIcon ok target=' + target);
      const ok: IconSwitchResult = { desktopApplied: true, errCode: 0, errMsg: '' };
      return ok;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      const code: number = err.code ?? -1;
      const msg: string = err.message ?? '';
      // 17700309 表示当前未启用任何备用图标，切回默认黑色态时视为已生效
      if (target === ICON_DARK && code === 17700309) {
        console.info('DSH_ICON already on default dark icon (17700309)');
        const okDefault: IconSwitchResult = { desktopApplied: true, errCode: 0, errMsg: '' };
        return okDefault;
      }
      console.warn('DSH_ICON setAlternateIcon fail code=' + String(code) + ' msg=' + msg);
      const failRes: IconSwitchResult = { desktopApplied: false, errCode: code, errMsg: msg };
      return failRes;
    }
  }
}
