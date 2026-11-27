import connection from '@ohos.net.connection';
import { BusinessError } from '@kit.BasicServicesKit';
import { LinkLog } from './LinkLog';

/**
 * 网络连通与传输类型监听：
 * 冷启动读取真实系统默认网络，支持 stop() 注销监听，bearer 集合去重防风暴。
 */
export class Net {
  private static started: boolean = false;
  private static conn: connection.NetConnection | null = null;
  private static lastBearerSig: string = '';

  private static collectBearers(fallbackCaps?: connection.NetCapabilities): number[] {
    const seen: number[] = [];
    const addFrom = (caps?: connection.NetCapabilities): void => {
      if (caps === undefined || caps.bearerTypes === undefined) {
        return;
      }
      const list: number[] = caps.bearerTypes;
      for (let i = 0; i < list.length; i++) {
        const b: number = list[i];
        if (seen.indexOf(b) < 0) {
          seen.push(b);
        }
      }
    };
    try {
      const all: connection.NetHandle[] = connection.getAllNetsSync();
      if (all !== undefined && all.length > 0) {
        for (let i = 0; i < all.length; i++) {
          const h: connection.NetHandle = all[i];
          if (h !== undefined && h.netId !== 0) {
            try {
              addFrom(connection.getNetCapabilitiesSync(h));
            } catch (_e) {
            }
          }
        }
      }
    } catch (_e) {
    }
    try {
      const def: connection.NetHandle | undefined = connection.getDefaultNetSync();
      if (def !== undefined && def.netId !== 0) {
        addFrom(connection.getNetCapabilitiesSync(def));
      }
    } catch (_e) {
    }
    if (seen.length === 0 && fallbackCaps !== undefined) {
      addFrom(fallbackCaps);
    }
    seen.sort((a: number, b: number) => a - b);
    return seen;
  }

  private static bearerSignature(caps?: connection.NetCapabilities): string {
    try {
      const raw: number[] = Net.collectBearers(caps);
      if (raw.length === 0) {
        return 'none';
      }
      // 过滤 VPN 虚拟网卡抖动噪音：存在物理网卡（Wi-Fi/蜂窝/以太网）时仅按物理承载判断网络切换
      const phys: number[] = [];
      for (let i = 0; i < raw.length; i++) {
        if (raw[i] !== connection.NetBearType.BEARER_VPN) {
          phys.push(raw[i]);
        }
      }
      const list: number[] = phys.length > 0 ? phys : raw;
      list.sort((a: number, b: number) => a - b);
      return list.length > 0 ? list.join(',') : 'none';
    } catch (e) {
      return '';
    }
  }

  private static checkInitialOnline(): boolean {
    try {
      const hasNet: boolean = connection.hasDefaultNetSync();
      if (hasNet) {
        const net: connection.NetHandle | undefined = connection.getDefaultNetSync();
        if (net !== undefined && net.netId !== 0) {
          return true;
        }
      }
      const all: connection.NetHandle[] = connection.getAllNetsSync();
      if (all !== undefined) {
        for (let i = 0; i < all.length; i++) {
          if (all[i] !== undefined && all[i].netId !== 0) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      return true;
    }
  }

  static start(): void {
    if (Net.started) {
      return;
    }
    Net.started = true;
    AppStorage.setOrCreate('online', Net.checkInitialOnline());
    Net.lastBearerSig = Net.bearerSignature();
    try {
      const nc: connection.NetConnection = connection.createNetConnection();
      nc.on('netAvailable', () => {
        Net.set(true);
        const sig: string = Net.bearerSignature();
        if (sig !== '' && sig !== Net.lastBearerSig) {
          Net.lastBearerSig = sig;
          LinkLog.record('NET', 'bearer=' + Net.describeBearers());
          AppStorage.setOrCreate('netBearerTick', Date.now());
        }
      });
      nc.on('netCapabilitiesChange', (data: connection.NetCapabilityInfo) => {
        const sig: string = Net.bearerSignature(data !== undefined ? data.netCap : undefined);
        if (sig !== '' && sig !== Net.lastBearerSig) {
          Net.lastBearerSig = sig;
          LinkLog.record('NET', 'bearer=' + Net.describeBearers());
          AppStorage.setOrCreate('netBearerTick', Date.now());
        }
      });
      nc.on('netLost', () => {
        const stillOnline: boolean = Net.checkInitialOnline();
        Net.lastBearerSig = Net.bearerSignature();
        Net.set(stillOnline);
      });
      nc.register((err: BusinessError) => {
        if (err) {
          console.info('AM_NET register failed: ' + err.message);
        }
      });
      Net.conn = nc;
    } catch (e) {
      console.info('AM_NET start failed: ' + (e as BusinessError).message);
    }
  }

  static stop(): void {
    if (!Net.started) {
      return;
    }
    Net.started = false;
    if (Net.conn !== null) {
      try {
        Net.conn.unregister(() => {});
      } catch (e) {
      }
      Net.conn = null;
    }
  }

  private static set(v: boolean): void {
    const prev: boolean | undefined = AppStorage.get<boolean>('online');
    if (prev === v) {
      return;
    }
    AppStorage.setOrCreate('online', v);
    LinkLog.record('NET', v ? 'online=true' : 'online=false');
    if (v) {
      AppStorage.setOrCreate('listDirty', Date.now());
    }
  }

  static isOnline(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>('online');
    return v === undefined ? true : v;
  }

  /**
   * 仅当全部活跃网络句柄中只存在蜂窝承载（不含 Wi-Fi / 以太网 / VPN）时返回 true。
   * 使用 getAllNetsSync 兼容华为 WLAN+ / LinkTurbo 双网并发（默认网络切到蜂窝但 Wi-Fi 仍在线）。
   */
  static isCellularOnly(): boolean {
    try {
      const bearers: number[] = Net.collectBearers();
      let hasCellular: boolean = false;
      for (let i = 0; i < bearers.length; i++) {
        const b: number = bearers[i];
        if (b === connection.NetBearType.BEARER_WIFI ||
          b === connection.NetBearType.BEARER_ETHERNET ||
          b === connection.NetBearType.BEARER_VPN) {
          return false;
        }
        if (b === connection.NetBearType.BEARER_CELLULAR) {
          hasCellular = true;
        }
      }
      return hasCellular;
    } catch (e) {
      return false;
    }
  }

  /** 可读网络类型标签（供运行环境与诊断日志使用，区分 wifi+cellular 双网并发）。 */
  static describeBearers(): string {
    try {
      const bearers: number[] = Net.collectBearers();
      if (bearers.length === 0) {
        return Net.checkInitialOnline() ? 'other' : 'offline';
      }
      const hasWifi: boolean = bearers.indexOf(connection.NetBearType.BEARER_WIFI) >= 0;
      const hasCell: boolean = bearers.indexOf(connection.NetBearType.BEARER_CELLULAR) >= 0;
      const hasEth: boolean = bearers.indexOf(connection.NetBearType.BEARER_ETHERNET) >= 0;
      const hasVpn: boolean = bearers.indexOf(connection.NetBearType.BEARER_VPN) >= 0;
      if (hasWifi && hasCell) {
        return 'wifi+cellular';
      }
      if (hasWifi) {
        return 'wifi';
      }
      if (hasEth) {
        return 'ethernet';
      }
      if (hasCell) {
        return 'cellular';
      }
      if (hasVpn) {
        return 'vpn';
      }
      return 'other';
    } catch (e) {
      return 'unknown';
    }
  }
}
