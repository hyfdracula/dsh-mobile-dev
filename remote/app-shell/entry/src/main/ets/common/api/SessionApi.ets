import { ApiTransport } from '../ApiTransport';
import { FilePart } from '../Files';
import { ImagePart } from '../Images';
import {
  AnswerBody,
  ArchiveResp,
  AskAnswer,
  BackendInfo,
  BackendsResp,
  BackendToggleBody,
  BackendToggleResp,
  CommandExecBody,
  CommandExecResp,
  CommandsResp,
  CreateBody,
  CreateResp,
  ExportSignBody,
  ExportSignRawResp,
  ExportSignResp,
  ForkBody,
  ForkResp,
  ImageRef,
  MessagesResp,
  MessagesResult,
  OutboxBody,
  OutboxResp,
  PinBody,
  PinResp,
  PlanBody,
  PlanResp,
  PlanState,
  PreviewRow,
  PreviewsResp,
  QueueOrderBody,
  QueueOrderResp,
  QueueTextBody,
  RenameBody,
  SendBody,
  SessionRow,
  SessionsResp,
  SignBody,
  SignItem,
  SignResp,
  SlashCommandRow,
  StopResp,
  StreamUpdate
} from '../ApiTypes';

/**
 * 会话生命周期、消息流（含精简模式与 SSE 实时推送）、待发送队列、附件短签名、
 * 计划模式、斜杠指令与日志导出签名（F09 / R4 / G4）。
 */
export class SessionApi {
  /** 单飞去重：避免启动与前台恢复时 ShellPage 与 SessionList 同时发两条完全相同的 /api/sessions。 */
  private static inflightSessions: Map<string, Promise<SessionRow[]>> = new Map<string, Promise<SessionRow[]>>();

  static async sessions(t: ApiTransport, backend: string = ''): Promise<SessionRow[]> {
    const q: string = backend !== '' && backend !== 'all'
      ? ('/api/sessions?backend=' + encodeURIComponent(backend))
      : '/api/sessions';
    const key: string = t.currentBase() + '|' + q;
    const existing: Promise<SessionRow[]> | undefined = SessionApi.inflightSessions.get(key);
    if (existing !== undefined) {
      return await existing;
    }
    const p: Promise<SessionRow[]> = t.call<SessionsResp>(q, 'GET').then((r: SessionsResp) => r.sessions ?? []);
    SessionApi.inflightSessions.set(key, p);
    try {
      return await p;
    } finally {
      if (SessionApi.inflightSessions.get(key) === p) {
        SessionApi.inflightSessions.delete(key);
      }
    }
  }

  static async backends(t: ApiTransport, refresh: boolean = false): Promise<BackendInfo[]> {
    const q: string = refresh ? '/api/backends?refresh=1' : '/api/backends';
    const r: BackendsResp = await t.call<BackendsResp>(q, 'GET');
    return r.backends ?? [];
  }

  static async toggleBackend(t: ApiTransport, id: string, enabled: boolean): Promise<BackendInfo | null> {
    const body: BackendToggleBody = { enabled: enabled };
    const r: BackendToggleResp = await t.call<BackendToggleResp>(
      '/api/backends/' + encodeURIComponent(id) + '/toggle',
      'POST',
      JSON.stringify(body)
    );
    return r.backend !== undefined ? r.backend : null;
  }

  static async previews(t: ApiTransport, ids: string[]): Promise<PreviewRow[]> {
    if (ids.length === 0) {
      return [];
    }
    const q: string = '/api/sessions/previews?ids=' + encodeURIComponent(ids.join(','));
    const r: PreviewsResp = await t.call<PreviewsResp>(q, 'GET');
    return r.previews ?? [];
  }

  private static toMessagesResult(r: MessagesResp): MessagesResult {
    return {
      total: r.total,
      messages: r.messages ?? [],
      stats: r.stats,
      context: r.context,
      running: r.running,
      firstSeq: r.firstSeq,
      lastTurn: r.lastTurn,
      lastErr: r.lastErr,
      queue: r.queue,
      questions: r.questions,
      plan: r.plan,
      tasks: r.tasks
    };
  }

  static async messages(t: ApiTransport, id: string, limit: number, compact: boolean = false): Promise<MessagesResult> {
    const cq: string = compact ? '&compact=1' : '';
    const r: MessagesResp = await t.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?limit=' + String(limit) + cq, 'GET');
    return SessionApi.toMessagesResult(r);
  }

  static async messagesSince(t: ApiTransport, id: string, since: number, compact: boolean = false): Promise<MessagesResult> {
    const cq: string = compact ? '&compact=1' : '';
    const r: MessagesResp = await t.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?since=' + String(since) + cq, 'GET');
    return SessionApi.toMessagesResult(r);
  }

