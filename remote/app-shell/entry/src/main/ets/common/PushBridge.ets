import { UIAbility } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { pushCommon, pushService } from '@kit.PushKit';
import { Api } from './Api';
import { PushRegisterBody, PushStatusResp, PushTestResp } from './ApiTypes';
import { FEEDBACK_BASE, installId } from './Feedback';
import { LinkLog } from './LinkLog';

/**
 * HarmonyOS Push Kit 客户端桥接：
 * - 统一托管 Push Token 获取、tokenUpdate 监听与前台消息到达刷新；
 * - 将当前 Push Token 与通知偏好上报给已配对桌面端网关，用于退后台/离线后的系统级推送；
 * - 当运行于模拟器或尚未在 AGC 开通推送权益时，优雅降级并输出可读诊断码。
 */
export class PushBridge {
  private static inited: boolean = false;
  private static currentToken: string = '';
  private static boundApi: Api | null = null;
  private static lastSyncSig: string = '';

  static hasToken(): boolean {
    return PushBridge.currentToken !== '';
  }

  static deviceId(): string {
    try {
      return installId();
    } catch (e) {
      return 'dsh-mobile-device';
    }
  }

  private static maskToken(token: string): string {
    if (token.length <= 14) {
      return token;
    }
    return token.slice(0, 6) + '...' + token.slice(token.length - 6);
  }

  private static formatErr(code: number, rawMsg: string): string {
    if (code === 1000900010) {
      return '当前签名未关联 AGC 应用身份，请在 DevEco 与 AGC 完成签名关联 (1000900010)';
    }
    if (code === 1000900012) {
      return 'AGC 项目尚未开通 Push Kit 推送权益 (1000900012)';
    }
    if (code === 1000900014) {
      return '当前设备或模拟器暂不支持 Push Token 申请，请在真机并开通 AGC 后使用 (1000900014)';
    }
    if (code === 1000900011) {
      return '网络不可用，暂无法向华为推送服务申请令牌 (1000900011)';
    }
    if (code === 1000900008) {
      return '连接华为推送服务超时 (1000900008)';
    }
    const clean: string = rawMsg.trim();
    return clean !== '' ? (clean + ' (' + String(code) + ')') : ('Push Kit 暂不可用 (' + String(code) + ')');
  }

  static init(ability: UIAbility): void {
    if (!PushBridge.inited) {
      PushBridge.inited = true;
      AppStorage.setOrCreate('pushState', 'loading');
      AppStorage.setOrCreate('pushTokenPreview', '');
      AppStorage.setOrCreate('pushErrCode', 0);
      AppStorage.setOrCreate('pushErrMsg', '');
      AppStorage.setOrCreate('pushSynced', false);

      try {
        pushService.on('tokenUpdate', ability, (token: string) => {
          const clean: string = token.trim();
          if (clean !== '') {
            PushBridge.currentToken = clean;
            AppStorage.setOrCreate('pushState', 'ready');
            AppStorage.setOrCreate('pushTokenPreview', PushBridge.maskToken(clean));
            AppStorage.setOrCreate('pushErrCode', 0);
            AppStorage.setOrCreate('pushErrMsg', '');
            LinkLog.record('NOTIFY', 'push token updated');
            if (PushBridge.boundApi !== null) {
              void PushBridge.syncToGateway(PushBridge.boundApi, true);
            }
          }
        });
      } catch (e) {
        console.info('DSH_PUSH tokenUpdate listener skipped: ' + JSON.stringify(e));
      }

      try {
        pushService.receiveMessage('DEFAULT', ability, (payload: pushCommon.PushPayload) => {
          LinkLog.record('NOTIFY', 'push_fg_recv type=' + (payload.type ?? 'unknown'));
          AppStorage.setOrCreate('fgProbe', Date.now());
          AppStorage.setOrCreate('listDirty', Date.now());
        });
      } catch (e) {
        console.info('DSH_PUSH receiveMessage skipped: ' + JSON.stringify(e));
      }
    }
    void PushBridge.refreshToken();
  }

