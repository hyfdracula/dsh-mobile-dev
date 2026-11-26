import preferences from '@ohos.data.preferences';
import { bundleManager } from '@kit.AbilityKit';
import { HdsNavDestination, HdsNavigationTitleBarOptions } from '@kit.UIDesignKit';
import { Api, ApiInfo, SessionRow } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK } from '../common/AppIcon';
import { PageHeader, TopFade, buildTransparentHdsTitle } from '../common/Chrome';
import { Haptics } from '../common/Haptics';
import { legalBodyOf, LegalDocKind, legalTitleOf } from '../common/LegalDocs';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID, SPEED_NORMAL } from '../common/Motion';
import { Pairing } from '../common/Pairing';
import { Toast } from '../common/Toast';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { Unread } from '../common/Unread';
import { AboutPanel, AboutRow } from './AboutPanel';
import { AgentPanel } from './AgentPanel';
import { AppearancePanel } from './AppearancePanel';
import { ConnectPanel } from './ConnectPanel';
import { DataStoragePanel } from './DataStoragePanel';
import { ExtrasPanel } from './ExtrasPanel';
import { FeedbackPage } from './FeedbackPage';
import { LegalSheet } from './LegalSheet';
import { NotifyPanel } from './NotifyPanel';
import { PairPage } from './PairPage';
import { StoragePage } from './StoragePage';
import { WebConsolePage } from './WebConsolePage';

interface NavRow {
  id: string;
  name: string;
  hint: string;
}

const AGENT_GROUP_ROWS: NavRow[] = [
  { id: 'agents', name: 'Agent 引擎与控制台', hint: '多智能体引擎、预设、插件与控制台' }
];

const PREF_GROUP_ROWS: NavRow[] = [
  { id: 'appearance', name: '外观与交互', hint: '主题、沉浸光感、应用图标与交互' },
  { id: 'notify', name: '通知', hint: '回合完成提醒与系统权限' }
];

const DATA_GROUP_ROWS: NavRow[] = [
  { id: 'data', name: '数据与存储', hint: '缓存空间、草稿与待发清理' },
  { id: 'about', name: '关于与协议', hint: '版本、诊断日志、隐私政策与开源许可' }
];

/**
 * 设置页信息架构协调器：
 * - 顶部单一 Hero 连接卡片（唯一「连接」入口）；
 * - 三大语义分组卡片：「电脑与智能体」、「偏好设置」、「数据与支持」；
 * - 底部静态版本号落款；二级/三级页由内部 subStack 承载。
 */
@Component
export struct SettingsPage {
  @Consume('stack') rootStack: NavPathStack;
  api: Api = new Api('', '');
  @Prop @Watch('onConnProp') wanBase: string = '';
  @Prop @Watch('onConnProp') token0: string = '';
  @Prop machineName: string = '';
  @Prop netMode: string = 'auto';
  @Prop autoLan: boolean = true;
  @Prop @Watch('onHapticsProp') haptics: boolean = true;
  @Prop @Watch('onHdsProp') hdsOn: boolean = true;
  themeMode: string = 'auto';
  systemDark: boolean = true;
  forceWan: boolean = false;
  defaultLan: string = '';

  onSave: (b: string, t: string) => void = () => {};
  onSaveLan: (b: string, t: string, lan: string[], hostId?: string, e2eePub?: string, hostName?: string) => void = () => {};
  onPickMachine: (id: string) => void = () => {};
  onRemoveMachine: (id: string) => void = () => {};
  onAddMachine: (wan: string, token: string, name: string) => void = () => {};
  onTheme: (m: string) => void = () => {};
  onNetMode: (m: string) => void = () => {};
  onHaptics: (v: boolean) => void = () => {};
  onHds: (v: boolean) => void = () => {};
  onWan: (v: boolean) => void = () => {};
  onAutoLan: (v: boolean) => void = () => {};
  onReset: () => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('machinesVer') machinesVer: number = 0;
  @StorageLink('settingsSub') sub: string = '';
  @StorageLink('settingsBack') @Watch('onSettingsBack') settingsBack: number = 0;
  @StorageLink('machineEpoch') @Watch('onMachineEpoch') machineEpoch: number = 0;
  @StorageLink('linkEncrypted') linkEncrypted: boolean = false;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('unreadCount') unreadCount: number = 0;
  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @StorageLink('motionMode') @Watch('onMotionModeChange') motionMode: string = MOTION_VIVID;
  @StorageLink('motionSpeed') motionSpeed: string = SPEED_NORMAL;
  @StorageLink('sheetOpen') sheetOpen: boolean = false;

  @State private pairEntry: string = '';
  @State private dataRefreshTick: number = 0;
  @State private legalKind: LegalDocKind = 'privacy';
  @State private legalOpen: boolean = false;
  @State private hapticsUi: boolean = true;
  @State private hdsUi: boolean = true;
  @State private enterSendUi: boolean = true;
  @State private compactHistoryUi: boolean = false;
  @State private textScaleUi: number = 1;

  // 灵动档旗舰悬浮卡片栈与景深虚化状态
  @State private sheetStack: string[] = [];
  @State private sheetMounted: boolean = false;
  @State private sheetOpenFactor: number = 0;
  @State private sheetDragY: number = 0;
  @State private sheetHFrac: number = 0.78;
  @State private subSlideFactor: number = 1;
  @State private subDragX: number = 0;
  @State private sheetW: number = 360;
  @State private pressedRowId: string = '';
  private suspendedSheet: string[] = [];
  private sheetCloseTimer: number = -1;
  private subPopTimer: number = -1;
  private modeSwitching: boolean = false;

  @State private info: ApiInfo | null = null;
  @State private base: string = '';
  @State private lan: boolean = false;
  @State private err: string = '';
  @State private loading: boolean = true;

  @State private editBase: string = '';
  @State private editToken: string = '';
  @State private saved: string = '';
  @State private saveErr: string = '';
  @State private saving: boolean = false;
  @State private saveStage: number = 0;
  @State private saveDetail: string = '';
  @State private saveElapsed: number = 0;

