import { UIAbility } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { pushCommon, pushService } from '@kit.PushKit';
import { Api } from './Api';
import { PushRegisterBody, PushStatusResp, PushTestResp } from './ApiTypes';
import { FEEDBACK_BASE, installId } from './Feedback';
import { LinkLog } from './LinkLog';
import { Secret } from './Secret';

interface BindResp {
  ok?: boolean;
  code?: string;
  relaySecret?: string;
  rotated?: boolean;
}

/**
 * HarmonyOS Push Kit 客户端桥接：
 * - 合规门槛：仅在用户明确同意《隐私政策》后激活 Push Kit 监听与 getToken() 申请；
 * - 防刷绑定：拿到 Push Token 后向云端中继 `/v1/push/bind` 申请本机专属 `relaySecret`，存入 Asset Store Kit，
 *   再通过端到端加密通道传给用户配对的桌面端网关；
 * - 若当前为未关联 AGC 的签名或模拟器环境，优雅降级并保留可读诊断提示。
 */
export class PushBridge {
  private static abilityRef: UIAbility | null = null;
  private static privacyAllowed: boolean = false;
  private static listenersAttached: boolean = false;
  private static currentToken: string = '';
  private static cachedRelayToken: string = '';
  private static cachedRelaySecret: string = '';
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

