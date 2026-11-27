import { inputMethod } from '@kit.IMEKit';
import { HdsNavDestination, HdsNavigationTitleBarOptions, hdsEffect } from '@kit.UIDesignKit';
import window from '@ohos.window';
import { KeyboardAvoidMode as KbMode } from '@ohos.arkui.UIContext';
import {
  AgentRef,
  Api,
  AskAnswer,
  AskState,
  BackendCapabilities,
  BackendInfo,
  CatalogGroup,
  CommandExecResp,
  ContextUsage,
  GoalView,
  Message,
  MessagesResult,
  PendingAsk,
  PermRow,
  PermsResp,
  PlanState,
  QueuedItem,
  SessionRow,
  SessionStats,
  SlashCommandRow,
  StreamUpdate,
  TurnErr,
  backendIdOfSession,
  backendLabelOf,
  defaultBackendCapabilities
} from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { ChatCache, ChatSnapshot } from '../common/Cache';
import { buildTransparentHdsTitle } from '../common/Chrome';
import { Drafts } from '../common/Drafts';
import { isFeedbackEnabled } from '../common/Feedback';
import { FilePart } from '../common/Files';
import { dayLabel, sameDay } from '../common/Format';
import { Haptics } from '../common/Haptics';
import { ImagePart, pickImages } from '../common/Images';
import { Machines } from '../common/Machines';
import { Marks } from '../common/Marks';
import { Mat } from '../common/Mat';
import { MdBlock, parseMd } from '../common/Md';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Net } from '../common/Net';
import { Outbox, StashItem } from '../common/Outbox';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { Unread } from '../common/Unread';
import { AttachMenu } from './AttachMenu';
import { ExtrasPanel } from './ExtrasPanel';
import { PendingBoard, PendRow } from './PendingBoard';
import { PendingImages } from './PendingImages';
import { TypingBubble } from './TypingBubble';
import { WebConsolePage } from './WebConsolePage';
import { AiFlowGlow } from './chat/AiFlowGlow';
import { AskQuestionCard } from './chat/AskQuestionCard';
import { BigEditorOverlay } from './chat/BigEditorOverlay';
import { ChatBubbleItem } from './chat/ChatBubbleItem';
import {
  ChatEmptyWelcome,
  ChatTopBackdrop,
  ComposerSendCluster,
  ContextPill,
  HeaderCirclePill,
  HeaderTitleCapsule,
  PlanModeBanner,
  ScrollBottomFab,
  SubagentStrip
} from './chat/ChatComposerWidgets';
import { ChatErrorCard, OutboxRescueCard } from './chat/ChatErrorCard';
import {
  archiveSessionNow,
  buildMsgForEachKey,
  buildPendRows,
  captureCameraParts,
  collectImageIds,
  dispatchOnlineSend,
  EMPTY_GOAL,
  EMPTY_STATS,
  exportSessionByFormat,
  fetchResolvedModelState,
  forkSessionNow,
  formatLinkBadge,
  mergeMessageList,
  modelLabelOf,
  pickLocalFileParts,
  reconcileOutboxItems,
  ReorderOutcome,
  reorderPendList,
  replayOutboxItems,
  ResolvedModelState,
  resolveKeyboardHeightVp,
  resolveLinkState,
  saveSessionMarkdown,
  stashOfflineSend,
  toggleSessionPinState,
  toStashImages
} from './chat/ChatHelpers';
import { ChatSearchOverlay } from './chat/ChatSearchOverlay';
import { ChatStatsSheet } from './chat/ChatStatsSheet';
import { ChatMenuPopup, RenameSessionSheet } from './chat/ChatTopMenu';
import { FeedbackQuickSheet } from './chat/FeedbackQuickSheet';
import { GoalSheet } from './chat/GoalSheet';
import { MessageSelectSheet } from './chat/MessageSelectSheet';
import { ModelPickerSheet } from './chat/ModelPickerSheet';
import { PermPickerSheet } from './chat/PermPickerSheet';

@Component
export struct ChatPage {
  api: Api = new Api('', '');
  param: ChatParam = { id: '', title: '' };
  @Consume('stack') stack: NavPathStack;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('enterSend') enterSend: boolean = true;
  @StorageLink('compactHistory') @Watch('onCompactHistoryChange') compactHistory: boolean = false;
  @StorageLink('textScale') textScale: number = 1;
  @StorageLink('online') @Watch('onOnline') online: boolean = true;
  @StorageLink('bigImg') bigImg: string = '';
  @StorageLink('bigImgGeoId') bigImgGeoId: string = '';
  @StorageLink('appFg') @Watch('onAppFgChange') appFg: boolean = true;
  @StorageLink('linkMode') linkMode: string = 'lan';
  @StorageLink('linkEncrypted') linkEncrypted: boolean = false;
  @StorageLink('wideScreen') wideScreen: boolean = false;

  @State private kbH: number = 0;
  private kwWin: window.Window | null = null;
  private kwCb: ((h: number) => void) | null = null;
  private kwRep: number = 0;
  private kwAvoid: number = 0;
  private kwAvoidSeen: boolean = false;
  private kwAvoidCb: ((data: window.AvoidAreaOptions) => void) | null = null;
  private winH: number = 0;

  @State private msgs: Message[] = [];
  @State private total: number = 0;
  @State private loading: boolean = true;
  @State private hasMore: boolean = false;
  @State private loadingMore: boolean = false;
  @State private cached: boolean = false;
  private initialMaxSeq: number = Number.MAX_SAFE_INTEGER;
  private seenSeqs: Set<number> = new Set<number>();
  private mdCache: Map<string, MdBlock[]> = new Map<string, MdBlock[]>();
  private scroller: Scroller = new Scroller();
  @State private atBottom: boolean = true;

  @State private draft: string = '';
  @State private sending: boolean = false;
  @State @Watch('onRunningChange') private running: boolean = false;
  @State private pendImgs: ImagePart[] = [];
  @State private pendFiles: FilePart[] = [];
  @State private queueItems: QueuedItem[] = [];
  @State private pendH: number = 0;
  @State private pendBusy: boolean = false;
  @State private rescue: StashItem[] = [];
  @State private rescueBusy: boolean = false;
  private retryText: string = '';
  private pendingKey: string = '';

  @State private ctx: ContextUsage | null = null;
  @State private stats: SessionStats | null = null;
  @State private statsOn: boolean = false;
  @State private statsRefreshing: boolean = false;
  @State private groups: CatalogGroup[] = [];
  @State private groupsLoaded: boolean = false;
  private loadingModels: boolean = false;
  @State private modelOn: boolean = false;
  @State private pickingModelId: string = '';
  @State private curModel: string = '';
  @State private curModelId: string = '';
  @State private curEffort: string = '';
  @State private teamOn: boolean = false;
  @State private teamBusy: boolean = false;
  private teamSeq: number = 0;
  @State private agents: AgentRef[] = [];

  @State private goalOn: boolean = false;
  @State private goal: GoalView | null = null;
  @State private goalBusy: boolean = false;

  @State private planActive: boolean = false;
  @State private planBusy: boolean = false;
  @State private hostCommands: SlashCommandRow[] = [];
  @State private slashOpened: boolean = false;
  @State private cmdBusyText: string = '';

  @State private permOn: boolean = false;
  @State private permLoading: boolean = false;
  @State private permUnavailable: boolean = false;
  @State private permPresets: PermRow[] = [];
  @State private permCurrent: string = '';
  @State private permSaving: string = '';

  @State private fbQuickOn: boolean = false;
  @State private fbQuickBusy: boolean = false;

  @State private titleNow: string = '';
  @State private pinned: boolean = false;
  @State private menuOn: boolean = false;
  @State private renaming: boolean = false;
  @State private searchOn: boolean = false;
  @State private bigEditOn: boolean = false;
  @State private queueEditId: string = '';
  @State private editBuf: string = '';
  @State private attachOn: boolean = false;
  @State private inputH: number = 0;
  @State private bottomStackH: number = 0;
  @State private backendCaps: BackendCapabilities = defaultBackendCapabilities('dsh');
  @State private msgMenuOn: boolean = false;
  @State private menuMsg: Message | null = null;
  @State private asks: PendingAsk[] = [];
  @State private extrasMode: string = '';
  @State private webConsoleOn: boolean = false;
  @State private composerPressed: boolean = false;
  @State private composerTouchXPct: number = 50;
  @State private composerTouchYPct: number = 50;
  private composerW: number = 340;
  private composerH: number = 104;

  @State private err: string = '';
  @State private errCard: string = '';
  @State private errCardCode: string = '';

  private stopStream: (() => void) | null = null;
  private sseActive: boolean = false;
  private poller: number = 0;
  @State private dotOn: number = 0;
  @State private hdrEntered: boolean = true;
  private hdrTimer: number = -1;
  private dotTimer: number = 0;
  private alive: boolean = false;
  private gen: number = 0;
  private retried: number = 0;
  private retryTimer: number = 0;

  // ---------- 生命周期与未读消点（F12） ----------

  aboutToAppear(): void {
    this.alive = true;
    this.gen++;
    if (Motion.isFlagship(this.motionMode)) {
      this.hdrEntered = false;
      this.hdrTimer = setTimeout(() => {
        this.hdrTimer = -1;
        this.hdrEntered = true;
      }, 24);
    } else {
      this.hdrEntered = true;
    }
    this.initialMaxSeq = Number.MAX_SAFE_INTEGER;
    this.seenSeqs.clear();
    this.pinKeyboard();
    this.titleNow = this.param.title;
    Marks.clear(this.param.id);
    Unread.markRead(this.param.id);
    this.draft = Drafts.get(this.param.id);
    AppStorage.setOrCreate('openSession', this.param.id);
    AppStorage.setOrCreate('pendingOpenSession', '');
    this.curModelId = this.param.model ?? '';
    this.curModel = '';
    this.curEffort = this.param.effort ?? '';
    this.syncFromCachedSessions();
    this.backendCaps = defaultBackendCapabilities(this.sessionBackend());
    void this.load(true);
    void this.loadBackendCaps();
    void this.loadModels();
    void this.loadSessionMeta();
    void this.loadHostCommands();
    if (!this.isExternalBackend()) {
      void this.loadTeamMode();
      void this.loadPlanState();
      void this.loadGoalSilent();
    }
  }

  aboutToDisappear(): void {
    Drafts.set(this.param.id, this.draft);
    Drafts.flush();
    this.unpinKeyboard();
    AppStorage.setOrCreate('openSession', '');
    this.alive = false;
    this.gen++;
    if (this.hdrTimer >= 0) {
      clearTimeout(this.hdrTimer);
      this.hdrTimer = -1;
    }
    if (this.retryTimer !== 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = 0;
    }
    this.closeStream();
    this.stopPolling();
    this.stopDotTimer();
  }