  @State private notifyDone: boolean = true;
  @State private notifyBgOnly: boolean = true;
  @State private verText: string = 'Agent Mobile';
  @State private answerMode: string = 'phone';
  @State private answerBusy: boolean = false;
  @State private devCount: number = -1;

  private linkTimer: number = -1;
  private saveTimer: number = -1;
  private subStack: NavPathStack = new NavPathStack();

  private onConnProp(): void {
    if (this.wanBase !== '') {
      this.editBase = this.wanBase;
    }
    if (this.token0 !== '') {
      this.editToken = this.token0;
    }
  }

  private onMachineEpoch(): void {
    this.editBase = this.wanBase;
    this.editToken = this.token0;
    this.saved = '';
    this.saveErr = '';
    void this.load();
    void this.loadDeviceCount();
  }

  private onHapticsProp(): void {
    if (this.hapticsUi !== this.haptics) {
      this.hapticsUi = this.haptics;
    }
  }

  private onHdsProp(): void {
    if (this.hdsUi !== this.hdsOn) {
      this.hdsUi = this.hdsOn;
    }
  }

  private syncSubFromStack(): void {
    const names: string[] = this.subStack.getAllPathName();
    if (names.length > 0) {
      this.sub = names[names.length - 1];
    } else if (this.sheetStack.length > 0) {
      this.sub = this.sheetStack[this.sheetStack.length - 1];
    } else {
      this.sub = '';
    }
  }

  private onMotionModeChange(): void {
    if (this.modeSwitching) {
      return;
    }
    this.modeSwitching = true;
    try {
      const wantFlagship: boolean = Motion.isFlagship(this.motionMode);
      if (wantFlagship) {
        // 经典 -> 灵动：若当前停留在二级面板（如外观与交互），原地切换为景深悬浮卡片栈
        const names: string[] = this.subStack.getAllPathName();
        const cur: string = names.length > 0 ? names[names.length - 1] : '';
        if (cur !== '' && !this.isFullScreenSub(cur)) {
          this.subStack.clear();
          this.openFloatingSheet(cur);
        }
      } else {
        // 灵动 -> 经典：若悬浮卡片栈开着，平滑切回经典整页 Navigation
        const top: string = this.sheetStack.length > 0 ? this.sheetStack[0] : '';
        if (this.sheetMounted || this.sheetStack.length > 0) {
          this.clearSheetTimers();
          this.sheetStack = [];
          this.sheetMounted = false;
          this.sheetOpenFactor = 0;
          this.sheetDragY = 0;
          this.subDragX = 0;
          this.subSlideFactor = 1;
          this.sheetOpen = false;
          if (top !== '' && !top.startsWith('legal:')) {
            this.subStack.pushPathByName(top, null);
          }
          this.syncSubFromStack();
        }
      }
    } finally {
      this.modeSwitching = false;
    }
  }

  private clearSheetTimers(): void {
    if (this.sheetCloseTimer >= 0) {
      clearTimeout(this.sheetCloseTimer);
      this.sheetCloseTimer = -1;
    }
    if (this.subPopTimer >= 0) {
      clearTimeout(this.subPopTimer);
      this.subPopTimer = -1;
    }
  }

  private sheetHeightFor(route: string): number {
    if (route === 'notify') return 0.56;
    if (route === 'data') return 0.60;
    if (route === 'about') return 0.68;
    if (route === 'agents') return 0.80;
    if (route === 'appearance') return 0.84;
    if (route === 'connect') return 0.84;
    if (route.startsWith('legal:')) return 0.84;
    return 0.78;
  }

  private triggerRouteLoad(route: string): void {
    if (route === 'connect') {
      void this.load();
      void this.loadDeviceCount();
    } else if (route === 'agents') {
      void this.loadAnswerMode();
    } else if (route === 'data') {
      this.dataRefreshTick++;
    }
  }

  private openSettingEntry(id: string): void {
    Haptics.tap();
    if (Motion.isFlagship(this.motionMode)) {
      this.openFloatingSheet(id);
      return;
    }
    this.subStack.pushPathByName(id, null);
  }

  private openFloatingSheet(route: string): void {
    this.clearSheetTimers();
    this.suspendedSheet = [];
    this.sheetStack = [route];
    this.sheetDragY = 0;
    this.subDragX = 0;
    this.subSlideFactor = 1;
    this.sheetOpenFactor = 0;
    this.sheetHFrac = this.sheetHeightFor(route);
    this.sheetMounted = true;
    this.sheetOpen = true;
    this.syncSubFromStack();
    this.triggerRouteLoad(route);
    setTimeout(() => {
      if (this.sheetMounted && this.sheetStack.length > 0) {
        this.getUIContext().animateTo(Motion.flagshipSheet(this.motionSpeed), () => {
          this.sheetOpenFactor = 1;
        });
      }
    }, 16);
  }

  private pushSheetNested(route: string): void {
    if (!this.sheetMounted || this.sheetStack.length === 0) {
      return;
    }
    this.clearSheetTimers();
    const next: string[] = this.sheetStack.slice();
    next.push(route);
    this.subDragX = 0;
    this.subSlideFactor = 0;
    this.sheetStack = next;
    this.syncSubFromStack();
    this.triggerRouteLoad(route);
    setTimeout(() => {
      if (this.sheetMounted && this.sheetStack.length > 1) {
        this.getUIContext().animateTo(Motion.flagshipParallax(this.motionSpeed), () => {
          this.subSlideFactor = 1;
          this.sheetHFrac = this.sheetHeightFor(route);
        });
      }
    }, 16);
  }

  private popSheetNested(): void {
    if (this.sheetStack.length <= 1) {
      this.closeFloatingSheet();
      return;
    }
    this.clearSheetTimers();
    const prevRoute: string = this.sheetStack[this.sheetStack.length - 2];
    const dur: number = Math.round(280 * Motion.speedScale(this.motionSpeed));
    this.getUIContext().animateTo(Motion.flagshipParallax(this.motionSpeed), () => {
      this.subSlideFactor = 0;
      this.subDragX = 0;
      this.sheetHFrac = this.sheetHeightFor(prevRoute);
    });
    this.subPopTimer = setTimeout(() => {
      this.subPopTimer = -1;
      if (this.sheetStack.length > 1) {
        const popped: string[] = this.sheetStack.slice(0, this.sheetStack.length - 1);
        this.sheetStack = popped;
        this.subSlideFactor = 1;
        this.subDragX = 0;
        this.syncSubFromStack();
      }
    }, dur);
  }