  static async refreshToken(): Promise<string> {
    if (PushBridge.currentToken === '') {
      AppStorage.setOrCreate('pushState', 'loading');
    }
    try {
      const token: string = (await pushService.getToken()).trim();
      if (token !== '') {
        PushBridge.currentToken = token;
        AppStorage.setOrCreate('pushState', 'ready');
        AppStorage.setOrCreate('pushTokenPreview', PushBridge.maskToken(token));
        AppStorage.setOrCreate('pushErrCode', 0);
        AppStorage.setOrCreate('pushErrMsg', '');
        LinkLog.record('NOTIFY', 'push token ready');
        if (PushBridge.boundApi !== null) {
          void PushBridge.syncToGateway(PushBridge.boundApi, false);
        }
        return token;
      }
      AppStorage.setOrCreate('pushState', 'unavailable');
      AppStorage.setOrCreate('pushErrMsg', '未获取到有效的 Push Token');
      return '';
    } catch (err) {
      const be: BusinessError = err as BusinessError;
      const code: number = typeof be.code === 'number' ? be.code : -1;
      const msg: string = PushBridge.formatErr(code, be.message ?? '');
      AppStorage.setOrCreate('pushState', 'unavailable');
      AppStorage.setOrCreate('pushErrCode', code);
      AppStorage.setOrCreate('pushErrMsg', msg);
      AppStorage.setOrCreate('pushSynced', false);
      LinkLog.record('NOTIFY', 'push token unavailable code=' + String(code));
      console.info('DSH_PUSH getToken failed code=' + String(code) + ' :: ' + (be.message ?? ''));
      return '';
    }
  }

  static bindApi(api: Api): void {
    PushBridge.boundApi = api;
  }

  static async syncToGateway(api: Api, force: boolean = false): Promise<boolean> {
    PushBridge.boundApi = api;
    if (PushBridge.currentToken === '' || api.currentBase() === '') {
      return false;
    }
    const doneOn: boolean = AppStorage.get<boolean>('notifyDone') !== false;
    const bgOnlyOn: boolean = AppStorage.get<boolean>('notifyBgOnly') !== false;
    const showTitleOn: boolean = AppStorage.get<boolean>('notifyShowTitle') !== false;
    const devId: string = PushBridge.deviceId();
    const sig: string = api.currentBase() + '|' + PushBridge.currentToken + '|' + devId + '|' +
      (doneOn ? '1' : '0') + (bgOnlyOn ? '1' : '0') + (showTitleOn ? '1' : '0');
    if (!force && sig === PushBridge.lastSyncSig) {
      return true;
    }
    const body: PushRegisterBody = {
      deviceId: devId,
      pushToken: PushBridge.currentToken,
      relayUrl: FEEDBACK_BASE,
      enabled: doneOn,
      bgOnly: bgOnlyOn,
      showTitle: showTitleOn
    };
    try {
      const resp = await api.registerPush(body);
      if (resp.ok === true) {
        PushBridge.lastSyncSig = sig;
        AppStorage.setOrCreate('pushSynced', true);
        LinkLog.record('NOTIFY', 'push registered enabled=' + (doneOn ? '1' : '0'));
        return true;
      }
    } catch (e) {
      console.info('DSH_PUSH register failed: ' + (e as Error).message);
    }
    AppStorage.setOrCreate('pushSynced', false);
    return false;
  }

  static async fetchGatewayStatus(api: Api): Promise<PushStatusResp | null> {
    if (api.currentBase() === '') {
      return null;
    }
    try {
      return await api.pushStatus(FEEDBACK_BASE);
    } catch (e) {
      return null;
    }
  }

  static async testPush(api: Api): Promise<PushTestResp> {
    if (PushBridge.currentToken !== '') {
      await PushBridge.syncToGateway(api, true);
    }
    try {
      return await api.testPush(PushBridge.deviceId(), FEEDBACK_BASE);
    } catch (e) {
      return {
        ok: false,
        code: 'rpc_error',
        message: (e as Error).message !== '' ? (e as Error).message : '测试请求发送失败'
      };
    }
  }

  static dispose(): void {
    try {
      pushService.off('tokenUpdate');
    } catch (e) {
      // ignore listener cleanup error
    }
    PushBridge.inited = false;
  }
}