  private onAppFgChange(): void {
    if (!this.alive) return;
    if (this.appFg === true) {
      Unread.markRead(this.param.id);
      void this.refreshSoft();
      this.startRealtimeStream();
    } else {
      this.closeStream();
      this.stopPolling();
    }
  }

  private markReadIfForeground(): void {
    if (this.alive && this.appFg === true) {
      Unread.markRead(this.param.id);
    }
  }

  private onRunningChange(): void {
    if (this.running && this.alive) {
      if (this.dotTimer === 0) {
        this.dotTimer = setInterval(() => {
          this.dotOn = (this.dotOn + 1) % 3;
        }, 280);
      }
    } else {
      this.stopDotTimer();
    }
  }

  private stopDotTimer(): void {
    if (this.dotTimer !== 0) {
      clearInterval(this.dotTimer);
      this.dotTimer = 0;
    }
  }

  private onCompactHistoryChange(): void {
    if (!this.alive) return;
    this.closeStream();
    this.stopPolling();
    void this.load(true);
  }

  // ---------- 键盘避让（U5 / M2） ----------

  private pinKeyboard(): void {
    try { this.getUIContext().setKeyboardAvoidMode(KbMode.NONE); } catch (e) {}
    window.getLastWindow(AppCtx.ability()).then((w: window.Window) => {
      if (!this.alive) return;
      this.kwWin = w;
      try {
        this.winH = AppCtx.px2vp(w.getWindowProperties().windowRect.height);
      } catch (e) {
        this.winH = 0;
      }
      this.kwCb = (h: number) => {
        this.kwRep = h > 0 ? AppCtx.px2vp(h) : 0;
        this.applyKb();
      };
      w.on('keyboardHeightChange', this.kwCb);
      this.kwAvoidCb = (data: window.AvoidAreaOptions) => {
        const area: window.AvoidArea = data.area;
        const px: number = area === undefined || area.bottomRect === undefined ? 0 : area.bottomRect.height;
        this.kwAvoid = px > 0 ? AppCtx.px2vp(px) : 0;
        this.kwAvoidSeen = true;
        this.applyKb();
      };
      w.on('avoidAreaChange', this.kwAvoidCb);
    }).catch(() => {});
  }

