import vibrator from '@ohos.vibrator';

/**
 * 分级语义触感引擎：
 * 优先调用鸿蒙线性马达原生预设波形（vibrator.HapticFeedback / EffectId），
 * 若当前设备或模拟器不支持特定预设，则自动回退到多节奏时序脉冲，
 * 为轻触、下拉刻度、开关、确认、成功、警告、报错与长按提供截然不同的手感反馈。
 * 全局开关由设置页控制，Index 启动时从 preferences 读入。
 */
export class Haptics {
  static enabled: boolean = true;
  private static supportCache: Map<string, boolean> = new Map<string, boolean>();
  private static seq: number = 0;

  /** 下拉菜单项 / 筛选选项刻度轻点 */
  static tick(): void {
    Haptics.fire('haptic.clock.timer', [7], 'touch');
  }

  /** 普通列表行与常规按钮点击 */
  static tap(): void {
    Haptics.fire('haptic.effect.soft', [11], 'touch');
  }

  /** 开关拨动：开启清脆利落，关闭轻柔收拢 */
  static toggle(isOn: boolean): void {
    if (isOn) {
      Haptics.fire('haptic.effect.sharp', [13], 'touch');
    } else {
      Haptics.fire('haptic.effect.soft', [8], 'touch');
    }
  }

  /** 返回上一页 / 拖拽关闭浮层 / 收起面板 */
  static soft(): void {
    Haptics.fire('haptic.effect.soft', [14], 'physicalFeedback');
  }

  /** 明确的操作确认（发送消息、保存配置、确认提交） */
  static confirm(): void {
    Haptics.fire('haptic.effect.hard', [18], 'touch');
  }

  /** 完成反馈（复制成功、配对成功、导出成功）：双连轻跳节奏 */
  static success(): void {
    Haptics.fire('haptic.notice.success', [10, 55, 16], 'notification');
  }

  /** 警示反馈（停止生成、移除/清空二次确认）：沉稳双拍提示 */
  static warn(): void {
    Haptics.fire('haptic.notice.warning', [18, 65, 18], 'notification');
  }

  /** 失败/错误反馈（请求异常、校验阻断）：短三连提示 */
  static error(): void {
    Haptics.fire('haptic.notice.fail', [14, 45, 14, 45, 22], 'notification');
  }

  /** 长按弹出菜单 */
  static long(): void {
    Haptics.fire('haptic.effect.hard', [26], 'physicalFeedback');
  }

  private static isPresetSupported(effectId: string): boolean {
    const cached: boolean | undefined = Haptics.supportCache.get(effectId);
    if (cached !== undefined) {
      return cached;
    }
    let ok: boolean = false;
    try {
      ok = vibrator.isSupportEffectSync(effectId);
    } catch (_e) {
      ok = false;
    }
    Haptics.supportCache.set(effectId, ok);
    return ok;
  }

  private static fire(effectId: string, fallbackPattern: number[], usage: vibrator.Usage): void {
    if (!Haptics.enabled) {
      return;
    }
    const curSeq: number = ++Haptics.seq;
    if (Haptics.isPresetSupported(effectId)) {
      try {
        vibrator.startVibration(
          { type: 'preset', effectId: effectId, count: 1 },
          { id: 0, usage: usage }
        ).catch(() => {
          Haptics.supportCache.set(effectId, false);
          if (curSeq === Haptics.seq) {
            Haptics.firePattern(fallbackPattern, usage, curSeq);
          }
        });
        return;
      } catch (_e) {
        Haptics.supportCache.set(effectId, false);
      }
    }
    Haptics.firePattern(fallbackPattern, usage, curSeq);
  }

  /**
   * 偶数位为振动毫秒数，奇数位为停顿间隔毫秒数（如 [10, 55, 16]）。
   */
  private static firePattern(pattern: number[], usage: vibrator.Usage, seqId: number): void {
    if (!Haptics.enabled || pattern.length === 0) {
      return;
    }
    const triggerOnce = (ms: number): void => {
      try {
        vibrator.startVibration(
          { type: 'time', duration: ms },
          { id: 0, usage: usage }
        ).catch((e: Error) => {
          console.error('DSH_HAP fail :: ' + e.message);
        });
      } catch (e) {
        console.error('DSH_HAP throw :: ' + (e as Error).message);
      }
    };
    triggerOnce(pattern[0]);
    let offset: number = pattern[0];
    for (let i: number = 1; i + 1 < pattern.length; i += 2) {
      offset += pattern[i];
      const dur: number = pattern[i + 1];
      setTimeout(() => {
        if (Haptics.enabled && seqId === Haptics.seq) {
          triggerOnce(dur);
        }
      }, offset);
      offset += dur;
    }
  }
}