  private static tokenAlias(token: string): string {
    let h: number = 2166136261;
    for (let i = 0; i < token.length; i++) {
      h ^= token.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return 'push_relay_' + (h >>> 0).toString(16);
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

  /** 仅登记 Ability 引用与界面初始占位，在隐私弹窗同意前绝不触碰 Push Kit SDK。 */
  static attachAbility(ability: UIAbility): void {
    PushBridge.abilityRef = ability;
    AppStorage.setOrCreate('pushState', 'idle');
    AppStorage.setOrCreate('pushBindState', 'idle');
    AppStorage.setOrCreate('pushTokenPreview', '');
    AppStorage.setOrCreate('pushErrCode', 0);
    AppStorage.setOrCreate('pushErrMsg', '');
    AppStorage.setOrCreate('pushSynced', false);
  }

  /** 在用户确认同意隐私政策后激活 Push Kit 监听并申请 Push Token。 */
  static activateAfterPrivacy(): void {
    const firstActivation: boolean = !PushBridge.privacyAllowed;
    PushBridge.privacyAllowed = true;
    if (!PushBridge.listenersAttached && PushBridge.abilityRef !== null) {
      PushBridge.listenersAttached = true;
      const ability: UIAbility = PushBridge.abilityRef;
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
    if (firstActivation || PushBridge.currentToken === '') {
      void PushBridge.refreshToken();
    }
  }

  static async refreshToken(): Promise<string> {
    if (!PushBridge.privacyAllowed) {
      return '';
    }
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

  private static async ensureRelaySecret(token: string, rotate: boolean = false): Promise<string> {
    if (token === '') {
      return '';
    }
    const alias: string = PushBridge.tokenAlias(token);
    if (!rotate) {
      if (PushBridge.cachedRelayToken === token && PushBridge.cachedRelaySecret.length >= 32) {
        AppStorage.setOrCreate('pushBindState', 'bound');
        return PushBridge.cachedRelaySecret;
      }
      const saved: string = Secret.loadFor(alias);
      if (saved.length >= 32) {
        PushBridge.cachedRelayToken = token;
        PushBridge.cachedRelaySecret = saved;
        AppStorage.setOrCreate('pushBindState', 'bound');
        return saved;
      }
    }

    const req = http.createHttp();
    try {
      const res: http.HttpResponse = await req.request(FEEDBACK_BASE + '/v1/push/bind', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'X-Install': PushBridge.deviceId()
        },
        extraData: JSON.stringify({
          installId: PushBridge.deviceId(),
          pushToken: token,
          rotate: rotate
        }),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 8000,
        readTimeout: 8000
      });
      if (res.responseCode === 404) {
        AppStorage.setOrCreate('pushBindState', 'relay_pending_deploy');
        LinkLog.record('NOTIFY', 'push bind 404 pending worker deploy');
        return '';
      }
      const raw: string = typeof res.result === 'string' ? res.result : JSON.stringify(res.result);
      const parsed: BindResp = JSON.parse(raw) as BindResp;
      if (res.responseCode >= 200 && res.responseCode < 300 && parsed.ok === true &&
        typeof parsed.relaySecret === 'string' && parsed.relaySecret.length >= 32) {
        const secret: string = parsed.relaySecret.trim();
        PushBridge.cachedRelayToken = token;
        PushBridge.cachedRelaySecret = secret;
        Secret.saveFor(alias, secret);
        AppStorage.setOrCreate('pushBindState', 'bound');
        LinkLog.record('NOTIFY', 'push bind ok rotated=' + (rotate ? '1' : '0'));
        return secret;
      }
      AppStorage.setOrCreate('pushBindState', 'error');
      LinkLog.record('NOTIFY', 'push bind fail status=' + String(res.responseCode) + ' code=' + (parsed.code ?? 'err'));
    } catch (e) {
      AppStorage.setOrCreate('pushBindState', 'error');
      LinkLog.record('NOTIFY', 'push bind network error');
    } finally {
      req.destroy();
    }
    return '';
  }

  static bindApi(api: Api): void {
    PushBridge.boundApi = api;
  }

  static async syncToGateway(api: Api, force: boolean = false): Promise<boolean> {
    PushBridge.boundApi = api;
    if (!PushBridge.privacyAllowed || PushBridge.currentToken === '' || api.currentBase() === '') {
      return false;
    }
    const relaySecret: string = await PushBridge.ensureRelaySecret(PushBridge.currentToken, false);
    const doneOn: boolean = AppStorage.get<boolean>('notifyDone') !== false;
    const bgOnlyOn: boolean = AppStorage.get<boolean>('notifyBgOnly') !== false;
    const showTitleOn: boolean = AppStorage.get<boolean>('notifyShowTitle') !== false;
    const devId: string = PushBridge.deviceId();
    const secretTag: string = relaySecret.length >= 12 ? relaySecret.slice(0, 12) : '-';
    const sig: string = api.currentBase() + '|' + PushBridge.currentToken + '|' + devId + '|' + secretTag + '|' +
      (doneOn ? '1' : '0') + (bgOnlyOn ? '1' : '0') + (showTitleOn ? '1' : '0');
    if (!force && sig === PushBridge.lastSyncSig) {
      return true;
    }
    const body: PushRegisterBody = {
      deviceId: devId,
      pushToken: PushBridge.currentToken,
      relayUrl: FEEDBACK_BASE,
      relaySecret: relaySecret !== '' ? relaySecret : undefined,
      enabled: doneOn,
      bgOnly: bgOnlyOn,
      showTitle: showTitleOn
    };
    try {
      const resp = await api.registerPush(body);
      if (resp.ok === true) {
        PushBridge.lastSyncSig = sig;
        AppStorage.setOrCreate('pushSynced', true);
        LinkLog.record('NOTIFY', 'push registered enabled=' + (doneOn ? '1' : '0') + ' bound=' + (relaySecret !== '' ? '1' : '0'));
        return true;
      }
    } catch (e) {
      console.info('DSH_PUSH register failed: ' + (e as Error).message);
    }
    AppStorage.setOrCreate('pushSynced', false);
    return false;
  }

  static async rotateBinding(api: Api): Promise<boolean> {
    if (!PushBridge.privacyAllowed || PushBridge.currentToken === '') {
      return false;
    }
    const nextSecret: string = await PushBridge.ensureRelaySecret(PushBridge.currentToken, true);
    if (nextSecret === '') {
      return false;
    }
    return await PushBridge.syncToGateway(api, true);
  }

  static async unregisterGateway(api: Api): Promise<void> {
    PushBridge.lastSyncSig = '';
    AppStorage.setOrCreate('pushSynced', false);
    if (api.currentBase() === '') {
      return;
    }
    try {
      await api.unregisterPush(PushBridge.deviceId());
    } catch (e) {
      // ignore offline unregister error
    }
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
    if (PushBridge.privacyAllowed && PushBridge.currentToken !== '') {
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
    if (PushBridge.listenersAttached) {
      try {
        pushService.off('tokenUpdate');
      } catch (e) {
        // ignore listener cleanup error
      }
    }
    PushBridge.listenersAttached = false;
    PushBridge.privacyAllowed = false;
    PushBridge.abilityRef = null;
  }
}