  private applyKb(): void {
    const next: number = resolveKeyboardHeightVp(this.kwRep, this.kwAvoid, this.kwAvoidSeen, this.winH);
    if (Math.abs(next - this.kbH) > 0.5) {
      const wasBottom: boolean = this.atBottom;
      const rising: boolean = next > this.kbH;
      try {
        this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
          this.kbH = next;
        });
      } catch (e) {
        this.kbH = next;
      }
      if (wasBottom && rising) {
        setTimeout(() => {
          if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
        }, 60);
      }
    }
  }

  private unpinKeyboard(): void {
    if (this.kwWin !== null && this.kwCb !== null) {
      try { this.kwWin.off('keyboardHeightChange', this.kwCb); } catch (e) {}
    }
    if (this.kwWin !== null && this.kwAvoidCb !== null) {
      try { this.kwWin.off('avoidAreaChange', this.kwAvoidCb); } catch (e) {}
    }
    this.kwWin = null;
    this.kwCb = null;
    this.kwAvoidCb = null;
    this.kwRep = 0;
    this.kwAvoid = 0;
    this.kwAvoidSeen = false;
    this.kbH = 0;
    try { this.getUIContext().setKeyboardAvoidMode(KbMode.RESIZE); } catch (e) {}
  }

  private hideKb(): void {
    try { inputMethod.getController().stopInputSession(); } catch (err) {}
  }

  // ---------- SSE 实时流与自动回退轮询（G4 / R4） ----------

  private closeStream(): void {
    const fn: (() => void) | null = this.stopStream;
    this.stopStream = null;
    this.sseActive = false;
    if (fn !== null) fn();
  }

  private startRealtimeStream(): void {
    if (!this.alive) return;
    this.closeStream();
    this.stopPolling();
    if (this.api.onWan() && this.api.isEncrypted()) {
      this.sseActive = false;
      this.startFallbackPoll();
      return;
    }
    const g: number = this.gen;
    const lastSeq: number = this.msgs.length > 0 ? this.msgs[this.msgs.length - 1].seq : 0;
    const sinceSeq: number = this.running && lastSeq > 0 ? lastSeq - 1 : lastSeq;
    this.sseActive = true;
    this.stopStream = this.api.streamSession(
      this.param.id,
      sinceSeq,
      (u: StreamUpdate): void => {
        if (!this.alive || g !== this.gen) return;
        this.handleStreamUpdate(u);
      },
      (reason: string): void => {
        if (!this.alive || g !== this.gen) return;
        console.info('DSH_SSE fallback -> poll (' + reason + ')');
        this.sseActive = false;
        this.stopStream = null;
        this.startFallbackPoll();
      },
      this.compactHistory
    );
  }

  private handleStreamUpdate(u: StreamUpdate): void {
    if (!this.alive) return;
    const wasBottom: boolean = this.atBottom;
    if (u.running !== undefined) this.running = u.running === true;
    if (u.context !== undefined && u.context !== null) this.ctx = u.context;
    if (u.stats !== undefined && u.stats !== null) this.stats = u.stats;
    if (u.plan !== undefined) this.planActive = u.plan.active === true;
    if (u.queue !== undefined) this.applyQueue(u.queue);
    if (u.questions !== undefined) {
      this.asks = u.questions.active === undefined ? [] : u.questions.active;
    }
    if (u.messages !== undefined && u.messages.length > 0) {
      const merged: Message[] = mergeMessageList(this.msgs, u.messages);
      this.msgs = merged;
      this.total = u.total > 0 ? u.total : Math.max(this.total, merged.length);
      this.hasMore = this.msgs.length < this.total;
      const imgIds: string[] = collectImageIds(u.messages);
      if (imgIds.length > 0) {
        this.api.signAttachments(imgIds).then(() => {
          if (this.alive) this.msgs = this.msgs.slice();
        }).catch(() => {});
      }
      ChatCache.write(this.param.id, this.msgs, this.total, this.running, u.lastTurn ?? '');
      const synRes: MessagesResult = {
        total: this.total,
        messages: this.msgs,
        running: this.running,
        lastTurn: u.lastTurn,
        lastErr: u.lastErr,
        queue: this.queueItems,
        questions: u.questions,
        plan: u.plan
      };
      this.rescue = reconcileOutboxItems(this.param.id, synRes);
      this.markReadIfForeground();
      if (wasBottom) {
        setTimeout(() => {
          if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
        }, 40);
      }
    } else if (u.total > 0 && u.total !== this.total) {
      this.total = u.total;
      this.hasMore = this.msgs.length < this.total;
    }
    if (u.lastErr !== undefined) {
      this.takeLastErr(u.lastErr);
    } else if (this.running && this.errCard !== '') {
      this.dismissErrCard();
    }
    if (this.err !== '') this.err = '';
  }

  private startFallbackPoll(): void {
    this.stopPolling();
    this.schedulePoll(1200);
  }

  private schedulePoll(ms: number): void {
    if (!this.alive || this.sseActive) return;
    if (this.poller !== 0) clearTimeout(this.poller);
    this.poller = setTimeout(() => {
      this.poller = 0;
      void this.pollOnce();
    }, ms);
  }

  private stopPolling(): void {
    if (this.poller !== 0) {
      clearTimeout(this.poller);
      this.poller = 0;
    }
  }

  private async pollOnce(): Promise<void> {
    if (!this.alive || this.sseActive) return;
    if (this.sending || this.loading) {
      this.schedulePoll(1200);
      return;
    }
    const g: number = this.gen;
    const lastSeq: number = this.msgs.length > 0 ? this.msgs[this.msgs.length - 1].seq : 0;
    const sinceSeq: number = this.running && lastSeq > 0 ? lastSeq - 1 : lastSeq;
    try {
      const r: MessagesResult = await this.api.messagesSince(this.param.id, sinceSeq, this.compactHistory);
      if (!this.alive || g !== this.gen || this.sseActive) return;
      this.running = r.running === true;
      this.takeLastErr(r.lastErr);
      this.applyQueue(r.queue === undefined ? [] : r.queue);
      const qs: AskState | undefined = r.questions;
      this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      if (r.context !== undefined && r.context !== null) this.ctx = r.context;
      if (r.plan !== undefined) this.planActive = r.plan.active === true;
      if (this.err !== '') this.err = '';
      if (r.total !== this.total || r.messages.length > 0) {
        const merged: Message[] = mergeMessageList(this.msgs, r.messages);
        await this.api.signAttachments(collectImageIds(r.messages));
        if (!this.alive || g !== this.gen) return;
        this.msgs = merged;
        this.total = r.total > 0 ? r.total : merged.length;
        this.hasMore = this.msgs.length < this.total;
        if (r.stats !== undefined && r.stats !== null) this.stats = r.stats;
        ChatCache.write(this.param.id, this.msgs, this.total, this.running, r.lastTurn ?? '');
        this.rescue = reconcileOutboxItems(this.param.id, r);
        this.markReadIfForeground();
        if (this.atBottom) {
          setTimeout(() => {
            if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
          }, 80);
        }
      }
    } catch (e) {
    }
    this.schedulePoll(this.running ? 1200 : 4000);
  }

  // ---------- 消息加载与分页 ----------

  private async load(startStreamAfter: boolean = false): Promise<void> {
    const g: number = this.gen;
    if (this.msgs.length === 0) {
      const snap: ChatSnapshot | null = ChatCache.read(this.param.id);
      if (snap !== null) {
        this.msgs = snap.messages;
        this.total = snap.total;
        this.running = snap.running;
        this.hasMore = snap.messages.length < snap.total;
        this.cached = true;
        this.loading = false;
        if (this.atBottom) {
          setTimeout(() => {
            if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
          }, 30);
        }
      }
    }
    const wasBottom: boolean = this.atBottom;
    const beforeTail: string = this.msgs.length === 0 ? '' :
      String(this.msgs[this.msgs.length - 1].seq) + ':' + String(this.msgs[this.msgs.length - 1].text.length);
    try {
      const r: MessagesResult = await this.api.messages(this.param.id, 60, this.compactHistory);
      if (!this.alive || g !== this.gen) return;
      await this.api.signAttachments(collectImageIds(r.messages));
      if (!this.alive || g !== this.gen) return;
      if (startStreamAfter || this.initialMaxSeq === Number.MAX_SAFE_INTEGER) {
        this.initialMaxSeq = r.messages.length > 0 ? r.messages[r.messages.length - 1].seq : 0;
      }
      this.msgs = r.messages;
      this.total = r.total;
      this.stats = r.stats ?? null;
      this.ctx = r.context === undefined ? null : r.context;
      this.running = r.running === true;
      if (r.plan !== undefined) this.planActive = r.plan.active === true;
      this.applyQueue(r.queue === undefined ? [] : r.queue);
      const qs: AskState | undefined = r.questions;
      this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      this.hasMore = r.messages.length < r.total;
      this.err = '';
      this.takeLastErr(r.lastErr);
      this.cached = false;
      ChatCache.write(this.param.id, r.messages, r.total, r.running === true, r.lastTurn ?? '');
      this.rescue = reconcileOutboxItems(this.param.id, r);
      this.markReadIfForeground();
      const afterTail: string = r.messages.length === 0 ? '' :
        String(r.messages[r.messages.length - 1].seq) + ':' + String(r.messages[r.messages.length - 1].text.length);
      if (wasBottom && afterTail !== beforeTail) {
        setTimeout(() => {
          if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
        }, 80);
      }
      if (startStreamAfter || (!this.sseActive && this.poller === 0)) {
        this.startRealtimeStream();
      }
    } catch (e) {
      const msg: string = (e as Error).message;
      if (!this.alive || g !== this.gen) return;
      if (msg.indexOf('session log not found') >= 0 && this.retried < 6) {
        this.retried++;
        this.err = '';
        this.retryTimer = setTimeout(() => {
          this.retryTimer = 0;
          if (this.alive) void this.load(startStreamAfter);
        }, 500);
        return;
      }
      if (this.cached) {
        this.err = '';
      } else {
        this.err = msg;
        this.showErrCard('', msg, Date.now());
      }
      if (!this.sseActive && this.poller === 0) this.startFallbackPoll();
    } finally {
      this.loading = false;
    }
  }

  private async refreshSoft(): Promise<void> {
    const g: number = this.gen;
    Haptics.tap();
    this.statsRefreshing = true;
    try {
      const r: MessagesResult = await this.api.messages(this.param.id, 60, this.compactHistory);
      if (!this.alive || g !== this.gen) return;
      if (this.msgs.length > 0 && r.messages.length > 0) {
        const localLast: number = this.msgs[this.msgs.length - 1].seq;
        const srvFirst: number = r.messages[0].seq;
        const srvLast: number = r.messages[r.messages.length - 1].seq;
        if (srvLast < localLast || srvFirst > localLast + 1) {
          await this.load(false);
          return;
        }
      }
      await this.api.signAttachments(collectImageIds(r.messages));
      if (!this.alive || g !== this.gen) return;
      const out: Message[] = mergeMessageList(this.msgs, r.messages);
      this.msgs = out;
      this.total = r.total;
      this.stats = r.stats ?? null;
      this.ctx = r.context === undefined ? null : r.context;
      this.running = r.running === true;
      if (r.plan !== undefined) this.planActive = r.plan.active === true;
      this.applyQueue(r.queue === undefined ? [] : r.queue);
      const qs: AskState | undefined = r.questions;
      this.asks = qs === undefined || qs.active === undefined ? [] : qs.active;
      this.hasMore = out.length < r.total;
      this.err = '';
      this.takeLastErr(r.lastErr);
      this.cached = false;
      ChatCache.write(this.param.id, out, r.total, r.running === true, r.lastTurn ?? '');
      this.rescue = reconcileOutboxItems(this.param.id, r);
      this.markReadIfForeground();
    } catch (e) {
      const msg: string = (e as Error).message;
      if (!this.alive || g !== this.gen) return;
      this.err = msg;
      this.showErrCard('', msg, Date.now());
    } finally {
      this.statsRefreshing = false;
    }
  }

  private async loadOlder(): Promise<void> {
    if (this.loadingMore || this.msgs.length === 0) return;
    this.loadingMore = true;
    const g: number = this.gen;
    try {
      const oldest: number = this.msgs[0].seq;
      const r: MessagesResult = await this.api.messagesBefore(this.param.id, oldest, 60, this.compactHistory);
      if (!this.alive || g !== this.gen) return;
      if (r.messages.length === 0) {
        this.hasMore = false;
      } else {
        await this.api.signAttachments(collectImageIds(r.messages));
        if (!this.alive || g !== this.gen) return;
        this.msgs = r.messages.concat(this.msgs);
        this.hasMore = this.msgs.length < r.total;
      }
      this.err = '';
    } catch (e) {
      if (this.alive && g === this.gen) {
        this.err = (e as Error).message;
      }
    } finally {
      this.loadingMore = false;
    }
  }

  // ---------- 会话元数据、模型、协作、计划、目标与指令（F04 / F09） ----------

  private syncFromCachedSessions(): void {
    const rows: SessionRow[] = this.api.cachedSessions();
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === this.param.id) {
        this.pinned = rows[i].pinned === true;
        if (rows[i].title !== '' && this.titleNow === '') this.titleNow = rows[i].title;
        const pl: PlanState | undefined = rows[i].plan;
        if (pl !== undefined) this.planActive = pl.active === true;
        const a = rows[i].agents;
        if (a !== undefined && a.subagents.length > 0) this.agents = a.subagents;
        break;
      }
    }
  }

  private async loadSessionMeta(): Promise<void> {
    const g: number = this.gen;
    try {
      const rows: SessionRow[] = await this.api.sessions();
      if (!this.alive || g !== this.gen) return;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].id === this.param.id) {
          this.pinned = rows[i].pinned === true;
          const pl: PlanState | undefined = rows[i].plan;
          if (pl !== undefined) this.planActive = pl.active === true;
          const a = rows[i].agents;
          if (a !== undefined && a.subagents.length > 0) this.agents = a.subagents;
          break;
        }
      }
    } catch (e) {
    }
  }

  private async loadPlanState(): Promise<void> {
    const g: number = this.gen;
    try {
      const st: PlanState = await this.api.plan(this.param.id);
      if (this.alive && g === this.gen) {
        this.planActive = st.active === true;
      }
    } catch (e) {
    }
  }

  private async togglePlanMode(nextActive: boolean): Promise<void> {
    if (this.planBusy) return;
    this.planBusy = true;
    const g: number = this.gen;
    try {
      const st: PlanState = await this.api.setPlan(this.param.id, nextActive);
      if (!this.alive || g !== this.gen) return;
      this.planActive = st.active === true;
      Toast.ok(this.planActive ? '已开启计划模式' : '已退出计划模式');
    } catch (e) {
      Toast.err('切换计划模式失败：' + (e as Error).message);
    } finally {
      this.planBusy = false;
    }
  }

  private async loadHostCommands(): Promise<void> {
    const g: number = this.gen;
    try {
      const list: SlashCommandRow[] = await this.api.commands(this.param.id);
      if (this.alive && g === this.gen) {
        this.hostCommands = list;
      }
    } catch (e) {
      // 旧宿主 404 时由内置指令列表兜底
    }
  }

  private async loadGoalSilent(): Promise<void> {
    const g: number = this.gen;
    try {
      const gv: GoalView | null = await this.api.goal(this.param.id);
      if (this.alive && g === this.gen) {
        this.goal = gv;
      }
    } catch (e) {
    }
  }

  private async loadModels(): Promise<void> {
    if (this.loadingModels) return;
    this.loadingModels = true;
    const g: number = this.gen;
    try {
      const mState: ResolvedModelState = await fetchResolvedModelState(this.api, this.param.id);
      if (!this.alive || g !== this.gen) return;
      this.groups = mState.groups;
      this.groupsLoaded = true;
      if (mState.modelId !== '') {
        this.curModelId = mState.modelId;
        this.curModel = mState.modelLabel;
        this.curEffort = mState.effort;
      }
    } catch (e) {
      if (this.alive && g === this.gen) {
        this.err = (e as Error).message;
        this.groupsLoaded = true;
      }
    } finally {
      this.loadingModels = false;
    }
  }

  private openModels(): void {
    this.modelOn = true;
    if (!this.isExternalBackend()) {
      void this.loadTeamMode();
    }
    if (!this.groupsLoaded || this.groups.length === 0) {
      this.groupsLoaded = false;
      void this.loadModels();
    }
  }

  private async pickModel(groupId: string, modelId: string, effort: string, effortOnly: boolean): Promise<void> {
    if (this.pickingModelId !== '') return;
    this.pickingModelId = effortOnly ? '__effort__' : modelId;
    try {
      await this.api.selectModel(this.param.id, groupId, modelId, effort);
      this.curModelId = modelId;
      this.curModel = modelLabelOf(this.groups, modelId);
      this.curEffort = effort;
      if (effortOnly) {
        Toast.ok('推理强度已更新');
      } else {
        Toast.ok('已切换模型');
        this.modelOn = false;
      }
    } catch (e) {
      Toast.err('切换失败：' + (e as Error).message);
    } finally {
      this.pickingModelId = '';
    }
  }

  private async loadTeamMode(): Promise<void> {
    const seq: number = this.teamSeq;
    const g: number = this.gen;
    try {
      const r = await this.api.team(this.param.id);
      if (this.alive && g === this.gen && seq === this.teamSeq) this.teamOn = r.enabled === true;
    } catch (e) {
    }
  }

  private async setTeamMode(v: boolean): Promise<void> {
    if (this.teamBusy) return;
    this.teamBusy = true;
    this.teamOn = v;
    Haptics.tap();
    this.teamSeq++;
    const seq: number = this.teamSeq;
    const g: number = this.gen;
    try {
      const on: boolean = await this.api.teamMode(this.param.id, v);
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) return;
      this.teamOn = on;
      Toast.ok(on ? '智能体协作已开启' : '智能体协作已关闭');
    } catch (e) {
      if (!this.alive || g !== this.gen || seq !== this.teamSeq) return;
      try {
        const r = await this.api.team(this.param.id);
        if (this.alive && g === this.gen && seq === this.teamSeq) {
          this.teamOn = r.enabled === true;
          Toast.ok(this.teamOn ? '智能体协作已开启' : '智能体协作已关闭');
          return;
        }
      } catch (e2) {
      }
      Toast.err('切换结果未确认：' + (e as Error).message);
    } finally {
      this.teamBusy = false;
    }
  }

  private openGoal(): void {
    this.goalOn = true;
    this.api.goal(this.param.id).then((gv: GoalView | null) => {
      if (this.alive) this.goal = gv;
    }).catch((e: Error) => {
      if (this.alive) this.err = e.message;
    });
  }

  private async createGoal(objective: string, maxRounds: number): Promise<boolean> {
    const text: string = objective.trim();
    if (text === '' || this.goalBusy) return false;
    this.goalBusy = true;
    try {
      this.goal = await this.api.goalCreate(
        this.param.id,
        text,
        maxRounds > 0 ? maxRounds : undefined
      );
      Toast.ok('长期目标已创建');
      return true;
    } catch (e) {
      Toast.err('创建目标失败：' + (e as Error).message);
      return false;
    } finally {
      this.goalBusy = false;
    }
  }

  private async actGoal(action: string): Promise<void> {
    if (this.goalBusy) return;
    this.goalBusy = true;
    try {
      this.goal = await this.api.goalAction(this.param.id, action);
      if (action === 'clear') {
        Toast.ok('目标已清除');
      } else if (action === 'complete') {
        Toast.ok('目标已标记完成');
      } else {
        Toast.ok('目标已更新');
      }
    } catch (e) {
      Toast.err('操作失败：' + (e as Error).message);
    } finally {
      this.goalBusy = false;
    }
  }

  private async saveGoalEdit(objective: string): Promise<boolean> {
    const text: string = objective.trim();
    if (text === '' || this.goalBusy) return false;
    this.goalBusy = true;
    try {
      this.goal = await this.api.goalAction(this.param.id, 'edit', text);
      Toast.ok('目标已修改');
      return true;
    } catch (e) {
      Toast.err('修改失败：' + (e as Error).message);
      return false;
    } finally {
      this.goalBusy = false;
    }
  }

  private openPermPicker(): void {
    this.permOn = true;
    this.permLoading = true;
    this.permUnavailable = false;
    const g: number = this.gen;
    this.api.permissions(this.param.id).then((r: PermsResp) => {
      if (!this.alive || g !== this.gen) return;
      this.permPresets = r.presets ?? [];
      this.permCurrent = r.current !== '' ? r.current : r.defaultPreset;
      this.permUnavailable = r.unavailable === true;
    }).catch((e: Error) => {
      if (!this.alive || g !== this.gen) return;
      this.permUnavailable = true;
      Toast.err('读取权限失败：' + e.message);
    }).finally(() => {
      this.permLoading = false;
    });
  }

  private async pickPermission(val: string): Promise<void> {
    if (this.permSaving !== '') return;
    this.permSaving = val;
    try {
      const next: string = await this.api.setPermission(this.param.id, val);
      this.permCurrent = next;
      Toast.ok('权限档位已更新');
      this.permOn = false;
    } catch (e) {
      Toast.err('切换权限失败：' + (e as Error).message);
    } finally {
      this.permSaving = '';
    }
  }

  private async submitQuickFeedback(category: string, content: string): Promise<boolean> {
    if (this.fbQuickBusy) return false;
    this.fbQuickBusy = true;
    try {
      const line: string = '/feedback [' + category + '] ' + content;
      const resp: CommandExecResp = await this.api.execCommand(this.param.id, line);
      this.fbQuickOn = false;
      Toast.ok(resp.text !== '' ? resp.text : '反馈已记录到当前会话');
      await this.refreshSoft();
      return true;
    } catch (e) {
      Toast.err('提交反馈失败：' + (e as Error).message);
      return false;
    } finally {
      this.fbQuickBusy = false;
    }
  }

  private openExportFormatPicker(): void {
    Haptics.tap();
    if (this.isExternalBackend()) {
      void this.runExportFormat('markdown');
      return;
    }
    this.getUIContext().getPromptAction().showDialog({
      title: '下载会话日志',
      message: '选择导出格式并保存到手机本地：',
      buttons: [
        { text: '导出 .md', color: Tokens.accent },
        { text: '下载 .zip', color: Tokens.fg },
        { text: '取消', color: Tokens.dim }
      ]
    }).then((res) => {
      if (res.index === 0) {
        void this.runExportFormat('markdown');
      } else if (res.index === 1) {
        void this.runExportFormat('zip');
      }
    }).catch(() => {});
  }

  private async runExportFormat(format: string): Promise<void> {
    if (this.cmdBusyText !== '') return;
    this.cmdBusyText = format === 'zip' ? '正在打包完整会话…' : '正在导出 Markdown…';
    try {
      const ok: boolean = await exportSessionByFormat(
        this.api,
        AppCtx.ability(),
        this.param.id,
        this.titleNow,
        this.msgs,
        format
      );
      if (ok) {
        Toast.ok(format === 'zip' ? '已保存完整会话包 (.zip)' : '已导出 Markdown');
      }
    } catch (e) {
      Toast.err('导出失败：' + (e as Error).message);
    } finally {
      this.cmdBusyText = '';
    }
  }

  private async executeCompactCommand(): Promise<void> {
    if (this.cmdBusyText !== '') return;
    this.cmdBusyText = '正在压缩上下文…';
    try {
      const resp: CommandExecResp = await this.api.execCommand(this.param.id, '/compact');
      Toast.ok(resp.text !== '' ? resp.text : '上下文压缩完成');
      await this.refreshSoft();
    } catch (e) {
      Toast.err('压缩失败：' + (e as Error).message);
    } finally {
      this.cmdBusyText = '';
    }
  }

  private async runHostSlashCommand(cmd: SlashCommandRow): Promise<void> {
    if (this.cmdBusyText !== '') return;
    this.cmdBusyText = '正在执行 /' + cmd.name + '…';
    try {
      const resp: CommandExecResp = await this.api.execCommand(this.param.id, '/' + cmd.name);
      if (resp.kind === 'error' || resp.ok === false) {
        Toast.err(resp.text !== '' ? resp.text : ('执行 /' + cmd.name + ' 失败'));
      } else {
        Toast.ok(resp.text !== '' ? resp.text : ('已执行 /' + cmd.name));
      }
      await this.refreshSoft();
    } catch (e) {
      Toast.err('执行 /' + cmd.name + ' 失败：' + (e as Error).message);
    } finally {
      this.cmdBusyText = '';
    }
  }

  private clearSlashDraftIfNeeded(): void {
    if (this.draft.startsWith('/')) {
      this.draft = '';
      this.pendingKey = '';
      Drafts.set(this.param.id, '');
    }
    this.slashOpened = false;
  }

  private handleSlashCommand(cmd: SlashCommandRow): void {
    this.attachOn = false;
    this.clearSlashDraftIfNeeded();
    const n: string = cmd.name.trim().toLowerCase();
    if (n === 'compact') {
      void this.executeCompactCommand();
      return;
    }
    if (n === 'permission') {
      this.hideKb();
      this.openPermPicker();
      return;
    }
    if (n === 'model') {
      this.hideKb();
      this.openModels();
      return;
    }
    if (n === 'export') {
      this.hideKb();
      this.openExportFormatPicker();
      return;
    }
    if (n === 'restart' || n === 'restart-force') {
      const isForce: boolean = n === 'restart-force';
      AppCtx.confirm(
        isForce ? '立即强制重启电脑端网关？' : '空闲重启电脑端网关？',
        isForce
          ? '将立即中断正在执行的任务并重启电脑端服务，手机连接会短暂断开。'
          : '将在当前任务空闲后重启电脑端服务，重启期间连接会短暂断开。',
        isForce ? '强制重启' : '确认重启',
        () => {
          void this.runHostSlashCommand(cmd);
        },
        isForce
      );
      return;
    }
    void this.runHostSlashCommand(cmd);
  }

  private currentSlashFilter(): string {
    if (!this.attachOn || !this.draft.startsWith('/')) {
      return '';
    }
    const body: string = this.draft.slice(1);
    if (body.indexOf(' ') >= 0 || body.indexOf('\n') >= 0 || body.length > 24) {
      return '';
    }
    return body;
  }

  private openPresetsPage(): void {
    const p: ChatParam = { id: this.param.id, title: this.titleNow !== '' ? this.titleNow : this.param.title };
    this.stack.pushPathByName('presets', p);
  }

  // ---------- 提问回答、发送、队列、附件与重发 ----------

  private async submitAskAnswers(callId: string, answers: AskAnswer[]): Promise<void> {
    try {
      await this.api.answerQuestions(this.param.id, callId, answers);
      this.asks = this.asks.filter((x: PendingAsk) => x.callId !== callId);
      Toast.ok('已回答');
      if (!this.sseActive) this.schedulePoll(800);
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private hasPend(): boolean {
    return this.pendImgs.length > 0 || this.pendFiles.length > 0;
  }

  private applyQueue(list: QueuedItem[]): void {
    this.queueItems = list;
    if (this.pendFiles.length + list.length === 0) this.pendH = 0;
  }

  private pendCardHeight(): number {
    const n: number = this.pendFiles.length + this.queueItems.length;
    return (n > 4 ? 4 : n) * 48 + 8;
  }

  private pendMove(from: number, to: number): void {
    const outcome: ReorderOutcome | null = reorderPendList(this.pendFiles, this.queueItems, from, to);
    if (outcome === null) return;
    this.pendFiles = outcome.files;
    Haptics.tap();
    if (!outcome.queueChanged) return;
    this.api.queueReorder(this.param.id, outcome.queueIds)
      .then(() => { Toast.ok('顺序已更新'); void this.refreshSoft(); })
      .catch((e: Error) => { Toast.err('排序失败：' + e.message); });
  }

  private queueById(id: string): QueuedItem | null {
    for (let i = 0; i < this.queueItems.length; i++) {
      if (this.queueItems[i].id === id) return this.queueItems[i];
    }
    return null;
  }

  private fireRow(r: PendRow): void {
    if (r.kind === 'queue') {
      const q: QueuedItem | null = this.queueById(r.id);
      if (q !== null) void this.doQueueFire(q);
      return;
    }
    void this.fireLocal(r.kind, r.idx);
  }

  private async fireLocal(kind: string, idx: number): Promise<void> {
    if (this.pendBusy) return;
    const imgs: ImagePart[] = kind === 'img' && idx < this.pendImgs.length ? [this.pendImgs[idx]] : [];
    const files: FilePart[] = kind === 'file' && idx < this.pendFiles.length ? [this.pendFiles[idx]] : [];
    const text: string = this.draft.trim();
    this.pendBusy = true;
    try {
      Haptics.tap();
      await this.api.sendOutbox(this.param.id, text, imgs, files, 'steer');
      if (text !== '') {
        this.draft = '';
        Drafts.set(this.param.id, '');
      }
      if (kind === 'img' && idx < this.pendImgs.length) this.dropImg(idx);
      if (kind === 'file' && idx < this.pendFiles.length) this.dropFile(idx);
      Toast.ok('已经插队发出');
      await this.refreshSoft();
    } catch (e) {
      Toast.err('发不出去：' + (e as Error).message);
    } finally {
      this.pendBusy = false;
    }
  }

  private dropRow(r: PendRow): void {
    if (r.kind === 'queue') {
      const q: QueuedItem | null = this.queueById(r.id);
      if (q !== null) void this.doQueueDrop(q);
      return;
    }
    Haptics.tap();
    if (r.kind === 'img') {
      this.dropImg(r.idx);
    } else {
      this.dropFile(r.idx);
    }
  }

  private dropImg(i: number): void {
    if (i < 0 || i >= this.pendImgs.length) return;
    this.pendImgs = this.pendImgs.filter((_: ImagePart, k: number) => k !== i);
  }

  private dropFile(i: number): void {
    if (i < 0 || i >= this.pendFiles.length) return;
    const next: FilePart[] = this.pendFiles.filter((_: FilePart, k: number) => k !== i);
    this.pendFiles = next;
    if (next.length + this.queueItems.length === 0) this.pendH = 0;
  }

  private async doQueueDrop(q: QueuedItem): Promise<void> {
    try {
      await this.api.queueDrop(this.param.id, q.id);
      this.applyQueue(this.queueItems.filter((x: QueuedItem) => x.id !== q.id));
      Haptics.tap();
    } catch (e) {
      this.err = '撤不回来：' + (e as Error).message;
    }
  }

  private doQueueEdit(q: QueuedItem): void {
    Haptics.tap();
    this.queueEditId = q.id;
    this.editBuf = q.text;
    this.bigEditOn = true;
  }

  private async saveQueueEdit(): Promise<void> {
    const id: string = this.queueEditId;
    if (id === '') return;
    const text: string = this.editBuf.trim();
    if (text === '') {
      Toast.ok('内容不能为空');
      return;
    }
    try {
      await this.api.queueEdit(this.param.id, id, text);
      const out: QueuedItem[] = [];
      for (let i = 0; i < this.queueItems.length; i++) {
        const x: QueuedItem = this.queueItems[i];
        if (x.id === id) {
          const updated: QueuedItem = { id: x.id, text: text, at: x.at, index: x.index, images: x.images };
          out.push(updated);
        } else {
          out.push(x);
        }
      }
      this.queueItems = out;
      this.queueEditId = '';
      this.editBuf = '';
      this.bigEditOn = false;
      Toast.ok('已更新');
    } catch (e) {
      Toast.err('更新失败：' + (e as Error).message);
    }
  }

  private async doQueueFire(q: QueuedItem): Promise<void> {
    try {
      Haptics.tap();
      await this.api.queueFire(this.param.id, q.id);
      this.applyQueue(this.queueItems.filter((x: QueuedItem) => x.id !== q.id));
      Toast.ok('已插队');
      if (!this.sseActive) this.schedulePoll(800);
    } catch (e) {
      this.err = '插队失败：' + (e as Error).message;
    }
  }

  private onOnline(): void {
    if (!this.alive || !this.online) return;
    void this.refreshSoft();
    this.startRealtimeStream();
    if (this.rescue.length === 0 || this.rescueBusy || this.running) return;
    Toast.info('网络已恢复，正在重发未发出的消息');
    void this.resendRescue();
  }

  private async resendRescue(): Promise<void> {
    if (this.rescueBusy || this.rescue.length === 0) return;
    Haptics.tap();
    this.rescueBusy = true;
    const items: StashItem[] = this.rescue;
    try {
      await replayOutboxItems(this.api, this.param.id, items, (left: StashItem[]): void => {
        this.rescue = left;
      });
      Toast.ok('已重发 ' + String(items.length) + ' 条');
      this.rescue = Outbox.mine(this.param.id);
      await this.refreshSoft();
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.rescueBusy = false;
    }
  }

  private dismissRescue(): void {
    Haptics.soft();
    Outbox.clear(this.param.id);
    this.rescue = [];
  }

  private async send(steerNow: boolean = false): Promise<void> {
    const text: string = this.draft.trim();
    if ((text === '' && !this.hasPend()) || this.sending) return;
    this.attachOn = false;
    this.slashOpened = false;
    const runningNow: boolean = this.running;
    const mode: string = steerNow ? 'steer' : 'queue';
    const idem: string = this.pendingKey !== '' ? this.pendingKey : Api.newIdemKey();
    this.pendingKey = idem;
    const route: string = (this.pendImgs.length > 0 || this.pendFiles.length > 0) ? 'outbox' : 'send';
    if (!Net.isOnline()) {
      if (!stashOfflineSend(this.param.id, text, this.pendImgs, this.pendFiles, idem)) return;
      this.rescue = Outbox.mine(this.param.id);
      this.draft = '';
      Drafts.set(this.param.id, '');
      this.pendImgs = [];
      this.pendFiles = [];
      this.pendH = 0;
      return;
    }
    Haptics.soft();
    this.sending = true;
    const imgs: ImagePart[] = this.pendImgs;
    const files: FilePart[] = this.pendFiles;
    this.draft = '';
    Drafts.set(this.param.id, '');
    try {
      await dispatchOnlineSend(this.api, this.param.id, text, imgs, files, mode, idem, runningNow);
      this.pendImgs = [];
      this.pendFiles = [];
      if (this.queueItems.length === 0) this.pendH = 0;
      this.pendingKey = '';
      this.atBottom = true;
      await this.refreshSoft();
      setTimeout(() => { if (this.alive) this.scroller.scrollEdge(Edge.Bottom); }, 60);
    } catch (e) {
      this.err = (e as Error).message;
      this.retryText = text;
      this.showErrCard('', this.err, Date.now());
      if (text !== '' || imgs.length > 0) {
        if (Outbox.remember(this.param.id, text, toStashImages(imgs), idem, route)) {
          this.rescue = Outbox.mine(this.param.id);
        } else {
          Toast.err('消息没能存到手机本地，请检查存储空间后再重试');
        }
      }
    } finally {
      this.sending = false;
    }
  }

  private async doStop(): Promise<void> {
    try {
      const ok: boolean = await this.api.stop(this.param.id);
      if (!ok) this.err = '这一轮已经不在了，或服务端没有受理';
      await this.refreshSoft();
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async pickAttach(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) { Toast.ok('一次最多 9 个附件'); return; }
      const parts: ImagePart[] = await pickImages(room);
      if (parts.length > 0) {
        this.pendImgs = this.pendImgs.concat(parts);
        Haptics.tap();
        this.err = '';
      }
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async pickAttachFile(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) { Toast.ok('一次最多 9 个附件'); return; }
      const parts: FilePart[] | null = await pickLocalFileParts(room);
      if (parts === null) return;
      if (parts.length === 0) { this.err = '选中的文件为空或超过 8 MB'; return; }
      this.pendFiles = this.pendFiles.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  private async pickCamera(): Promise<void> {
    if (this.sending) return;
    try {
      const room: number = 9 - this.pendImgs.length - this.pendFiles.length;
      if (room <= 0) { Toast.ok('一次最多 9 个附件'); return; }
      const parts: ImagePart[] | null = await captureCameraParts(AppCtx.ability());
      if (parts === null) return;
      if (parts.length === 0) { this.err = '拍到的照片读不出来'; return; }
      this.pendImgs = this.pendImgs.concat(parts);
      Haptics.tap();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    }
  }

  // ---------- 会话管理操作（F05 / I3） ----------

  private async doRename(rawTitle: string): Promise<void> {
    const t: string = rawTitle.trim();
    if (t === '') { this.err = '名字不能为空'; return; }
    try {
      await this.api.rename(this.param.id, t);
      this.titleNow = t;
      this.renaming = false;
      this.err = '';
      AppStorage.setOrCreate('listDirty', Date.now());
      Toast.ok('已重命名会话');
    } catch (e) {
      Toast.err('重命名失败：' + (e as Error).message);
    }
  }

  private async togglePinSession(): Promise<void> {
    const nextPinned: boolean = !this.pinned;
    if (await toggleSessionPinState(this.api, this.param.id, nextPinned)) this.pinned = nextPinned;
  }

  private async archiveCurrentSession(): Promise<void> {
    Haptics.soft();
    if (await archiveSessionNow(this.api, this.param.id) && this.stack.size() >= 1) this.stack.pop();
  }

  private async forkWholeSession(): Promise<void> {
    await forkSessionNow(this.api, this.param.id, -1, '已分支新会话，返回列表可查看');
  }

  private async forkAt(m: Message): Promise<void> {
    const at: number = m.turn !== undefined ? m.turn.atSeq : m.seq;
    Haptics.tap();
    await forkSessionNow(this.api, this.param.id, at, '已分叉，回列表可看到新会话');
  }

  private async exportMd(): Promise<void> {
    try {
      const ok: boolean = await saveSessionMarkdown(AppCtx.ability(), this.titleNow, this.param.id, this.msgs);
      if (ok) Toast.ok('已导出 Markdown');
    } catch (e) {
      Toast.err('导出失败：' + (e as Error).message);
    }
  }

  private quoteMessage(m: Message): void {
    const t: string = m.text.trim();
    if (t === '') return;
    const quote: string = t.split('\n').slice(0, 6).map((x: string) => '> ' + x).join('\n');
    this.draft = this.draft === '' ? quote + '\n\n' : this.draft + '\n' + quote + '\n\n';
    Drafts.set(this.param.id, this.draft);
  }

  private jumpToMessage(m: Message): void {
    let idx: number = 0;
    for (let i = 0; i < this.msgs.length; i++) {
      if (this.msgs[i].seq === m.seq) { idx = i; break; }
    }
    this.searchOn = false;
    const off: number = this.hasMore ? 2 : 1;
    setTimeout(() => {
      try { this.scroller.scrollToIndex(idx + off); } catch (e) {}
    }, 120);
  }

  private openExtras(mode: string): void {
    this.hideKb();
    this.extrasMode = mode;
  }

  // ---------- 辅助计算与缓存 ----------

  private immersiveOn(): boolean {
    return this.hdsOn && Mat.isImmersiveReady();
  }

  private sessionBackend(): string {
    return backendIdOfSession(this.param.id);
  }

  private sessionCaps(): BackendCapabilities {
    return this.backendCaps;
  }

  private async loadBackendCaps(): Promise<void> {
    const g: number = this.gen;
    const bid: string = this.sessionBackend();
    try {
      const rows: BackendInfo[] = await this.api.backends(false);
      if (!this.alive || g !== this.gen) return;
      for (let i = 0; i < rows.length; i++) {
        if (rows[i].id === bid && rows[i].capabilities !== undefined) {
          this.backendCaps = rows[i].capabilities!;
          return;
        }
      }
    } catch (e) {
      // 保留按智能体 ID 推导的默认能力
    }
  }

  private isExternalBackend(): boolean {
    return this.sessionBackend() !== 'dsh';
  }

  private headerSubtitle(): string {
    const linkTag: string = formatLinkBadge(this.online, this.linkMode, this.linkEncrypted);
    const engineTag: string = this.isExternalBackend() ? (backendLabelOf(this.sessionBackend()) + ' · ') : '';
    if (this.curModel !== '') {
      return this.curModel + ' · ' + engineTag + linkTag;
    }
    if (this.loading) {
      return '拉取中… · ' + engineTag + linkTag;
    }
    return engineTag + linkTag;
  }

  private listTopSpacerHeight(): number {
    return this.topInset + 72 + (this.agents.length > 0 ? 44 : 0);
  }

  private inputBottomPad(): number {
    return this.kbH > 0 ? (this.kbH + 10) : Math.max(20, this.bottomInset + 6);
  }

  /** 列表底部真实占位高度：贴合底部输入总成实际高度，避免拉到底后与输入框间留出大块空白 */
  private listBottomSpacerHeight(): number {
    const dockH: number = this.bottomStackH > 0
      ? this.bottomStackH
      : ((this.inputH > 0 ? this.inputH : 108) + this.pendH);
    return dockH + this.inputBottomPad() + 6;
  }

  private ctxUsed(): number {
    return this.ctx === null ? 0 : this.ctx.used;
  }

  private ctxWindow(): number {
    return this.ctx === null || this.ctx.window <= 0 ? 128000 : this.ctx.window;
  }

  private ctxPct(): number {
    if (this.ctx === null) return 0;
    return Math.min(100, Math.round((this.ctxUsed() * 100) / this.ctxWindow()));
  }

  private blocksOf(m: Message): MdBlock[] {
    const head: string = m.text.length > 8 ? m.text.slice(0, 8) : m.text;
    const tail: string = m.text.length > 8 ? m.text.slice(m.text.length - 8) : '';
    const key: string = String(m.seq) + ':' + String(m.text.length) + ':' + head + ':' + tail;
    const hit: MdBlock[] | undefined = this.mdCache.get(key);
    if (hit !== undefined) return hit;
    const blocks: MdBlock[] = parseMd(m.text);
    if (this.mdCache.size > 160) this.mdCache.clear();
    this.mdCache.set(key, blocks);
    return blocks;
  }

  private shouldAnimateBubble(m: Message): boolean {
    if (m.seq <= this.initialMaxSeq || this.seenSeqs.has(m.seq)) return false;
    this.seenSeqs.add(m.seq);
    return true;
  }

  private showErrCard(code: string, text: string, at: number): void {
    if (text === '') return;
    this.errCardCode = code;
    this.errCard = text;
    console.info('DSH_ERRCARD code=' + code + ' len=' + String(text.length) + ' at=' + String(at));
  }

  private dismissErrCard(): void {
    this.errCard = '';
    this.errCardCode = '';
  }

  private takeLastErr(le: TurnErr | null | undefined): void {
    if (this.running) {
      if (this.errCard !== '') this.dismissErrCard();
      return;
    }
    if (le === undefined || le === null || le.text === '' || le.text === this.errCard) return;
    let lastMark: number = 0;
    for (let i = 0; i < this.msgs.length; i++) {
      if (this.msgs[i].time > lastMark) lastMark = this.msgs[i].time;
    }
    if (lastMark > 0 && le.time > 0 && le.time < lastMark) {
      if (this.errCard !== '') this.dismissErrCard();
      return;
    }
    this.showErrCard(le.code, le.text, le.time);
  }

  // ---------- 视图局部 Builder ----------

  @Builder
  private modelSheetBuilder() {
    ModelPickerSheet({
      groups: this.groups,
      groupsLoaded: this.groupsLoaded,
      curModelId: this.curModelId,
      curModel: this.curModel,
      curEffort: this.curEffort,
      pickingId: this.pickingModelId,
      allowTeam: !this.isExternalBackend(),
      teamOn: this.teamOn,
      teamBusy: this.teamBusy,
      onToggleTeam: (v: boolean): void => { void this.setTeamMode(v); },
      onPick: (groupId: string, modelId: string, effort: string, effortOnly: boolean): void => {
        void this.pickModel(groupId, modelId, effort, effortOnly);
      },
      onClose: (): void => { this.modelOn = false; }
    })
  }

  @Builder
  private statsSheetBuilder() {
    ChatStatsSheet({
      hasCtx: this.ctx !== null,
      ctxUsed: this.ctx !== null ? this.ctx.used : 0,
      ctxWindow: this.ctx !== null ? this.ctx.window : 0,
      hasStats: this.stats !== null,
      stats: this.stats !== null ? this.stats : EMPTY_STATS,
      msgs: this.msgs,
      hasMore: this.hasMore,
      curModel: this.curModel,
      refreshing: this.statsRefreshing,
      onRefresh: (): void => { void this.refreshSoft(); },
      onClose: (): void => { this.statsOn = false; }
    })
  }

  @Builder
  private goalSheetBuilder() {
    GoalSheet({
      hasGoal: this.goal !== null,
      goal: this.goal !== null ? this.goal : EMPTY_GOAL,
      busy: this.goalBusy,
      kbH: this.kbH,
      onCreate: (objective: string, maxRounds: number): Promise<boolean> => this.createGoal(objective, maxRounds),
      onAction: (action: string): void => { void this.actGoal(action); },
      onSaveEdit: (objective: string): Promise<boolean> => this.saveGoalEdit(objective),
      onClose: (): void => { this.goalOn = false; }
    })
  }

  @Builder
  private selectSheetBuilder() {
    MessageSelectSheet({
      text: this.menuMsg === null ? '' : this.menuMsg.text,
      onQuote: (): void => {
        const target: Message | null = this.menuMsg;
        this.msgMenuOn = false;
        if (target !== null) this.quoteMessage(target);
      },
      onClose: (): void => { this.msgMenuOn = false; }
    })
  }

  @Builder
  private renameSheetBuilder() {
    RenameSessionSheet({
      initialTitle: this.titleNow,
      kbH: this.kbH,
      onSave: (title: string): void => { void this.doRename(title); },
      onCancel: (): void => { this.renaming = false; }
    })
  }

  @Builder
  private permSheetBuilder() {
    PermPickerSheet({
      loading: this.permLoading,
      unavailable: this.permUnavailable,
      presets: this.permPresets,
      current: this.permCurrent,
      savingVal: this.permSaving,
      onPick: (val: string): void => { void this.pickPermission(val); },
      onOpenFullPresets: (): void => { this.openPresetsPage(); },
      onClose: (): void => { this.permOn = false; }
    })
  }

  @Builder
  private feedbackSheetBuilder() {
    FeedbackQuickSheet({
      busy: this.fbQuickBusy,
      kbH: this.kbH,
      onSubmit: (category: string, content: string): Promise<boolean> => this.submitQuickFeedback(category, content),
      onClose: (): void => { this.fbQuickOn = false; }
    })
  }

  @Builder
  private chatMenuBuilder() {
    ChatMenuPopup({
      pinned: this.pinned,
      backendId: this.sessionBackend(),
      caps: this.sessionCaps(),
      onOpenExtras: (mode: string): void => { this.openExtras(mode); },
      onStartRename: (): void => { this.hideKb(); this.renaming = true; },
      onTogglePin: (): void => { void this.togglePinSession(); },
      onForkSession: (): void => { void this.forkWholeSession(); },
      onOpenSearch: (): void => {
        this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
          this.searchOn = true;
        });
      },
      onExportMd: (): void => { void this.exportMd(); },
      onOpenPresets: (): void => { this.openPresetsPage(); },
      onOpenWebConsole: (): void => { this.hideKb(); this.webConsoleOn = true; },
      onRefresh: (): void => { void this.refreshSoft(); },
      onArchive: (): void => { void this.archiveCurrentSession(); },
      onDismiss: (): void => { this.menuOn = false; }
    })
  }

  private openBigImg(url: string, geoId: string): void {
    if (Motion.isVivid(this.motionMode) && geoId !== '') {
      this.bigImgGeoId = geoId;
      this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
        this.bigImg = url;
      });
    } else {
      this.bigImgGeoId = '';
      this.bigImg = url;
    }
  }

  private buildComposerEffect(): VisualEffect {
    if (!this.hdsOn) {
      const offLight: hdsEffect.PointLightEffect = {
        sourceType: hdsEffect.PointLightSourceType.NONE,
        illuminatedType: hdsEffect.PointLightIlluminatedType.NONE
      };
      return new hdsEffect.HdsEffectBuilder()
        .pointLight(offLight)
        .pressShadow(hdsEffect.PressShadowType.NONE)
        .buildEffect();
    }
    const lightOpts: hdsEffect.PointLightOptions = {
      color: this.themeDark ? '#CCFFFFFF' : '#FFFFFFFF',
      intensity: this.composerPressed ? 1.45 : 0.92,
      height: 46,
      bloom: this.composerPressed ? 0.85 : 0.42
    };
    const lightEff: hdsEffect.PointLightEffect = {
      sourceType: hdsEffect.PointLightSourceType.BRIGHT,
      illuminatedType: hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER,
      options: lightOpts
    };
    return new hdsEffect.HdsEffectBuilder()
      .pointLight(lightEff)
      .pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT)
      .buildEffect();
  }

  @Builder
  private composerGlowOverlay() {
    Stack() {
      // 1. 沉浸光感非均一折射高光与顶边晶体棱线
      if (this.hdsOn) {
        Row()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 155,
            colors: this.themeDark
              ? [['#29FFFFFF', 0.0], ['#0AFFFFFF', 0.34], ['#00FFFFFF', 0.68], ['#1494B8FF', 1.0]]
              : [['#78FFFFFF', 0.0], ['#24FFFFFF', 0.38], ['#00FFFFFF', 0.72], ['#1A3B6EF6', 1.0]]
          })
          .hitTestBehavior(HitTestMode.None)

        Row()
          .width('86%')
          .height(1)
          .linearGradient({
            angle: 90,
            colors: [
              ['#00FFFFFF', 0.0],
              [this.themeDark ? '#5CFFFFFF' : '#E6FFFFFF', 0.5],
              ['#00FFFFFF', 1.0]
            ]
          })
          .position({ x: '7%', y: 0 })
          .hitTestBehavior(HitTestMode.None)

        // 2. 点击跟手径向高光晕染
        Row()
          .width('100%')
          .height('100%')
          .radialGradient({
            center: [String(this.composerTouchXPct) + '%', String(this.composerTouchYPct) + '%'],
            radius: 150,
            colors: this.themeDark
              ? [['#42FFFFFF', 0.0], ['#1CA6C8FF', 0.42], ['#00FFFFFF', 1.0]]
              : [['#85FFFFFF', 0.0], ['#303B6EF6', 0.42], ['#00FFFFFF', 1.0]]
          })
          .opacity(this.composerPressed ? 1 : 0)
          .animation(Motion.flagshipSnappy())
          .hitTestBehavior(HitTestMode.None)
      }

      // 3. AI 回复中双边流光
      if (this.running && Motion.isVivid(this.motionMode)) {
        AiFlowGlow({ radius: Tokens.rCard, glowOpacity: 0.58 })
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** HDS 标题栏内容：放回 HdsNavDestination.titleBar 以激活 HarmonyOS 6 真实沉浸光感材质，并保持四控件单行水平居中对齐 */
  @Builder
  private headerPadded() {
    Column() {
      Column() {
        Row({ space: 9 }) {
          HeaderCirclePill({
            glyph: 'back',
            immersive: this.immersiveOn(),
            onTap: (): void => { this.stack.pop(); }
          })
            .accessibilityText('返回')
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(Motion.headerPopOpacityAnim(125, this.motionMode))
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_BACK_X })
            .scale({
              x: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              y: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              centerX: '0%',
              centerY: '50%'
            })
            .animation(Motion.headerPopScaleAnim(125, this.motionMode))

          HeaderTitleCapsule({
            title: this.titleNow !== '' ? this.titleNow : '会话',
            subtitle: this.headerSubtitle(),
            linkState: resolveLinkState(this.online, this.linkMode),
            immersive: this.immersiveOn(),
            onTap: (): void => {
              if (!this.sessionCaps().modelSwitch) return;
              this.hideKb();
              this.openModels();
            }
          })
            .layoutWeight(1)
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(Motion.headerPopOpacityAnim(115, this.motionMode))
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_TITLE_X })
            .scale({
              x: this.hdrEntered ? 1 : Motion.HEADER_TITLE_SCALE_START,
              y: this.hdrEntered ? 1 : Motion.HEADER_TITLE_SCALE_START,
              centerX: '0%',
              centerY: '50%'
            })
            .animation(Motion.headerTitleSlideAnim(115, this.motionMode))

          HeaderCirclePill({
            glyph: 'stats',
            immersive: this.immersiveOn(),
            onTap: (): void => { this.hideKb(); this.statsOn = true; }
          })
            .accessibilityText('上下文与统计')
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(Motion.headerPopOpacityAnim(155, this.motionMode))
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_RIGHT_X })
            .scale({
              x: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              y: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              centerX: '0%',
              centerY: '50%'
            })
            .animation(Motion.headerPopScaleAnim(155, this.motionMode))

          HeaderCirclePill({
            glyph: '···',
            immersive: this.immersiveOn(),
            onTap: (): void => { this.hideKb(); this.menuOn = true; }
          })
            .accessibilityText('更多菜单')
            .animation(null)
            .opacity(this.hdrEntered ? 1 : 0)
            .animation(Motion.headerPopOpacityAnim(125, this.motionMode))
            .translate({ x: this.hdrEntered ? 0 : Motion.HEADER_SLIDE_RIGHT_OUTER_X })
            .scale({
              x: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              y: this.hdrEntered ? 1 : Motion.HEADER_BTN_SCALE_START,
              centerX: '0%',
              centerY: '50%'
            })
            .animation(Motion.headerPopScaleAnim(125, this.motionMode))
            .bindPopup(this.menuOn, Mat.popupOpts(
              this.hdsOn,
              (): void => { this.chatMenuBuilder(); },
              Placement.BottomRight,
              { x: 0, y: 6 },
              (vis: boolean): void => { if (!vis) this.menuOn = false; },
              20,
              Motion.popupMenuTransition(this.motionMode, true)
            ))
        }
        .width('100%')
        .height(50)
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14 })

        if (this.agents.length > 0) {
          SubagentStrip({ agents: this.agents })
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: this.wideScreen ? 760 : 9999 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: this.topInset + 10, bottom: 8 })
  }

  private hdsTitle(): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => { this.headerPadded(); };
    return buildTransparentHdsTitle(stack);
  }

  // ---------- 主构建树 ----------

  build() {
    HdsNavDestination() {
      Stack({ alignContent: Alignment.Top }) {
        // 底色层
        Row()
          .width('100%')
          .height('100%')
          .backgroundColor(this.themeBg)
          .hitTestBehavior(HitTestMode.None)

        if (this.loading && this.msgs.length === 0) {
          Column() {
            LoadingProgress().width(46).height(46).color(Tokens.accent)
            Text('正在拉取会话…').fontSize(Tokens.fsFoot).fontColor(Tokens.dim).margin({ top: 10 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .zIndex(5)
          .hitTestBehavior(HitTestMode.None)
          .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
        }

        // 消息流列表（L4 宽屏/折叠屏居中限宽 760vp）
        List({ space: 0, scroller: this.scroller }) {
          ListItem() { Row().width('100%').height(this.listTopSpacerHeight()) }

          if (this.hasMore) {
            ListItem() {
              Row() {
                Text(this.loadingMore ? '正在取更早的消息…' : '↑ 加载更早的消息')
                  .fontSize(Tokens.fsBody)
                  .fontColor(this.loadingMore ? Tokens.dim2 : Tokens.accent)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 6, bottom: 16 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
              .onClick(() => { void this.loadOlder(); })
            }
          }

          if (!this.loading && this.msgs.length === 0) {
            ListItem() {
              Column() {
                ChatEmptyWelcome()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
          }

          ForEach(this.msgs, (m: Message, i: number) => {
            ListItem() {
              Column() {
                Column() {
                  if (i === 0 || !sameDay(this.msgs[i - 1].time, m.time)) {
                    Text(dayLabel(m.time))
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.dim2)
                      .backgroundColor(Tokens.chip)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .margin({ top: 10, bottom: 8 })
                  }
                  ChatBubbleItem({
                    msg: m,
                    blocks: m.text !== '' ? this.blocksOf(m) : [],
                    isStreaming: this.running && i === this.msgs.length - 1,
                    canFork: this.sessionCaps().fork,
                    api: this.api,
                    onPreviewImage: (url: string, geoId: string): void => { this.openBigImg(url, geoId); },
                    onFork: (target: Message): void => { void this.forkAt(target); },
                    onLongPress: (target: Message): void => {
                      this.menuMsg = target;
                      this.msgMenuOn = true;
                    }
                  })
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .constraintSize({ maxWidth: this.wideScreen ? 760 : 9999 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
            .transition(this.shouldAnimateBubble(m)
              ? Motion.bubbleTransition(this.motionMode)
              : TransitionEffect.IDENTITY)
          }, (m: Message) => buildMsgForEachKey(m))

          if (this.running) {
            ListItem() {
              Column() {
                Column() {
                  TypingBubble({ active: this.dotOn })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .constraintSize({ maxWidth: this.wideScreen ? 760 : 9999 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
            .transition(Motion.panelTransition(this.motionMode))
          }

          if (this.errCard !== '') {
            ListItem() {
              Column() {
                Column() {
                  ChatErrorCard({
                    errText: this.errCard,
                    errCode: this.errCardCode,
                    hasRetry: this.retryText !== '',
                    onRetry: (): void => {
                      const t: string = this.retryText;
                      this.retryText = '';
                      this.dismissErrCard();
                      this.draft = t;
                      void this.send();
                    },
                    onDismiss: (): void => { this.dismissErrCard(); }
                  })
                }
                .width('100%')
                .constraintSize({ maxWidth: this.wideScreen ? 760 : 9999 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Center)
            }
          }

          ListItem() { Row().width('100%').height(this.listBottomSpacerHeight()) }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 14, right: 14 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onDidScroll(() => { try { this.atBottom = this.scroller.isAtEnd(); } catch (e) {} })
        .hitTestBehavior(HitTestMode.Transparent)

        // 顶部柔和渐隐/非沉浸回退衬板（四枚顶栏控件已归位至 HdsNavDestination.titleBar 以启用真实沉浸光感）
        if (!this.bigEditOn && this.extrasMode === '' && !this.searchOn && !this.webConsoleOn) {
          ChatTopBackdrop({
            immersive: this.immersiveOn(),
            topInset: this.topInset
          })
        }

        // 底部输入总成（L4 居中限宽 760vp）
        Stack({ alignContent: Alignment.Bottom }) {
          Row()
            .width('100%')
            .height(this.hdsOn ? (this.inputBottomPad() + 18) : (this.pendH + 210 + this.inputBottomPad()))
            .linearGradient({
              angle: 180,
              colors: this.hdsOn
                ? [
                    ['#00' + (this.themeBg.startsWith('#') ? this.themeBg.slice(1) : this.themeBg), 0.0],
                    ['#CC' + (this.themeBg.startsWith('#') ? this.themeBg.slice(1) : this.themeBg), 1.0]
                  ]
                : [
                    ['#00' + (this.themeBg.startsWith('#') ? this.themeBg.slice(1) : this.themeBg), 0.0],
                    [this.themeBg, 0.72],
                    [this.themeBg, 1.0]
                  ]
            })
            .hitTestBehavior(HitTestMode.None)

          Column() {
            Column() {
              if (this.err !== '') {
                Text(this.err)
                  .fontSize(Tokens.fsFoot)
                  .fontColor(Tokens.err)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding({ left: 4, bottom: 6 })
              }

              if (this.asks.length > 0) {
                Column({ space: 6 }) {
                  ForEach(this.asks, (a: PendingAsk) => {
                    AskQuestionCard({
                      ask: a,
                      onSubmit: (callId: string, answers: AskAnswer[]): void => {
                        void this.submitAskAnswers(callId, answers);
                      }
                    })
                  }, (a: PendingAsk) => a.callId + '_' + String(a.questions.length))
                }
                .width('100%')
                .margin({ bottom: 8 })
              }

              if (this.rescue.length > 0) {
                OutboxRescueCard({
                  count: this.rescue.length,
                  firstText: this.rescue[0].text,
                  busy: this.rescueBusy,
                  onResend: (): void => { void this.resendRescue(); },
                  onDismiss: (): void => { this.dismissRescue(); }
                })
              }

              if (this.pendFiles.length + this.queueItems.length > 0) {
                PendingBoard({
                  rows: buildPendRows(this.pendFiles, this.queueItems),
                  cardH: this.pendCardHeight(),
                  onFire: (r: PendRow): void => { this.fireRow(r); },
                  onEdit: (r: PendRow): void => {
                    const q: QueuedItem | null = this.queueById(r.id);
                    if (q !== null) this.doQueueEdit(q);
                  },
                  onRemove: (r: PendRow): void => { this.dropRow(r); },
                  onMove: (from: number, to: number): void => { this.pendMove(from, to); },
                  onHeight: (h: number): void => {
                    if (Math.abs(h - this.pendH) > 1) {
                      this.pendH = h;
                      if (h > 0 && this.atBottom) {
                        setTimeout(() => {
                          if (this.alive) this.scroller.scrollEdge(Edge.Bottom);
                        }, 40);
                      }
                    }
                  }
                })
              }

              if (this.planActive) {
                PlanModeBanner({
                  busy: this.planBusy,
                  onClose: (): void => { void this.togglePlanMode(false); }
                })
              }

              if (this.cmdBusyText !== '' && !this.attachOn) {
                Row({ space: 8 }) {
                  LoadingProgress().width(14).height(14).color(Tokens.accent)
                  Text(this.cmdBusyText)
                    .fontSize(Tokens.fsCaption)
                    .fontColor(Tokens.accent)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                .margin({ bottom: 8 })
                .borderRadius(Tokens.rMd)
                .backgroundColor(Tokens.accentSoft)
              }

              Column() {
                if (this.pendImgs.length > 0) {
                  PendingImages({
                    images: this.pendImgs,
                    onPreview: (d: string, geoId: string): void => { this.openBigImg(d, geoId); },
                    onRemove: (i: number): void => { this.dropImg(i); }
                  })
                }

                if (this.attachOn) {
                  AttachMenu({
                    planActive: this.planActive,
                    hasGoal: this.goal !== null,
                    hostCommands: this.hostCommands,
                    filterPrefix: this.currentSlashFilter(),
                    cmdBusyText: this.cmdBusyText,
                    backendId: this.sessionBackend(),
                    caps: this.sessionCaps(),
                    showFeedback: isFeedbackEnabled(),
                    onCamera: (): void => { this.attachOn = false; this.clearSlashDraftIfNeeded(); void this.pickCamera(); },
                    onPhotos: (): void => { this.attachOn = false; this.clearSlashDraftIfNeeded(); void this.pickAttach(); },
                    onFiles: (): void => { this.attachOn = false; this.clearSlashDraftIfNeeded(); void this.pickAttachFile(); },
                    onGoal: (): void => { this.attachOn = false; this.clearSlashDraftIfNeeded(); this.hideKb(); this.openGoal(); },
                    onTogglePlan: (): void => {
                      this.attachOn = false;
                      this.clearSlashDraftIfNeeded();
                      void this.togglePlanMode(!this.planActive);
                    },
                    onFeedback: (): void => {
                      this.attachOn = false;
                      this.clearSlashDraftIfNeeded();
                      this.hideKb();
                      this.fbQuickOn = true;
                    },
                    onSelectCommand: (cmd: SlashCommandRow): void => {
                      this.handleSlashCommand(cmd);
                    }
                  })
                }

                Row() {
                  TextArea({ placeholder: '发消息，或输入 / 呼出指令…', text: this.draft })
                    .placeholderColor(Tokens.dim2)
                    .fontColor(Tokens.fg)
                    .fontSize(Tokens.fsBodyLg)
                    .lineHeight(21)
                    .padding({ left: 12, right: 4, top: 12, bottom: 12 })
                    .backgroundColor(Color.Transparent)
                    .layoutWeight(1)
                    .constraintSize({ minHeight: 46, maxHeight: 87 })
                    .barState(BarState.Auto)
                    .enterKeyType(this.enterSend ? EnterKeyType.Send : EnterKeyType.NEW_LINE)
                    .onChange((v: string) => {
                      const prev: string = this.draft;
                      this.draft = v;
                      this.pendingKey = '';
                      Drafts.set(this.param.id, v);
                      if (prev === '' && v === '/') {
                        this.slashOpened = true;
                        void this.loadHostCommands();
                        this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
                          this.attachOn = true;
                        });
                      } else if (this.slashOpened && (!v.startsWith('/') || v.indexOf(' ') >= 0 || v.indexOf('\n') >= 0)) {
                        this.slashOpened = false;
                        this.attachOn = false;
                      }
                    })
                    .onSubmit(() => {
                      if (this.enterSend) void this.send();
                    })

                  Row() {
                    Image($r('app.media.ic_expand')).width(18).height(18).fillColor(Tokens.dim).draggable(false)
                  }
                  .width(40)
                  .height(40)
                  .justifyContent(FlexAlign.Center)
                  .margin({ left: 2, right: 6 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                  .accessibilityText('展开编辑')
                  .onClick(() => {
                    Haptics.tap();
                    this.queueEditId = '';
                    this.bigEditOn = true;
                  })
                }
                .width('100%')

                Row() {
                  if (this.sessionCaps().goalMode) {
                    ContextPill({
                      hasCtx: this.ctx !== null,
                      pct: this.ctxPct(),
                      onTap: (): void => {
                        this.hideKb();
                        this.statsOn = true;
                      }
                    })

                    Stack() {
                      Image($r('app.media.ic_goal'))
                        .width(17)
                        .height(17)
                        .fillColor(this.goal !== null ? Tokens.accent : Tokens.dim)
                    }
                    .width(30)
                    .height(30)
                    .margin({ left: 8 })
                    .borderRadius(Tokens.rPill)
                    .backgroundColor(this.goal !== null ? Tokens.accentSoft : Color.Transparent)
                    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
                    .accessibilityText('长期目标')
                    .onClick(() => {
                      Haptics.tap();
                      this.hideKb();
                      this.openGoal();
                    })
                  } else {
                    Text(backendLabelOf(this.sessionBackend()))
                      .fontSize(Tokens.fsCaption)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tokens.accent)
                      .backgroundColor(Tokens.accentSoft)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                      .onClick(() => {
                        Haptics.tap();
                        this.hideKb();
                        this.statsOn = true;
                      })
                  }

                  Blank()

                  ComposerSendCluster({
                    running: this.running,
                    sending: this.sending,
                    hasContent: this.draft.trim() !== '' || this.hasPend(),
                    attachOn: this.attachOn,
                    onToggleAttach: (): void => {
                      if (!this.attachOn) {
                        void this.loadHostCommands();
                      }
                      this.slashOpened = false;
                      this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
                        this.attachOn = !this.attachOn;
                      });
                    },
                    onSendNormal: (): void => { void this.send(false); },
                    onSendQueue: (): void => { void this.send(false); },
                    onSendSteer: (): void => { void this.send(true); },
                    onStop: (): void => { void this.doStop(); }
                  })
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .padding({ top: 6, bottom: 6 })
              .backgroundColor(this.hdsOn ? Color.Transparent : Tokens.surface)
              .backgroundEffect(Mat.glassEffect(this.hdsOn, this.attachOn || this.pendImgs.length > 0))
              .visualEffect(this.buildComposerEffect())
              .borderRadius(Tokens.rCard)
              .border(Mat.glassRimBorder(this.hdsOn))
              .shadow(Mat.glassFloatShadow(this.hdsOn))
              .overlay(this.composerGlowOverlay())
              .clip(true)
              .onTouch((e: TouchEvent) => {
                if (!this.hdsOn) {
                  return;
                }
                if (e.touches !== undefined && e.touches.length > 0) {
                  const w: number = this.composerW > 40 ? this.composerW : 340;
                  const h: number = this.composerH > 30 ? this.composerH : 104;
                  const xp: number = Math.round(Math.max(5, Math.min(95, (e.touches[0].x / w) * 100)));
                  const yp: number = Math.round(Math.max(5, Math.min(95, (e.touches[0].y / h) * 100)));
                  this.composerTouchXPct = xp;
                  this.composerTouchYPct = yp;
                }
                if (e.type === TouchType.Down) {
                  this.composerPressed = true;
                } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
                  this.composerPressed = false;
                }
              })
              .onAreaChange((oldValue: Area, newValue: Area) => {
                const w: number = Number(newValue.width);
                const h: number = Number(newValue.height);
                if (w > 40) this.composerW = w;
                if (h > 0 && Math.abs(h - this.inputH) > 1) this.inputH = h;
                if (h > 0) this.composerH = h;
              })
            }
            .width('100%')
            .constraintSize({ maxWidth: this.wideScreen ? 760 : 9999 })
            .onAreaChange((_oldVal: Area, newVal: Area) => {
              const h: number = Number(newVal.height);
              if (h > 0 && Math.abs(h - this.bottomStackH) > 1) this.bottomStackH = h;
            })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 16, right: 16, top: 12, bottom: this.inputBottomPad() })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)

        if (!this.atBottom) {
          ScrollBottomFab({
            bottomOffset: this.inputBottomPad() + (this.bottomStackH > 0 ? this.bottomStackH : this.inputH) + 12,
            onTap: (): void => {
              this.scroller.scrollEdge(Edge.Bottom);
              this.atBottom = true;
            }
          })
        }

        if (this.extrasMode !== '') {
          ExtrasPanel({
            mode: this.extrasMode,
            sessionId: this.param.id,
            api: this.api,
            onExit: (): void => { this.extrasMode = ''; }
          })
        }

        if (this.webConsoleOn) {
          WebConsolePage({
            api: this.api,
            hostName: Machines.displayName(),
            onExit: (): void => { this.webConsoleOn = false; }
          })
        }

        if (this.bigEditOn) {
          BigEditorOverlay({
            isQueueEdit: this.queueEditId !== '',
            text: this.queueEditId === '' ? this.draft : this.editBuf,
            canSendAttach: this.hasPend(),
            kbH: this.kbH,
            onTextChange: (v: string): void => {
              if (this.queueEditId !== '') {
                this.editBuf = v;
              } else {
                this.draft = v;
                this.pendingKey = '';
                Drafts.set(this.param.id, v);
              }
            },
            onSend: (): void => { this.bigEditOn = false; void this.send(); },
            onSaveQueue: (): void => { void this.saveQueueEdit(); },
            onClose: (): void => {
              this.bigEditOn = false;
              this.queueEditId = '';
              this.editBuf = '';
            }
          })
        }

        if (this.searchOn) {
          ChatSearchOverlay({
            msgs: this.msgs,
            kbH: this.kbH,
            onJump: (m: Message): void => { this.jumpToMessage(m); },
            onClose: (): void => {
              this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
                this.searchOn = false;
              });
            }
          })
        }

        // 所有半模态统一挂载在页面底部独立零尺寸锚点上（F03 / F04 / F05 / F09）
        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.modelOn, this.modelSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, '72%', () => { this.modelOn = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.statsOn, this.statsSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, '72%', () => { this.statsOn = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.goalOn, this.goalSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.goalOn = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.msgMenuOn, this.selectSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, '88%', () => { this.msgMenuOn = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.renaming, this.renameSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.renaming = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.permOn, this.permSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.permOn = false; }))

        Row()
          .width(0)
          .height(0)
          .hitTestBehavior(HitTestMode.None)
          .bindSheet($$this.fbQuickOn, this.feedbackSheetBuilder(),
            Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.fbQuickOn = false; }))
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(this.bigEditOn || this.extrasMode !== '' || this.searchOn || this.webConsoleOn)
    .titleBar(this.hdsTitle())
    .padding({ top: 0 })
    .onBackPressed(() => {
      if (this.webConsoleOn) { this.webConsoleOn = false; return true; }
      if (this.extrasMode !== '') { this.extrasMode = ''; return true; }
      if (this.searchOn) { this.searchOn = false; return true; }
      if (this.bigEditOn) {
        this.bigEditOn = false;
        this.queueEditId = '';
        this.editBuf = '';
        return true;
      }
      if (this.attachOn) { this.attachOn = false; this.slashOpened = false; return true; }
      if (this.renaming) { this.renaming = false; return true; }
      if (this.menuOn) { this.menuOn = false; return true; }
      if (this.permOn) { this.permOn = false; return true; }
      if (this.fbQuickOn) { this.fbQuickOn = false; return true; }
      if (this.goalOn) { this.goalOn = false; return true; }
      if (this.msgMenuOn) { this.msgMenuOn = false; return true; }
      if (this.modelOn || this.statsOn) {
        this.modelOn = false;
        this.statsOn = false;
        return true;
      }
      if (this.stack.size() >= 1) { this.stack.pop(); return true; }
      return false;
    })
    .hideBackButton(true)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.themeBg)
    .mode(NavDestinationMode.STANDARD)
  }
}