  static async messagesBefore(t: ApiTransport, id: string, before: number, limit: number = 60,
    compact: boolean = false): Promise<MessagesResult> {
    const cq: string = compact ? '&compact=1' : '';
    const r: MessagesResp = await t.call<MessagesResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/messages?before=' + String(before) + '&limit=' + String(limit) + cq,
      'GET');
    return SessionApi.toMessagesResult(r);
  }

  /**
   * 订阅会话增量 SSE 流（GET /api/sessions/:id/stream?since=...）。
   * 旧宿主 404 或中途断流时回调一次 onFallback 供上层无缝回退到轮询。
   */
  static streamSession(
    t: ApiTransport,
    id: string,
    since: number,
    onUpdate: (update: StreamUpdate) => void,
    onFallback: (reason: string) => void,
    compact: boolean = false
  ): () => void {
    const cq: string = compact ? '&compact=1' : '';
    const path: string = '/api/sessions/' + encodeURIComponent(id) + '/stream?since=' + String(since) + cq;
    return t.openSseStream(
      path,
      (evName: string, data: string): void => {
        if (data === '') {
          return;
        }
        try {
          const parsed: StreamUpdate = JSON.parse(data) as StreamUpdate;
          if (parsed.messages === undefined) {
            parsed.messages = [];
          }
          if (parsed.type === undefined || parsed.type === '') {
            parsed.type = evName;
          }
          onUpdate(parsed);
        } catch (e) {
          console.info('DSH_SSE parse skipped: ' + JSON.stringify(e));
        }
      },
      (reason: string): void => {
        onFallback(reason);
      }
    );
  }

  static async send(t: ApiTransport, id: string, text: string, mode: string = '', idem: string = ''): Promise<void> {
    const body: SendBody = { text: text };
    if (mode === 'steer' || mode === 'queue') {
      body.mode = mode;
    }
    await t.call<object>('/api/sessions/' + encodeURIComponent(id) + '/send', 'POST',
      JSON.stringify(body), idem);
  }

  static async sendOutbox(t: ApiTransport, id: string, text: string, images: ImagePart[], files: FilePart[],
    mode: string = '', idem: string = ''): Promise<number> {
    const body: OutboxBody = { text: text, images: images, files: files };
    if (mode === 'steer' || mode === 'queue') {
      body.mode = mode;
    }
    const r: OutboxResp = await t.call<OutboxResp>('/api/sessions/' + encodeURIComponent(id) + '/outbox', 'POST',
      JSON.stringify(body), idem);
    return r.parts === undefined ? 0 : r.parts;
  }

  static async stop(t: ApiTransport, id: string): Promise<boolean> {
    const r: StopResp = await t.call<StopResp>('/api/sessions/' + encodeURIComponent(id) + '/stop', 'POST', '{}');
    return r.accepted === true;
  }

  static async createSession(t: ApiTransport, cwd: string, backend: string = 'dsh'): Promise<string> {
    const body: CreateBody = { cwd: cwd };
    if (backend !== '' && backend !== 'dsh') {
      body.backend = backend;
    }
    const r: CreateResp = await t.call<CreateResp>('/api/sessions', 'POST', JSON.stringify(body));
    return r.sessionId === undefined ? '' : r.sessionId;
  }

  static async rename(t: ApiTransport, id: string, title: string): Promise<void> {
    const body: RenameBody = { title: title };
    await t.call<object>('/api/sessions/' + encodeURIComponent(id), 'PATCH', JSON.stringify(body));
  }

  static async archive(t: ApiTransport, id: string): Promise<boolean> {
    const r: ArchiveResp = await t.call<ArchiveResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/archive', 'POST');
    return r.ok === true;
  }

  static async unarchive(t: ApiTransport, id: string): Promise<boolean> {
    const r: ArchiveResp = await t.call<ArchiveResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/unarchive', 'POST');
    return r.ok === true;
  }

  static async pin(t: ApiTransport, id: string, pinned: boolean): Promise<boolean> {
    const body: PinBody = { pinned: pinned };
    const r: PinResp = await t.call<PinResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/pin', 'POST', JSON.stringify(body));
    return r.ok === true;
  }

  static async fork(t: ApiTransport, id: string, atSeq: number = -1): Promise<string> {
    const body: ForkBody = {};
    if (atSeq >= 0) {
      body.atSeq = atSeq;
    }
    const r: ForkResp = await t.call<ForkResp>('/api/sessions/' + encodeURIComponent(id) + '/fork', 'POST',
      JSON.stringify(body));
    return r.sessionId === undefined ? '' : r.sessionId;
  }

  static async queueDrop(t: ApiTransport, id: string, itemId: string): Promise<void> {
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/drop',
      'POST', '{}');
  }

  static async queueReorder(t: ApiTransport, id: string, ids: string[]): Promise<void> {
    const body: QueueOrderBody = { ids: ids };
    await t.call<QueueOrderResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/reorder', 'POST', JSON.stringify(body));
  }

  static async queueEdit(t: ApiTransport, id: string, itemId: string, text: string): Promise<void> {
    const body: QueueTextBody = { text: text };
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/edit',
      'POST', JSON.stringify(body));
  }

  static async queueFire(t: ApiTransport, id: string, itemId: string): Promise<void> {
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/queue/' + encodeURIComponent(itemId) + '/fire',
      'POST', '{}');
  }

  static async answerQuestions(t: ApiTransport, id: string, callId: string, answers: AskAnswer[]): Promise<void> {
    const body: AnswerBody = { callId: callId, answers: answers };
    await t.call<object>(
      '/api/sessions/' + encodeURIComponent(id) + '/questions/answer',
      'POST', JSON.stringify(body));
  }

  static async signAttachments(t: ApiTransport, ids: string[]): Promise<void> {
    const need: string[] = [];
    const nowSec: number = Math.floor(Date.now() / 1000);
    for (let i = 0; i < ids.length && need.length < 64; i++) {
      const id: string = ids[i];
      const exp: number = t.attExp.get(id) ?? 0;
      if (!t.attSig.has(id) || exp <= nowSec + 60) {
        need.push(id);
      }
    }
    if (need.length === 0) {
      return;
    }
    try {
      const body: SignBody = { ids: need };
      const r: SignResp = await t.call<SignResp>('/api/attachments/sign', 'POST', JSON.stringify(body));
      const items: SignItem[] = r.items === undefined ? [] : r.items;
      for (let i = 0; i < items.length; i++) {
        t.attSig.set(items[i].id, 'e=' + items[i].e + '&sig=' + items[i].sig);
        const e: number = Number(items[i].e);
        t.attExp.set(items[i].id, Number.isFinite(e) ? e : 0);
      }
      if (items.length > 0) {
        AppStorage.setOrCreate('attSigRev', Date.now());
      }
    } catch (e) {
      console.info('DSH_ATT_SIGN skipped :: ' + (e as Error).message);
    }
  }

  static attachmentUrl(t: ApiTransport, img: ImageRef): string {
    const mt: string = img.mediaType !== '' ? img.mediaType : 'image/png';
    const sig: string | undefined = t.attSig.get(img.id);
    if (sig !== undefined && (t.attExp.get(img.id) ?? 0) > Math.floor(Date.now() / 1000) + 30) {
      return t.currentBase() + '/api/attachments/' + img.id + '?' + sig + '&m=' + encodeURIComponent(mt);
    }
    return '';
  }

  /** 读取当前会话的计划模式状态（F09）。 */
  static async plan(t: ApiTransport, id: string): Promise<PlanState> {
    const r: PlanResp = await t.call<PlanResp>('/api/sessions/' + encodeURIComponent(id) + '/plan', 'GET');
    return { active: r.active === true, pending: r.pending === true };
  }

  /** 切换当前会话的计划模式（F09）。 */
  static async setPlan(t: ApiTransport, id: string, active: boolean): Promise<PlanState> {
    const body: PlanBody = { active: active };
    const r: PlanResp = await t.call<PlanResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/plan', 'POST', JSON.stringify(body));
    return { active: r.active === true, pending: r.pending === true };
  }

  /** 获取当前会话可用的斜杠指令列表（F09）。 */
  static async commands(t: ApiTransport, id: string): Promise<SlashCommandRow[]> {
    const r: CommandsResp = await t.call<CommandsResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/commands', 'GET');
    return r.commands !== undefined ? r.commands : [];
  }

  /** 在电脑端执行一条斜杠指令（如 /compact、/feedback、/restart）（F09）。 */
  static async execCommand(t: ApiTransport, id: string, line: string): Promise<CommandExecResp> {
    const body: CommandExecBody = { line: line };
    const r: CommandExecResp = await t.call<CommandExecResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/commands/execute',
      'POST',
      JSON.stringify(body),
      undefined,
      undefined,
      60000
    );
    return {
      ok: r.ok,
      commandId: r.commandId !== undefined ? r.commandId : '',
      kind: r.kind !== undefined ? r.kind : 'info',
      text: r.text !== undefined ? r.text : ''
    };
  }

  /** 申请会话导出短签名并拼装完整下载 URL（markdown | zip）（F09）。 */
  static async exportSessionUrl(t: ApiTransport, id: string, format: string): Promise<ExportSignResp> {
    const fmt: string = format.trim().toLowerCase() === 'zip' ? 'zip' : 'markdown';
    const body: ExportSignBody = { format: fmt };
    const r: ExportSignRawResp = await t.call<ExportSignRawResp>(
      '/api/sessions/' + encodeURIComponent(id) + '/export/sign', 'POST', JSON.stringify(body));
    const e: string = r.e !== undefined ? r.e : '';
    const sig: string = r.sig !== undefined ? r.sig : '';
    const filename: string = r.filename !== undefined ? r.filename : ('dsh-session.' + (fmt === 'zip' ? 'zip' : 'md'));
    const base: string = t.currentBase();
    const url: string = base !== '' && e !== '' && sig !== ''
      ? base + '/api/sessions/' + encodeURIComponent(id) + '/export?format=' + encodeURIComponent(fmt) +
        '&e=' + encodeURIComponent(e) + '&sig=' + encodeURIComponent(sig)
      : '';
    return {
      ok: r.ok === true && url !== '',
      url: url,
      filename: filename,
      e: e,
      sig: sig
    };
  }
}