  private closeFloatingSheet(suspend: boolean = false): void {
    this.clearSheetTimers();
    if (!this.sheetMounted) {
      this.sheetOpen = false;
      this.syncSubFromStack();
      return;
    }
    if (suspend && this.sheetStack.length > 0) {
      this.suspendedSheet = this.sheetStack.slice();
    } else if (!suspend) {
      this.suspendedSheet = [];
    }
    const dur: number = Math.round(260 * Motion.speedScale(this.motionSpeed));
    this.getUIContext().animateTo(Motion.flagshipSheet(this.motionSpeed), () => {
      this.sheetOpenFactor = 0;
      this.sheetDragY = 0;
    });
    this.sheetCloseTimer = setTimeout(() => {
      this.sheetCloseTimer = -1;
      this.sheetStack = [];
      this.sheetMounted = false;
      this.sheetDragY = 0;
      this.subDragX = 0;
      this.subSlideFactor = 1;
      this.sheetOpen = false;
      this.syncSubFromStack();
    }, dur);
  }

  private openFullSub(name: string): void {
    if (this.sheetMounted && this.sheetStack.length > 0) {
      this.suspendedSheet = this.sheetStack.slice();
      this.clearSheetTimers();
      this.sheetStack = [];
      this.sheetMounted = false;
      this.sheetOpenFactor = 0;
      this.sheetDragY = 0;
      this.sheetOpen = false;
    }
    this.subStack.pushPathByName(name, null);
    this.syncSubFromStack();
  }

  private effectiveBackdrop(): number {
    if (!this.sheetMounted || this.sheetOpenFactor <= 0) {
      return 0;
    }
    const dragRatio: number = Math.min(1, Math.max(0, this.sheetDragY / 320));
    return Math.max(0, this.sheetOpenFactor * (1 - dragRatio));
  }

  private effectiveSubProgress(): number {
    if (this.sheetStack.length <= 1) {
      return 1;
    }
    const w: number = this.sheetW > 80 ? this.sheetW : 360;
    const dragFrac: number = Math.min(1, Math.max(0, this.subDragX / w));
    return Math.max(0, Math.min(1, this.subSlideFactor - dragFrac));
  }

  private sheetPageOffsetX(idx: number): number {
    const last: number = this.sheetStack.length - 1;
    if (last <= 0) {
      return 0;
    }
    const w: number = this.sheetW > 80 ? this.sheetW : 360;
    const p: number = this.effectiveSubProgress();
    if (idx === last) {
      return w * (1 - p);
    }
    if (idx === last - 1) {
      return -w * 0.28 * p;
    }
    return -w * 0.28;
  }

  private sheetPageScale(idx: number): number {
    const last: number = this.sheetStack.length - 1;
    if (last <= 0 || idx === last) {
      return 1;
    }
    if (idx === last - 1) {
      return 1 - 0.035 * this.effectiveSubProgress();
    }
    return 0.965;
  }

  private sheetPageOpacity(idx: number): number {
    const last: number = this.sheetStack.length - 1;
    if (last <= 0 || idx === last) {
      return 1;
    }
    if (idx === last - 1) {
      return 1 - 0.52 * this.effectiveSubProgress();
    }
    return 0;
  }

  private onSettingsBack(): void {
    if (this.legalOpen) {
      this.legalOpen = false;
      return;
    }
    if (this.sheetMounted && this.sheetStack.length > 0) {
      if (this.sheetStack.length > 1) {
        this.popSheetNested();
      } else {
        this.closeFloatingSheet();
      }
      return;
    }
    if (this.sub === 'feedback') {
      const at: string | undefined = AppStorage.get<string>('fbStage');
      if (at !== undefined && at !== '' && at !== 'entry') {
        const n: number | undefined = AppStorage.get<number>('fbBack');
        AppStorage.setOrCreate('fbBack', (n === undefined ? 0 : n) + 1);
        return;
      }
    }
    if (this.sub !== '') {
      this.closeSub();
    }
  }

