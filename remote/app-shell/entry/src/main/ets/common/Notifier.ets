import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import { AppCtx } from './AppCtx';
import { LinkLog } from './LinkLog';

/**
 * 系统通知与桌面角标管理（F11 / F12）：
 * - ensure(ctx) 支持显式传入 UIAbilityContext 并允许未授权时重试，直到用户授权或明确拒绝；
 * - noteId(sessionId) 统一计算单会话稳定通知 ID；
 * - done(...) 发布通知时不再硬编码累加 badgeNumber: 1，改为发完后严格同步 Unread 未读数；
 * - cancelSession / cancelAll / syncBadge 确保已读会话自动撤回通知并同步桌面角标。
 */
export class Notifier {
  private static granted: boolean = false;
  private static explicitlyDenied: boolean = false;
  private static slotReady: boolean = false;

  /** 计算单个会话对应的稳定通知 ID。 */
  static noteId(sessionId: string): number {
    if (sessionId === '') {
      return 1000;
    }
    let h: number = 0;
    for (let i = 0; i < sessionId.length; i++) {
      h = (h * 31 + sessionId.charCodeAt(i)) % 100000;
    }
    return 1000 + h;
  }

  /** 申请通知授权并建立横幅提醒通道；未显式拒绝前允许重试。 */
  static async ensure(ctx?: common.UIAbilityContext): Promise<void> {
    if (Notifier.granted && Notifier.slotReady) {
      return;
    }
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (enabled) {
        Notifier.granted = true;
        Notifier.explicitlyDenied = false;
      } else if (!Notifier.explicitlyDenied) {
        try {
          const targetCtx: common.UIAbilityContext | null = ctx !== undefined ? ctx : AppCtx.abilityOrNull();
          if (targetCtx !== null) {
            await notificationManager.requestEnableNotification(targetCtx);
          } else {
            await notificationManager.requestEnableNotification();
          }
          Notifier.granted = await notificationManager.isNotificationEnabled();
        } catch (reqErr) {
          const be: BusinessError = reqErr as BusinessError;
          // 1600004: 用户显式拒绝通知弹窗，停止反复弹窗打扰
          if (be.code === 1600004) {
            Notifier.explicitlyDenied = true;
          }
          console.info('DSH_NOTIFY requestEnable failed code=' + String(be.code) + ' :: ' + (be.message ?? ''));
        }
      }
    } catch (e) {
      console.info('DSH_NOTIFY enable check failed :: ' + (e as BusinessError).message);
    }
    if (!Notifier.slotReady) {
      try {
        await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
        Notifier.slotReady = true;
      } catch (e) {
        console.info('DSH_NOTIFY slot failed :: ' + (e as BusinessError).message);
      }
    }
  }

  /**
   * 发一条通知，点它回到应用；带上 sessionId 时直接打开那个会话。
   * 兼容新签名 done(title, body, sessionId) 与旧签名 done(title, body, numericId, sessionId)。
   */
  static async done(
    title: string,
    body: string,
    sessionIdOrId: string | number = '',
    legacySessionId: string = ''
  ): Promise<void> {
    let id: number = 1000;
    let sessionId: string = '';
    if (typeof sessionIdOrId === 'number') {
      id = sessionIdOrId;
      sessionId = legacySessionId;
    } else {
      sessionId = sessionIdOrId;
      id = Notifier.noteId(sessionId);
    }

    let agent: object | undefined = undefined;
    try {
      const bName: string = AppCtx.bundleName();
      const aName: string = AppCtx.abilityName();
      if (bName !== '') {
        const info: wantAgent.WantAgentInfo = {
          wants: [
            {
              bundleName: bName,
              abilityName: aName,
              parameters: { sessionId: sessionId }
            }
          ],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: id % 100000,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        agent = await wantAgent.getWantAgent(info);
      }
    } catch (e) {
      console.info('DSH_NOTIFY wantAgent failed :: ' + (e as BusinessError).message);
    }

    // 不在 publish 中写死 badgeNumber: 1，避免桌面角标无上限累加
    const req: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: body
        }
      }
    };
    if (agent !== undefined) {
      req.wantAgent = agent;
    }
    try {
      await notificationManager.publish(req);
      LinkLog.record('NOTIFY', 'published id=' + String(id) + ' sid=' + (sessionId !== '' ? sessionId : '-'));
      console.info('DSH_NOTIFY published id=' + String(id) + ' sid=' + sessionId);
    } catch (e) {
      LinkLog.record('NOTIFY', 'publish_fail id=' + String(id) + ' err=' + ((e as BusinessError).message ?? 'unknown'));
      console.info('DSH_NOTIFY publish failed :: ' + (e as BusinessError).message);
    }
    const totalBadge: number | undefined = AppStorage.get<number>('unreadTotalCount');
    const badgeCount: number | undefined = totalBadge !== undefined ? totalBadge : AppStorage.get<number>('unreadCount');
    if (badgeCount !== undefined) {
      await Notifier.syncBadge(badgeCount);
    }
  }

  /** 撤回指定会话的已发通知。 */
  static async cancelSession(sessionId: string): Promise<void> {
    if (sessionId === '') {
      return;
    }
    try {
      await notificationManager.cancel(Notifier.noteId(sessionId));
    } catch (e) {
      // 通知不存在或已被用户划掉时静默忽略
    }
  }

  /** 撤回本应用全部通知。 */
  static async cancelAll(): Promise<void> {
    try {
      await notificationManager.cancelAll();
    } catch (e) {
      console.info('DSH_NOTIFY cancelAll failed :: ' + (e as BusinessError).message);
    }
  }

  /** 将系统桌面应用角标严格同步为当前未读会话数。 */
  static async syncBadge(n: number): Promise<void> {
    const safe: number = n > 0 ? Math.floor(n) : 0;
    try {
      await notificationManager.setBadgeNumber(safe);
    } catch (e) {
      console.info('DSH_NOTIFY setBadgeNumber failed :: ' + (e as BusinessError).message);
    }
  }
}
