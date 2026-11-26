import { AppCtx } from './AppCtx';
import { Haptics } from './Haptics';
import { LinkLog } from './LinkLog';
import { Motion } from './Motion';

/**
 * 全 App 唯一的轻提示出口：
 * - 灵动档：通过全局液态玻璃弹簧胶囊（GlassToastHost）从底部上方弹性浮出，支持语义矢量图标；
 * - 经典档：沿用系统原生 UIContext.getPromptAction().showToast。
 */
export class Toast {
  private static seq: number = 0;

  static ok(msg: string): void {
    Toast.dispatch(msg, 'ok', 1800);
  }

  static info(msg: string): void {
    Toast.dispatch(msg, 'info', 1900);
  }

  static err(msg: string): void {
    Haptics.error();
    LinkLog.record('ERR', 'toast=' + msg);
    Toast.dispatch(msg, 'err', 2600);
  }

  static show(msg: string, duration: number): void {
    Toast.dispatch(msg, 'info', duration);
  }

  private static dispatch(msg: string, kind: string, duration: number): void {
    if (Motion.isFlagship()) {
      Toast.seq += 1;
      AppStorage.setOrCreate('glassToastText', msg);
      AppStorage.setOrCreate('glassToastKind', kind);
      AppStorage.setOrCreate('glassToastDur', duration);
      AppStorage.setOrCreate('glassToastSeq', Toast.seq);
      return;
    }
    AppCtx.showToast(msg, duration);
  }
}