  aboutToAppear(): void {
    this.hapticsUi = this.haptics;
    this.hdsUi = this.hdsOn;
    const es: boolean | undefined = AppStorage.get<boolean>('enterSend');
    this.enterSendUi = es !== undefined ? es : true;
    this.compactHistoryUi = AppStorage.get<boolean>('compactHistory') === true;
    const ts: number | undefined = AppStorage.get<number>('textScale');
    this.textScaleUi = ts !== undefined && ts > 0 ? ts : 1;
    this.readVersion();
    this.syncSubFromStack();
    const nd: boolean | undefined = AppStorage.get<boolean>('notifyDone');
    const nb: boolean | undefined = AppStorage.get<boolean>('notifyBgOnly');
    this.notifyDone = nd !== undefined ? nd : true;
    this.notifyBgOnly = nb !== undefined ? nb : true;
    this.editBase = this.wanBase;
    this.editToken = this.token0;
    void this.load();
    this.linkTimer = setInterval(() => {
      const lanNow: boolean = this.api.isLan();
      if (lanNow !== this.lan) {
        this.lan = lanNow;
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    if (this.linkTimer >= 0) {
      clearInterval(this.linkTimer);
      this.linkTimer = -1;
    }
    this.stopSaveTimer();
    this.clearSheetTimers();
  }

  private startSaveTimer(): void {
    this.stopSaveTimer();
    const t0: number = Date.now();
    this.saveElapsed = 0;
    this.saveTimer = setInterval(() => {
      this.saveElapsed = Math.round((Date.now() - t0) / 100) / 10;
    }, 100);
  }

  private stopSaveTimer(): void {
    if (this.saveTimer >= 0) {
      clearInterval(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.info = await this.api.info();
      this.base = this.api.currentBase();
      this.lan = this.api.isLan();
      this.err = '';
    } catch (e) {
      this.err = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private async reconnectHost(): Promise<void> {
    await this.api.poke();
    await this.load();
    void this.loadDeviceCount();
    if (this.err === '') {
      Toast.ok('已刷新连接 · ' + (this.info !== null ? this.info.host : '在线'));
    } else {
      Toast.err(this.err);
    }
  }

  private async doSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    const rawBase: string = this.editBase.trim();
    const rawToken: string = this.editToken.trim();
    if (rawBase === '' || rawToken === '') {
      this.saved = '';
      this.saveErr = '连接地址与访问令牌均不能为空。';
      return;
    }
    if (rawBase.indexOf('://') >= 0 && !/^https?:\/\//i.test(rawBase)) {
      this.saved = '';
      this.saveErr = '地址协议仅支持 http:// 或 https://。';
      return;
    }
    const normBase: string = Pairing.normalizeBase(rawBase);
    if (!/^https?:\/\/[^\s/]+/i.test(normBase)) {
      this.saved = '';
      this.saveErr = '连接地址格式不合法，请检查后重试。';
      return;
    }
    this.editBase = normBase;
    this.editToken = rawToken;
    this.saving = true;
    this.saved = '';
    this.saveErr = '';
    this.saveStage = 0;
    this.saveDetail = '正在写入新连接地址 · ' + normBase;
    this.startSaveTimer();
    try {
      this.onSave(normBase, rawToken);
      this.saveStage = 1;
      this.saveDetail = '正在探测可达入口…';
      await this.api.poke((st: number, det: string) => {
        this.saveStage = 1;
        this.saveDetail = det;
      });
      this.saveStage = 2;
      this.saveDetail = '正在验证访问令牌与电脑状态…';
      const inf: ApiInfo = await this.api.info((st: number, det: string) => {
        this.saveStage = 2;
        this.saveDetail = det;
      });
      this.info = inf;
      this.base = this.api.currentBase();
      this.lan = this.api.isLan();
      this.err = '';
      this.saveErr = '';
      this.saved = '已连接 · ' + inf.host;
      void this.loadDeviceCount();
      Toast.ok('已连接 ' + inf.host);
    } catch (e) {
      const msg: string = (e as Error).message !== undefined && (e as Error).message !== ''
        ? (e as Error).message
        : '无法连接到该地址，请检查电脑端网关是否开启或令牌是否正确';
      this.err = msg;
      this.saveErr = msg;
      this.saved = '';
    } finally {
      this.stopSaveTimer();
      this.saving = false;
    }
  }

  private async loadDeviceCount(): Promise<void> {
    try {
      const rows: SessionRow[] = await this.api.sessions();
      this.devCount = rows.length;
    } catch (e) {
      this.devCount = -1;
    }
  }

  private async loadAnswerMode(): Promise<void> {
    try {
      const m: string = await this.api.answerMode();
      if (m === 'phone' || m === 'desktop') {
        this.answerMode = m;
      }
    } catch (e) {
      // 旧网关无该路由时保留默认手机为主
    }
  }

  private async setAnswerMode(mode: string): Promise<void> {
    const old: string = this.answerMode;
    this.answerMode = mode;
    this.answerBusy = true;
    try {
      const m: string = await this.api.setAnswerMode(mode);
      this.answerMode = (m === 'desktop' || m === 'phone') ? m : mode;
    } catch (e) {
      this.answerMode = old;
      Toast.err('切换失败：' + (e as Error).message);
    } finally {
      this.answerBusy = false;
    }
  }

  private readVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.verText = 'Agent Mobile v' + info.versionName;
    } catch (e) {
      this.verText = 'Agent Mobile';
    }
  }

  private async savePrefFlag(key: string, v: boolean): Promise<void> {
    AppStorage.setOrCreate(key, v);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), 'dsh_mobile_cfg');
      await p.put(key, v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.info('AM_CFG save failed key=' + key);
    }
  }

  private async saveTextScale(v: number): Promise<void> {
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), 'dsh_mobile_cfg');
      await p.put('textScale', String(v));
      await p.flush();
    } catch (e) {
      console.info('AM_CFG textScale save failed');
    }
  }

  private closeSub(): void {
    if (this.subStack.size() > 0) {
      this.subStack.pop();
    }
    this.syncSubFromStack();
    if (this.subStack.size() === 0 && this.suspendedSheet.length > 0 && Motion.isFlagship(this.motionMode)) {
      const restore: string[] = this.suspendedSheet.slice();
      this.suspendedSheet = [];
      const top: string = restore[restore.length - 1];
      this.sheetStack = restore;
      this.sheetDragY = 0;
      this.subDragX = 0;
      this.subSlideFactor = 1;
      this.sheetOpenFactor = 0;
      this.sheetHFrac = this.sheetHeightFor(top);
      this.sheetMounted = true;
      this.sheetOpen = true;
      this.syncSubFromStack();
      this.triggerRouteLoad(top);
      setTimeout(() => {
        if (this.sheetMounted && this.sheetStack.length > 0) {
          this.getUIContext().animateTo(Motion.flagshipSheet(this.motionSpeed), () => {
            this.sheetOpenFactor = 1;
          });
        }
      }, 16);
    }
  }

  private clearUnread(): void {
    Unread.clearAll();
    Toast.ok('已清除全部未读与桌面红点');
  }

  private panelMaxWidth(): number {
    return this.wideScreen ? 680 : 520;
  }

  private bannerStatusText(): string {
    if (this.loading) {
      return '正在检测连接…';
    }
    if (this.err !== '') {
      return '未连接 · 点击管理电脑连接';
    }
    const route: string = this.lan ? '已连接 · 局域网直连' : '已连接 · 公网入口';
    return this.linkEncrypted ? route + ' · 端到端加密' : route;
  }

  private isFullScreenSub(name: string): boolean {
    return name === 'pair' || name === 'feedback' || name === 'storage' ||
      name === 'extras_plugins' || name === 'extras_schedules' || name === 'web_console';
  }

  private subTitleOf(name: string): string {
    if (name === 'connect') return '连接与设备';
    if (name === 'agents') return 'Agent 引擎与控制台';
    if (name === 'appearance') return '外观与交互';
    if (name === 'notify') return '通知';
    if (name === 'data') return '数据与存储';
    if (name === 'legal:privacy') return legalTitleOf('privacy');
    if (name === 'legal:terms') return legalTitleOf('terms');
    if (name === 'legal:licenses') return legalTitleOf('licenses');
    return '关于与协议';
  }

  private navIconRes(id: string): Resource {
    if (id === 'agents') return $r('app.media.ic_set_agent');
    if (id === 'appearance') return $r('app.media.ic_set_look');
    if (id === 'notify') return $r('app.media.ic_set_bell');
    if (id === 'data') return $r('app.media.ic_set_disk');
    return $r('app.media.ic_set_info');
  }

  private aboutRows(): AboutRow[] {
    return [
      { k: '客户端', v: this.verText, mono: false },
      { k: '电脑网关', v: this.info !== null ? (this.info.version + ' · ' + this.info.host) : '未连接', mono: false },
      { k: '监听端口', v: this.info !== null ? String(this.info.port) : '-', mono: true },
      { k: '数据流向', v: '仅在授权设备间加密传输', mono: false }
    ];
  }

  @Builder
  rootHeader() {
    Row() {
      Text('设置').fontSize(Tokens.fsDisplay).fontWeight(FontWeight.Bold).fontColor(Tokens.fg)
      Blank()
    }
    .width('100%').height(52).padding({ left: 16, right: 16 })
    .margin({ top: this.topInset }).alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  groupTitle(text: string, topGap: number) {
    Text(text)
      .fontSize(Tokens.fsCaption)
      .fontColor(Tokens.dim2)
      .letterSpacing(1.4)
      .margin({ left: 6, top: topGap, bottom: 8 })
  }

  @Builder
  navRow(r: NavRow) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Image(this.navIconRes(r.id)).width(18).height(18).fillColor(Tokens.navIconInk).objectFit(ImageFit.Contain)
      }
      .width(34).height(34).borderRadius(Tokens.rSm).backgroundColor(Tokens.navIconBg)

      Column() {
        Text(r.name).fontSize(Tokens.fsBodyLg).fontColor(Tokens.fg).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (r.hint !== '') {
          Text(r.hint).fontSize(Tokens.fsFoot).fontColor(Tokens.dim2).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })

      if (r.id === 'notify' && this.unreadCount > 0) {
        Text(String(this.unreadCount))
          .fontSize(Tokens.fsCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.accentInk)
          .backgroundColor(Tokens.accent)
          .borderRadius(Tokens.rPill)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .margin({ right: 8 })
          .contentTransition(Motion.numTransition(this.motionMode))
      }
      if (Motion.isFlagship(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Tokens.dim2])
      } else {
        Text('›').fontSize(17).fontColor(Tokens.dim2)
      }
    }
    .width('100%').padding({ left: 14, right: 14, top: 13, bottom: 13 })
    .alignItems(VerticalAlign.Center)
    .scale({
      x: this.pressedRowId === r.id ? 0.97 : 1,
      y: this.pressedRowId === r.id ? 0.97 : 1
    })
    .animation(Motion.isFlagship(this.motionMode)
      ? Motion.flagshipSnappy(this.motionSpeed)
      : undefined)
    .clickEffect(Motion.isFlagship(this.motionMode) ? null : { level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .onTouch((e: TouchEvent) => {
      if (!Motion.isFlagship(this.motionMode)) {
        return;
      }
      if (e.type === TouchType.Down) {
        this.pressedRowId = r.id;
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.pressedRowId === r.id) {
          this.pressedRowId = '';
        }
      }
    })
    .onClick(() => { this.openSettingEntry(r.id); })
  }

  @Builder
  navGroup(rows: NavRow[], cardIdx: number) {
    Column() {
      ForEach(rows, (r: NavRow, i: number) => {
        this.navRow(r)
        if (i < rows.length - 1) {
          Divider().color(Tokens.lineSoft).margin({ left: 60 })
        }
      }, (r: NavRow) => r.id)
    }
    .width('100%')
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .clip(true)
    .transition(Motion.flagshipCardStagger(cardIdx, this.motionMode, this.motionSpeed))
  }

  @Builder
  deviceBanner() {
    Row() {
      Image(AppIcon.res(this.appIconStyle))
        .width(46)
        .height(46)
        .borderRadius(Tokens.rMd)
        .border({ width: 0.5, color: Tokens.line })
      Column() {
        Row({ space: 6 }) {
          Text(this.machineName !== '' ? this.machineName : (this.info !== null ? this.info.host : '电脑连接'))
            .fontSize(Tokens.fsBodyLg).fontWeight(FontWeight.Medium).fontColor(Tokens.fg)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (!this.loading && this.err === '' && this.linkEncrypted) {
            Text('E2EE')
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.doneInk)
              .backgroundColor(Tokens.doneBg)
              .borderRadius(Tokens.rPill)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          }
        }
        Text(this.bannerStatusText())
          .fontSize(Tokens.fsFoot)
          .fontColor(this.loading ? Tokens.dim2 : (this.err === '' ? Tokens.ok : Tokens.err))
          .margin({ top: 3 }).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 12 })

      if (!this.loading && this.err === '') {
        Row().width(8).height(8).borderRadius(Tokens.rPill).backgroundColor(Tokens.ok).margin({ right: 6 })
      }
      if (Motion.isFlagship(this.motionMode)) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([Tokens.dim2])
      } else {
        Text('›').fontSize(17).fontColor(Tokens.dim2)
      }
    }
    .width('100%').padding(16).backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn)).shadow(Mat.cardShadow(this.hdsOn)).borderRadius(Tokens.rGroup)
    .scale({
      x: this.pressedRowId === 'connect' ? 0.97 : 1,
      y: this.pressedRowId === 'connect' ? 0.97 : 1
    })
    .animation(Motion.isFlagship(this.motionMode)
      ? Motion.flagshipSnappy(this.motionSpeed)
      : undefined)
    .clickEffect(Motion.isFlagship(this.motionMode) ? null : { level: ClickEffectLevel.LIGHT, scale: 0.98 })
    .transition(Motion.flagshipCardStagger(0, this.motionMode, this.motionSpeed))
    .onTouch((e: TouchEvent) => {
      if (!Motion.isFlagship(this.motionMode)) {
        return;
      }
      if (e.type === TouchType.Down) {
        this.pressedRowId = 'connect';
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        if (this.pressedRowId === 'connect') {
          this.pressedRowId = '';
        }
      }
    })
    .onClick(() => { this.openSettingEntry('connect'); })
  }

  @Builder
  rootList() {
    Column() {
      this.deviceBanner()

      this.groupTitle('电脑与智能体', 18)
      this.navGroup(AGENT_GROUP_ROWS, 1)

      this.groupTitle('偏好设置', 18)
      this.navGroup(PREF_GROUP_ROWS, 2)

      this.groupTitle('数据与支持', 18)
      this.navGroup(DATA_GROUP_ROWS, 3)

      Text(this.verText)
        .fontSize(Tokens.fsFoot)
        .fontColor(Tokens.dim2)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 22, bottom: 8 })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  fullScreenSubBody(name: string) {
    if (name === 'pair') {
      PairPage({
        api: this.api, defaultBase: this.defaultLan, entry: this.pairEntry, hasBack: true,
        onExit: () => { this.closeSub(); },
        onPaired: (b: string, t: string, host: string, lan: string[], hostId?: string, e2eePub?: string) => {
          this.closeSub();
          this.onSaveLan(b, t, lan, hostId, e2eePub, host);
          this.editBase = b;
          this.editToken = t;
          void this.load();
          void this.loadDeviceCount();
        }
      })
    } else if (name === 'feedback') {
      FeedbackPage({ onExit: () => { this.closeSub(); } })
    } else if (name === 'storage') {
      StoragePage({ onExit: () => { this.closeSub(); } })
    } else if (name === 'extras_plugins') {
      ExtrasPanel({ mode: 'plugins', sessionId: '', api: this.api, onExit: () => { this.closeSub(); } })
    } else if (name === 'extras_schedules') {
      ExtrasPanel({ mode: 'schedules', sessionId: '', api: this.api, onExit: () => { this.closeSub(); } })
    } else if (name === 'web_console') {
      WebConsolePage({
        api: this.api,
        hostName: this.machineName !== '' ? this.machineName : (this.info !== null ? this.info.host : ''),
        onExit: () => { this.closeSub(); }
      })
    }
  }

  @Builder
  panelSubBody(name: string) {
    if (name === 'connect') {
      ConnectPanel({
        api: this.api,
        editBase: $editBase, editToken: $editToken, saved: this.saved, saveErr: this.saveErr,
        saving: this.saving, saveStage: this.saveStage, saveDetail: this.saveDetail, saveElapsed: this.saveElapsed,
        netMode: this.netMode, machineName: this.machineName, currentBase: this.base,
        pluginVersion: this.info !== null ? this.info.version : '', sessionsCount: this.devCount,
        connected: !this.loading && this.err === '', linkLoading: this.loading, isLanLink: this.lan,
        onSave: (): void => { void this.doSave(); },
        onNetMode: (mode: string): void => { this.onNetMode(mode); },
        onPickMachine: (id: string): void => { this.onPickMachine(id); },
        onRemoveMachine: (id: string): void => { this.onRemoveMachine(id); },
        onAddMachine: (wan: string, token: string, mName: string): void => {
          this.onAddMachine(wan, token, mName);
        },
        onOpenPair: (entry: string): void => { this.pairEntry = entry; this.openFullSub('pair'); },
        onReconnect: (): void => { void this.reconnectHost(); },
        onRemoveCurrent: (): void => {
          AppCtx.confirm(
            '移除此电脑',
            '会清掉这台手机与它的配对凭据；若无其余电脑将回到连接页。电脑端不受影响。',
            '移除',
            () => {
              if (this.sheetMounted) {
                this.closeFloatingSheet();
              } else {
                this.closeSub();
              }
              this.onReset();
            },
            true
          );
        }
      })
    } else if (name === 'agents') {
      AgentPanel({
        api: this.api,
        answerMode: this.answerMode,
        answerBusy: this.answerBusy,
        onAnswerMode: (m: string): void => { void this.setAnswerMode(m); },
        onOpenPresets: (): void => {
          const p: ChatParam = { id: '', title: '智能体预设与权限' };
          this.rootStack.pushPathByName('presets', p);
        },
        onOpenExtras: (mode: string): void => {
          this.openFullSub(mode === 'schedules' ? 'extras_schedules' : 'extras_plugins');
        },
        onOpenWebConsole: (): void => {
          this.openFullSub('web_console');
        }
      })
    } else if (name === 'appearance') {
      AppearancePanel({
        themeMode: this.themeMode, haptics: this.hapticsUi, hds: this.hdsUi, enterSend: this.enterSendUi,
        textScale: this.textScaleUi, compactHistory: this.compactHistoryUi,
        onTheme: (m: string): void => { this.onTheme(m); },
        onHaptics: (v: boolean): void => { this.hapticsUi = v; this.onHaptics(v); },
        onHds: (v: boolean): void => { this.hdsUi = v; this.onHds(v); },
        onEnterSend: (v: boolean): void => { this.enterSendUi = v; void this.savePrefFlag('enterSend', v); },
        onTextScale: (v: number): void => {
          this.textScaleUi = v;
          AppStorage.setOrCreate('textScale', v);
          void this.saveTextScale(v);
        },
        onCompactHistory: (v: boolean): void => {
          this.compactHistoryUi = v;
          void this.savePrefFlag('compactHistory', v);
        }
      })
    } else if (name === 'notify') {
      NotifyPanel({
        done: this.notifyDone, bgOnly: this.notifyBgOnly,
        onDone: (v: boolean): void => { this.notifyDone = v; void this.savePrefFlag('notifyDone', v); },
        onBgOnly: (v: boolean): void => { this.notifyBgOnly = v; void this.savePrefFlag('notifyBgOnly', v); },
        onClearUnread: (): void => { this.clearUnread(); }
      })
    } else if (name === 'data') {
      DataStoragePanel({
        refreshTick: this.dataRefreshTick,
        onStorage: (): void => { this.openFullSub('storage'); }
      })
    } else if (name === 'legal:privacy' || name === 'legal:terms' || name === 'legal:licenses') {
      this.legalDocInline(name === 'legal:terms' ? 'terms' : (name === 'legal:licenses' ? 'licenses' : 'privacy'))
    } else {
      AboutPanel({
        rows: this.aboutRows(), verText: this.verText,
        onFeedback: (): void => { this.openFullSub('feedback'); },
        onLegal: (kind: LegalDocKind): void => {
          if (Motion.isFlagship(this.motionMode) && this.sheetMounted && this.sheetStack.length > 0) {
            this.pushSheetNested('legal:' + kind);
          } else {
            this.legalKind = kind;
            this.legalOpen = true;
          }
        }
      })
    }
  }

  @Builder
  subHeaderBar(name: string) {
    Column() {
      PageHeader({
        title: this.subTitleOf(name),
        padTop: true,
        immersive: true,
        rightKind: name === 'connect' ? 'icon' : 'none',
        rightIcon: $r('app.media.ic_scan'),
        onBack: () => { this.closeSub(); },
        onRight: () => { this.pairEntry = 'scan'; this.subStack.pushPathByName('pair', null); }
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  private subHdsTitle(name: string): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => { this.subHeaderBar(name); };
    return buildTransparentHdsTitle(stack);
  }

  @Builder
  subDest(name: string) {
    HdsNavDestination() {
      if (this.isFullScreenSub(name)) {
        this.fullScreenSubBody(name)
      } else {
        Stack({ alignContent: Alignment.Top }) {
          Scroll() {
            Column() {
              Column() { this.panelSubBody(name) }
                .width('100%').constraintSize({ maxWidth: this.panelMaxWidth() }).alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: this.topInset + 64, bottom: this.bottomInset + 40 })
            .alignItems(HorizontalAlign.Center)
          }
          .width('100%').height('100%').scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring).align(Alignment.Top)

          TopFade({ fadeHeight: this.topInset + 68 })
        }
        .width('100%').height('100%').backgroundColor(this.themeBg)
      }
    }
    .hideTitleBar(this.isFullScreenSub(name))
    .titleBar(this.subHdsTitle(name))
    .hideBackButton(true)
    .backgroundColor(this.themeBg)
    .onBackPressed(() => {
      if (this.legalOpen) {
        this.legalOpen = false;
        return true;
      }
      if (name === 'feedback') {
        const at: string | undefined = AppStorage.get<string>('fbStage');
        if (at !== undefined && at !== '' && at !== 'entry') {
          const n: number | undefined = AppStorage.get<number>('fbBack');
          AppStorage.setOrCreate('fbBack', (n === undefined ? 0 : n) + 1);
          return true;
        }
      }
      this.closeSub();
      return true;
    })
    .onShown(() => {
      this.syncSubFromStack();
      if (name === 'connect') {
        void this.load();
        void this.loadDeviceCount();
      } else if (name === 'agents') {
        void this.loadAnswerMode();
      } else if (name === 'data') {
        this.dataRefreshTick++;
      }
    })
    .onHidden(() => {
      this.syncSubFromStack();
    })
  }

  @Builder
  legalDocInline(kind: LegalDocKind) {
    Column() {
      Text(legalBodyOf(kind))
        .fontSize(Tokens.fsBody)
        .fontColor(Tokens.fg)
        .lineHeight(22)
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(Mat.cardBg(this.hdsOn))
    .border(Mat.cardBorder(this.hdsOn))
    .shadow(Mat.cardShadow(this.hdsOn))
    .borderRadius(Tokens.rGroup)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  sheetScrollPage(route: string) {
    Scroll() {
      Column() {
        this.panelSubBody(route)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 26 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  @Builder
  floatingSheetOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 景深半透明遮罩：跟随手指下拉进度实时淡出
      Row()
        .width('100%')
        .height('100%')
        .backgroundColor(this.themeDark ? '#66000000' : '#2E0F172A')
        .opacity(this.effectiveBackdrop())
        .onClick(() => {
          Haptics.tap();
          this.closeFloatingSheet();
        })

      // 旗舰悬浮可拖拽半模态卡片栈（外层 padding 精准留白，避免 width 100% + margin 溢出）
      Column() {
        Column() {
          // 顶部拖拽指示条 + 标题操作栏
        Column() {
          Row()
            .width(38)
            .height(4)
            .borderRadius(2)
            .backgroundColor(this.themeDark ? '#40FFFFFF' : '#260F172A')
            .margin({ top: 9, bottom: 8 })

          Row({ space: 10 }) {
            if (this.sheetStack.length > 1) {
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(17)
                  .fontWeight(FontWeight.Medium)
                  .fontColor([Tokens.fg])
              }
              .width(34)
              .height(34)
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.themeDark ? '#1FFFFFFF' : '#120F172A')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .accessibilityText('返回上一级')
              .transition(Motion.fabTransition(this.motionMode))
              .onClick(() => {
                Haptics.tap();
                this.popSheetNested();
              })
            }

            Text(this.sheetStack.length > 0 ? this.subTitleOf(this.sheetStack[this.sheetStack.length - 1]) : '')
              .fontSize(Tokens.fsTitle)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.fg)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            if (this.sheetStack.length > 0 && this.sheetStack[this.sheetStack.length - 1] === 'connect') {
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.qrcode'))
                  .fontSize(16)
                  .fontColor([Tokens.fg])
              }
              .width(34)
              .height(34)
              .borderRadius(Tokens.rPill)
              .backgroundColor(this.themeDark ? '#1FFFFFFF' : '#120F172A')
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
              .accessibilityText('扫码配对')
              .onClick(() => {
                Haptics.tap();
                this.pairEntry = 'scan';
                this.openFullSub('pair');
              })
            }

            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor([Tokens.dim])
            }
            .width(34)
            .height(34)
            .borderRadius(Tokens.rPill)
            .backgroundColor(this.themeDark ? '#1FFFFFFF' : '#120F172A')
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
            .accessibilityText('关闭')
            .onClick(() => {
              Haptics.tap();
              this.closeFloatingSheet();
            })
          }
          .width('100%')
          .padding({ left: 18, right: 16, bottom: 10 })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .gesture(
          PanGesture({ direction: PanDirection.Vertical, distance: 4 })
            .onActionUpdate((e: GestureEvent) => {
              const dy: number = e.offsetY;
              this.sheetDragY = dy > 0 ? dy : dy * 0.16;
            })
            .onActionEnd((e: GestureEvent) => {
              if (this.sheetDragY > 96 || e.velocityY > 560) {
                Haptics.soft();
                this.closeFloatingSheet();
              } else {
                this.getUIContext().animateTo(Motion.flagshipSheet(this.motionSpeed), () => {
                  this.sheetDragY = 0;
                });
              }
            })
        )

        // 栈内多级页面容器：ForEach 真栈式渲染，保留前页滚动位置并支持 30% 视差推拉与右滑跟手返回
        Stack({ alignContent: Alignment.TopStart }) {
          ForEach(this.sheetStack, (route: string, idx: number) => {
            Column() {
              this.sheetScrollPage(route)
            }
            .width('100%')
            .height('100%')
            .backgroundColor(idx > 0
              ? (this.hdsOn ? (this.themeDark ? '#F5141822' : '#FAF4F7FC') : Tokens.bg)
              : Color.Transparent)
            .translate({ x: this.sheetPageOffsetX(idx) })
            .scale({ x: this.sheetPageScale(idx), y: this.sheetPageScale(idx) })
            .opacity(this.sheetPageOpacity(idx))
            .hitTestBehavior(idx === this.sheetStack.length - 1 ? HitTestMode.Default : HitTestMode.None)
            .gesture(
              PanGesture({ direction: PanDirection.Right, distance: 12 })
                .onActionUpdate((e: GestureEvent) => {
                  if (idx !== this.sheetStack.length - 1 || this.sheetStack.length <= 1) {
                    return;
                  }
                  this.subDragX = e.offsetX > 0 ? e.offsetX : 0;
                })
                .onActionEnd((e: GestureEvent) => {
                  if (idx !== this.sheetStack.length - 1 || this.sheetStack.length <= 1) {
                    return;
                  }
                  const w: number = this.sheetW > 80 ? this.sheetW : 360;
                  if (this.subDragX > w * 0.28 || e.velocityX > 520) {
                    Haptics.soft();
                    this.popSheetNested();
                  } else {
                    this.getUIContext().animateTo(Motion.flagshipParallax(this.motionSpeed), () => {
                      this.subDragX = 0;
                    });
                  }
                })
            )
          }, (route: string, idx: number) => String(idx) + ':' + route)
        }
        .width('100%')
        .layoutWeight(1)
        .clip(true)
        }
        .width('100%')
        .constraintSize({ maxWidth: this.panelMaxWidth() + 32 })
        .height(String(Math.round(this.sheetHFrac * 100)) + '%')
        .backgroundColor(this.hdsOn
          ? (this.themeDark ? '#D6141822' : '#E8F4F7FC')
          : Tokens.bg)
        .backgroundEffect(Mat.glassEffect(this.hdsOn, true))
        .borderRadius(28)
        .border(this.hdsOn
          ? { width: 1, color: this.themeDark ? '#38FFFFFF' : '#E6FFFFFF' }
          : { width: 1, color: Tokens.line })
        .shadow({
          radius: 38,
          color: this.themeDark ? '#88000000' : '#30142038',
          offsetY: 12
        })
        .clip(true)
        .translate({ y: (1 - this.sheetOpenFactor) * 520 + this.sheetDragY })
        .scale({
          x: 0.94 + 0.06 * this.sheetOpenFactor,
          y: 0.94 + 0.06 * this.sheetOpenFactor
        })
        .opacity(Math.min(1, this.sheetOpenFactor * 1.45))
        .onAreaChange((_oldVal: Area, newVal: Area) => {
          const w: number = Number(newVal.width);
          if (w > 80 && Math.abs(w - this.sheetW) > 1) {
            this.sheetW = w;
          }
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 10, right: 10, bottom: this.bottomInset + 10 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  legalSheetView() {
    LegalSheet({
      kind: this.legalKind,
      onClose: () => {
        this.legalOpen = false;
      }
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        Navigation(this.subStack) {
          Stack({ alignContent: Alignment.Top }) {
            Scroll() {
              Column() {
                Column() { this.rootList() }
                  .width('100%').constraintSize({ maxWidth: this.panelMaxWidth() }).alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: this.topInset + 62, bottom: this.bottomInset + 96 })
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%').height('100%').scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring).align(Alignment.Top)

            TopFade({ fadeHeight: this.topInset + 68 })
            this.rootHeader()
          }
          .width('100%').height('100%').backgroundColor(this.themeBg)
        }
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
        .navDestination(this.subDest)
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.themeBg)
      .blur(this.effectiveBackdrop() * 18)
      .scale({
        x: 1 - 0.055 * this.effectiveBackdrop(),
        y: 1 - 0.055 * this.effectiveBackdrop()
      })
      .borderRadius(this.effectiveBackdrop() > 0.01 ? 22 * this.effectiveBackdrop() : 0)
      .clip(this.effectiveBackdrop() > 0.01)

      if (this.sheetMounted && this.sheetStack.length > 0) {
        this.floatingSheetOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .bindSheet($$this.legalOpen, this.legalSheetView(),
      Mat.sheetOpts(this.hdsOn, '74%', () => {
        this.legalOpen = false;
      }))
  }
}
