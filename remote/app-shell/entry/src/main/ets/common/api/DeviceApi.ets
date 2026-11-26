import { ApiTransport } from '../ApiTransport';
import {
  AnswerModeBody,
  AnswerModeResp,
  ApiInfo,
  InfoResp,
  PresenceBody,
  PresenceResp,
  PushRegisterBody,
  PushRegisterResp,
  PushStatusResp,
  PushTestBody,
  PushTestResp,
  StageCallback,
  WebConsoleGrantRawResp,
  WebConsoleGrantResp
} from '../ApiTypes';

/**
 * 设备探活、在线心跳、提问回答归属与网页控制台免密授权（L5 / L6）。
 */
export class DeviceApi {
  static async info(t: ApiTransport, stageCb?: StageCallback): Promise<ApiInfo> {
    const r: InfoResp = await t.call<InfoResp>('/api/info', 'GET', undefined, undefined, stageCb);
    t.seedLan(r.addresses, r.port);
    const hostId: string = r.hostId !== undefined ? r.hostId : '';
    const e2eePub: string = r.e2eePub !== undefined ? r.e2eePub : '';
    if (r.e2ee !== false && hostId !== '' && e2eePub !== '') {
      if (t.canAcceptE2eeMeta(hostId, e2eePub)) {
        t.configureE2ee(hostId, e2eePub);
      } else {
        AppStorage.setOrCreate('e2eeKeyMismatch', hostId);
      }
    }
    return {
      ok: r.ok,
      version: r.version,
      host: r.host,
      port: r.port,
      hostId: hostId !== '' ? hostId : undefined,
      e2ee: r.e2ee,
      e2eePub: e2eePub !== '' ? e2eePub : undefined,
      plan: r.plan,
      commands: r.commands,
      webConsole: r.webConsole
    };
  }

  static async presence(t: ApiTransport, online: boolean, sessionId: string = ''): Promise<void> {
    const q: string = sessionId === '' ? '' : '?sessionId=' + encodeURIComponent(sessionId);
    try {
      const body: PresenceBody = sessionId !== '' ? { online: online, sessionId: sessionId } : { online: online };
      await t.call<PresenceResp>('/api/presence' + q, 'POST', JSON.stringify(body));
    } catch (e) {
      console.info('DSH_PRESENCE fail ' + (e as Error).message);
    }
  }

  static async registerPush(t: ApiTransport, body: PushRegisterBody): Promise<PushRegisterResp> {
    return await t.call<PushRegisterResp>('/api/push/register', 'POST', JSON.stringify(body));
  }

  static async unregisterPush(t: ApiTransport, deviceId: string): Promise<PushRegisterResp> {
    return await t.call<PushRegisterResp>(
      '/api/push/unregister',
      'POST',
      JSON.stringify({ deviceId: deviceId })
    );
  }

  static async pushStatus(t: ApiTransport, relayUrl: string = ''): Promise<PushStatusResp> {
    const q: string = relayUrl !== '' ? ('?relayUrl=' + encodeURIComponent(relayUrl)) : '';
    return await t.call<PushStatusResp>('/api/push/status' + q, 'GET');
  }

  static async testPush(t: ApiTransport, deviceId: string = '', relayUrl: string = ''): Promise<PushTestResp> {
    const body: PushTestBody = { deviceId: deviceId, relayUrl: relayUrl };
    return await t.call<PushTestResp>('/api/push/test', 'POST', JSON.stringify(body));
  }

  static async answerMode(t: ApiTransport): Promise<string> {
    const r: AnswerModeResp = await t.call<AnswerModeResp>('/api/answer-mode', 'GET');
    return r.mode !== undefined ? r.mode : 'phone';
  }

  static async setAnswerMode(t: ApiTransport, mode: string): Promise<string> {
    const body: AnswerModeBody = { mode: mode };
    const r: AnswerModeResp = await t.call<AnswerModeResp>('/api/answer-mode', 'POST', JSON.stringify(body));
    return r.mode !== undefined ? r.mode : mode;
  }

  /** 向电脑端申请一次性免密网页控制台授权票据，并拼出完整进入地址（L5）。 */
  static async webConsoleGrant(t: ApiTransport): Promise<WebConsoleGrantResp> {
    const r: WebConsoleGrantRawResp = await t.call<WebConsoleGrantRawResp>('/api/web-console/grant', 'POST', '{}');
    const grant: string = r.grant !== undefined ? r.grant : '';
    const path: string = r.path !== undefined && r.path !== ''
      ? r.path
      : (grant !== '' ? '/api/web-console/enter?g=' + encodeURIComponent(grant) : '');
    const base: string = t.currentBase();
    const enterUrl: string = path !== '' && base !== '' ? base + path : '';
    return {
      ok: r.ok === true && enterUrl !== '',
      grant: grant,
      path: path,
      enterUrl: enterUrl,
      expiresIn: r.expiresIn !== undefined ? r.expiresIn : 60
    };
  }
}
