import preferences from '@ohos.data.preferences';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { Api } from '../common/Api';
import { AppCtx } from '../common/AppCtx';
import { AppIcon, ICON_DARK } from '../common/AppIcon';
import { isLanUrl } from '../common/ApiUtil';
import { Tokens } from '../common/Tokens';
import { ChatParam } from '../common/Types';
import { applyTheme, resolveDark, THEME_AUTO } from '../common/Theme';
import { LegalDocKind } from '../common/LegalDocs';
import { LegalSheet } from '../view/LegalSheet';
import { ChatPage } from '../view/ChatPage';
import { PresetsPage } from '../view/PresetsPage';
import { PairPage } from '../view/PairPage';
import { ShellPage } from '../view/ShellPage';
import { GlassToastHost } from '../common/GlassToastHost';
import { Haptics } from '../common/Haptics';
import { LinkLog } from '../common/LinkLog';
import { Machines } from '../common/Machines';
import { Mat } from '../common/Mat';
import { Motion, MOTION_VIVID } from '../common/Motion';
import { Net } from '../common/Net';
import { PushBridge } from '../common/PushBridge';
import { Secret } from '../common/Secret';
import { Toast } from '../common/Toast';
import { Unread } from '../common/Unread';

// 首次启动没有内置地址与令牌：先在「配对这台电脑」里扫码或输 6 位码，
// 配对成功后地址与令牌写进本机 preferences，之后的启动都从这里读。
export const DEFAULT_BASE: string = '';
export const DEFAULT_TOKEN: string = '';
export const LAN_BASE: string = '';

const PREF_STORE: string = 'dsh_mobile_cfg';

@Entry
@Component
struct Index {
  @Provide('stack') stack: NavPathStack = new NavPathStack();
  /** 全屏看图的地址与一镜到底 ID：聊天页写，这里负责铺满整屏盖住标题栏 */
  @StorageLink('bigImg') bigImg: string = '';
  @StorageLink('bigImgGeoId') bigImgGeoId: string = '';
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('themeRev') themeRev: number = 0;
  @StorageLink('sysConfigTick') @Watch('onSysConfigTick') sysConfigTick: number = 0;
  @StorageLink('netBearerTick') @Watch('onNetBearerTick') netBearerTick: number = 0;
  @StorageLink('openSession') @Watch('onOpenSessionChange') openSession: string = '';
  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @State private wanBase: string = DEFAULT_BASE;
  @State private token: string = DEFAULT_TOKEN;
  @State private api: Api = new Api(DEFAULT_BASE, DEFAULT_TOKEN, LAN_BASE);
  @State private themeMode: string = THEME_AUTO;
  /** 网络策略：auto（自动）/ lan（仅局域网）/ wan（仅公网）。 */
  @State private netMode: string = 'auto';
  /** 当前连着的电脑名字（多台电脑共用同一套界面，切换时整体换地址与令牌）。 */
  @State private machineName: string = '';
  @State private haptics: boolean = true;
  @State private hdsOn: boolean = true;
  @StorageLink('appIconStyle') appIconStyle: string = ICON_DARK;
  @State private cfgLoaded: boolean = false;
  @State private privacyAccepted: boolean = false;
  @State private legalKind: LegalDocKind = 'privacy';
  @State private legalOpen: boolean = false;
  /** 每次重建导航栈自增，40ms 延迟里若已变化就放弃回填 */
  private navRev: number = 0;
  /** 在线心跳定时器，-1 表示没在跑 */
  private presenceTimer: number = -1;
  private presenceBusy: boolean = false;
  private presenceTick: number = 0;
  private refreshLanBusy: boolean = false;
  /** 记录是否刚从后台返回前台，供 fgProbe 识别补扫通知不误吞 */
  private wasBackground: boolean = false;

  private bumpMachineEpoch(): void {
    const cur: number | undefined = AppStorage.get<number>('machineEpoch');
    AppStorage.setOrCreate('machineEpoch', (cur !== undefined ? cur : 0) + 1);
  }

  private onNetBearerTick(): void {
    if (!this.privacyAccepted || this.token === '' || this.wanBase === '') {
      return;
    }
    // 蜂窝 <-> Wi-Fi 切换时重选一次入口：出门秒切公网，回家秒切局域网
    void this.refreshLan();
  }

  private onOpenSessionChange(): void {
    if (!this.privacyAccepted || this.token === '' || this.wanBase === '') {
      return;
    }
    if (AppStorage.get<boolean>('appFg') === false) {
      return;
    }
    this.sendPresenceOnce();
  }

  private onSysConfigTick(): void {
    if (this.themeMode !== THEME_AUTO) {
      return;
    }
    const nextDark: boolean = resolveDark(this.themeMode, this.systemDark());
    if (nextDark !== Tokens.isDark) {
      this.applyThemeNow();
      AppStorage.setOrCreate('settingsBack', Date.now());
      AppStorage.setOrCreate('settingsSub', '');
      this.rebuildNav();
    }
  }

  /**
   * 从系统设置返回时会走这里：发一个信号让「通知」页重新读一次开关，
   * 否则用户在系统里打开了通知，回到应用还显示「现在没开」。
   */
  onPageShow(): void {
    LinkLog.record('APP', 'fg fromBg=' + (this.wasBackground ? '1' : '0'));
    AppStorage.setOrCreate('notifyProbe', Date.now());
    const fromBg: boolean = this.wasBackground;
    this.wasBackground = false;
    if (fromBg) {
      // 先标记后台恢复补扫并触发 fgProbe，再置 appFg=true，解除「后台停轮询 + 前台吞通知」死锁
      AppStorage.setOrCreate('fgResumeFromBg', true);
      AppStorage.setOrCreate('fgProbe', Date.now());
    }
    AppStorage.setOrCreate('appFg', true);
    if (!this.privacyAccepted) {
      return;
    }
    this.startPresence();
    // 回到前台先重选一次入口：从外面回到家、或切了 Wi-Fi，这一步就能立刻换回局域网
    void this.refreshLan();
    if (!fromBg) {
      AppStorage.setOrCreate('fgProbe', Date.now());
    }
  }

  onPageHide(): void {
    this.wasBackground = true;
    AppStorage.setOrCreate('appFg', false);
    LinkLog.record('APP', 'bg');
    this.stopPresence(true);
  }

  /**
   * 探测 /api/info 并把宿主的 hostId / e2eePub / 新局域网地址回写进 Machines（F08 / L6）。
   */
  private async syncHostMeta(): Promise<void> {
    if (this.token === '' || this.wanBase === '') {
      return;
    }
    try {
      const info = await this.api.info();
      const active = Machines.active();
      if (active !== null) {
        const hid: string = info.hostId !== undefined ? info.hostId : '';
        const pub: string = info.e2eePub !== undefined ? info.e2eePub : '';
        Machines.updateMeta(active.id, hid, pub, this.api.lanCandidates());
      }
      void PushBridge.syncToGateway(this.api);
    } catch (e) {
      // 网络暂不可达时忽略，下次交互重试
    }
  }

  /**
   * 回前台或网络切换时的入口自愈：先选入口（蜂窝直连公网，Wi-Fi 探测局域网）；
   * 再问一次 /api/info 把电脑自报的新地址、hostId 与 e2eePub 合进设备记录；
   * 仅当在 Wi-Fi 下发现了之前未探测过的新局域网地址时才补探一次，避免反复重探拖慢公网。
   */
  private async refreshLan(): Promise<void> {
    if (this.refreshLanBusy) {
      return;
    }
    this.refreshLanBusy = true;
    try {
      const beforeCount: number = this.api.lanCandidates().length;
      await this.api.poke();
      if (this.token === '') {
        return;
      }
      await this.syncHostMeta();
      if (this.netMode === 'wan' || Net.isCellularOnly()) {
        return;
      }
      if (!this.api.isLan() && this.api.lanCandidates().length > beforeCount) {
        await this.api.poke();
      }
    } finally {
      this.refreshLanBusy = false;
    }
  }

  /**
   * 在线心跳：电脑端据此决定 ask_user_question 卡片归谁（电脑端 15 秒超时）。
   * 局域网每 3 秒一次；公网隧道降频到每 9 秒一次且严格防重入，避免在弱网下堆积阻塞业务请求。
   */
  private sendPresenceOnce(): void {
    if (this.presenceBusy || this.token === '' || this.wanBase === '') {
      return;
    }
    this.presenceBusy = true;
    this.api.presence(true, this.openSession).catch(() => {
    }).finally(() => {
      this.presenceBusy = false;
    });
  }

  private startPresence(): void {
    if (this.presenceTimer >= 0) {
      return;
    }
    this.presenceTick = 0;
    this.sendPresenceOnce();
    this.presenceTimer = setInterval(() => {
      this.presenceTick++;
      if (this.api.onWan() && (this.presenceTick % 3 !== 0)) {
        return;
      }
      this.sendPresenceOnce();
    }, 3000);
  }

  private stopPresence(say: boolean): void {
    if (this.presenceTimer >= 0) {
      clearInterval(this.presenceTimer);
      this.presenceTimer = -1;
    }
    if (say) {
      void this.api.presence(false);
    }
  }

  aboutToAppear(): void {
    AppStorage.setOrCreate('settingsSub', '');
    this.applyThemeNow();
    void this.loadCfg();
  }

  aboutToDisappear(): void {
    this.stopPresence(false);
    AppCtx.clearWindow();
  }

  private closeBigImg(): void {
    if (Motion.isVivid(this.motionMode) && this.bigImgGeoId !== '') {
      this.getUIContext().animateTo(Motion.moveOpts(this.motionMode), () => {
        this.bigImg = '';
      });
    } else {
      this.bigImg = '';
    }
  }

  /**
   * 系统返回键：优先关闭全屏看图和合规文档浮层，再退回设置二级页。
   */
  onBackPress(): boolean {
    if (this.bigImg !== '') {
      this.closeBigImg();
      return true;
    }
    if (this.legalOpen) {
      this.legalOpen = false;
      return true;
    }
    const sub = AppStorage.get<string>('settingsSub');
    if (sub !== undefined && sub !== '') {
      AppStorage.setOrCreate('settingsBack', Date.now());
      Haptics.soft();
      return true;
    }
    return false;
  }

  private systemDark(): boolean {
    const stored: boolean | undefined = AppStorage.get<boolean>('sysDark');
    if (stored !== undefined) {
      return stored;
    }
    try {
      const cfg: Configuration = AppCtx.ability().config;
      return cfg.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return true;
    }
  }

  private applyThemeNow(): void {
    applyTheme(this.themeMode, this.systemDark());
  }

  private async loadCfg(): Promise<void> {
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      const pa = await p.get('privacyAccepted', '0') as string;
      this.privacyAccepted = pa === '1';
      const wmc = await p.get('wcMobileCompat', '1') as string;
      const wmp = await p.get('wcAutoDismissPromo', '0') as string;
      const mm = await p.get('motionMode', MOTION_VIVID) as string;
      AppStorage.setOrCreate('wcMobileCompat', wmc !== '0');
      AppStorage.setOrCreate('wcAutoDismissPromo', wmp === '1');
      AppStorage.setOrCreate('motionMode', Motion.normalize(mm));

      let b = await p.get('base', DEFAULT_BASE) as string;
      const tOldBase: string = b;
      let t = await p.get('token', DEFAULT_TOKEN) as string;
      // 令牌优先从资产库读；旧版本只写过 preferences，这里读出来顺手迁进资产库。
      const sec: string = Secret.load();
      if (sec !== '') {
        t = sec;
        if (await p.get('token', '') !== '') {
          await p.put('token', '');
          await p.flush();
        }
      } else if (t !== '' && t !== DEFAULT_TOKEN) {
        if (Secret.save(t)) {
          await p.put('token', '');
          await p.flush();
        }
      }
      const th = await p.get('theme', THEME_AUTO) as string;
      const fw = await p.get('forceWan', '0') as string;
      const al = await p.get('autoLan', '') as string;
      const hp = await p.get('haptics', '1') as string;
      const hd = await p.get('hdsOn', '1') as string;
      const ic = await p.get('appIconStyle', ICON_DARK) as string;
      const nd = await p.get('notifyDone', '1') as string;
      const nb = await p.get('notifyBgOnly', '1') as string;
      const nst = await p.get('notifyShowTitle', '1') as string;
      const es = await p.get('enterSend', '1') as string;
      const ch = await p.get('compactHistory', '0') as string;
      const ts = await p.get('textScale', '1') as string;
      AppStorage.setOrCreate('appIconStyle', AppIcon.normalize(ic));
      void AppIcon.init();
      AppStorage.setOrCreate('notifyDone', nd !== '0');
      AppStorage.setOrCreate('notifyBgOnly', nb !== '0');
      AppStorage.setOrCreate('notifyShowTitle', nst !== '0');
      AppStorage.setOrCreate('enterSend', es !== '0');
      AppStorage.setOrCreate('compactHistory', ch === '1');
      const tsN: number = Number(ts);
      AppStorage.setOrCreate('textScale', tsN > 0 ? tsN : 1);
      const lan = await p.get('lan', '') as string;
      AppStorage.setOrCreate('sendMode', 'queue');
      this.haptics = hp === '1';
      Haptics.enabled = this.haptics;
      this.hdsOn = hd !== '0';
      AppStorage.setOrCreate('hdsOn', this.hdsOn);
      // 兼容旧版 forceWan / autoLan 偏好，统一收敛为 netMode
      const nm = await p.get('netMode', '') as string;
      const legacyForceWan: boolean = fw === '1';
      const legacyAutoLan: boolean = al === '' ? !legacyForceWan : al === '1';
      this.netMode = nm !== '' ? nm : (legacyForceWan ? 'wan' : (legacyAutoLan ? 'auto' : 'wan'));

      let lanSaved: string = lan;
      if (b === '' && lanSaved === '' && DEFAULT_BASE !== '') {
        b = DEFAULT_BASE;
      }
      if (isLanUrl(b)) {
        lanSaved = lanSaved !== '' ? lanSaved : b;
        b = DEFAULT_BASE !== '' ? DEFAULT_BASE : '';
        console.info('DSH_CFG migrate lan-in-base -> ' + lanSaved);
      }
      if (b === '' && lanSaved !== '') {
        b = lanSaved;
        console.info('DSH_CFG base from lan -> ' + b);
      }
      const cur = Machines.active();
      if (cur !== null) {
        b = cur.wan;
        let mt: string = Secret.loadFor(cur.id);
        if (mt === '' && cur.token !== undefined && cur.token !== '') {
          mt = cur.token;
        }
        if (mt === '' && Machines.list().length === 1 && t !== '' && (b === tOldBase || cur.wan === tOldBase)) {
          mt = t;
          Secret.saveFor(cur.id, mt);
        }
        t = mt;
        lanSaved = cur.lan.length > 0 ? cur.lan[0] : '';
        console.info('DSH_MACH restore ' + cur.name + ' ' + cur.wan);
      } else if (b !== '' && t !== '') {
        Machines.upsert(b, t, lanSaved !== '' ? [lanSaved] : [], '', true);
      }
      if (b !== '' && t !== '') {
        this.wanBase = b;
        this.token = t;
        const curHostId: string = cur !== null && cur.hostId !== undefined ? cur.hostId : '';
        const curE2eePub: string = cur !== null && cur.e2eePub !== undefined ? cur.e2eePub : '';
        this.api.rebase(
          b,
          t,
          lanSaved,
          cur !== null ? cur.lan : (lanSaved !== '' ? [lanSaved] : []),
          curHostId,
          curE2eePub
        );
        this.applyNetMode();
        PushBridge.bindApi(this.api);
        this.machineName = Machines.displayName();
        Unread.refresh();
        console.info('DSH_CFG loaded base=' + b + ' netMode=' + this.netMode + ' lan=' + (lanSaved !== '' ? lanSaved : '-'));
        if (this.privacyAccepted) {
          void this.syncHostMeta();
          void PushBridge.syncToGateway(this.api);
        }
      }
      if (th !== this.themeMode) {
        this.themeMode = th;
        this.applyThemeNow();
      }
      if (this.privacyAccepted) {
        Net.start();
        PushBridge.activateAfterPrivacy();
        if (this.token !== '' && this.wanBase !== '') {
          this.startPresence();
        }
      }
      LinkLog.record('APP', 'cfgLoaded motion=' + Motion.normalize(mm) + ' hds=' + (this.hdsOn ? '1' : '0') +
        ' netMode=' + this.netMode + ' hosts=' + String(Machines.list().length));
    } catch (e) {
      console.error('DSH_CFG load failed :: ' + (e as Error).message);
    } finally {
      this.cfgLoaded = true;
    }
  }

  private async acceptPrivacy(): Promise<void> {
    Haptics.soft();
    this.privacyAccepted = true;
    Net.start();
    PushBridge.activateAfterPrivacy();
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('privacyAccepted', '1');
      await p.flush();
    } catch (e) {
      console.error('AM_PRIVACY save failed :: ' + (e as Error).message);
    }
    if (this.token !== '' && this.wanBase !== '') {
      this.startPresence();
      void this.syncHostMeta();
    }
  }

  private async saveCfg(
    b: string,
    t: string,
    lan: string[] = [],
    name: string = '',
    hostId: string = '',
    e2eePub: string = ''
  ): Promise<void> {
    let lanOne: string = lan.length > 0 ? lan[0] : '';
    let wan: string = b;
    if (isLanUrl(b)) {
      lanOne = lanOne !== '' ? lanOne : b;
      wan = isLanUrl(this.wanBase) || this.wanBase === '' ? DEFAULT_BASE : this.wanBase;
    }
    if (wan === '' && lanOne !== '') {
      wan = lanOne;
    }
    const prev = Machines.active();
    const prevId: string = prev !== null ? prev.id : '';
    const lanAll: string[] = [];
    if (lanOne !== '') {
      lanAll.push(lanOne);
    }
    for (let i = 0; i < lan.length; i++) {
      if (lan[i] !== '' && lanAll.indexOf(lan[i]) < 0) {
        lanAll.push(lan[i]);
      }
    }
    const prevTok: string = prev !== null
      ? (Secret.loadFor(prev.id) !== '' ? Secret.loadFor(prev.id) : prev.token)
      : '';
    if (prev !== null && t !== '' && prevTok === t) {
      for (let i = 0; i < prev.lan.length; i++) {
        if (lanAll.indexOf(prev.lan[i]) < 0) {
          lanAll.push(prev.lan[i]);
        }
      }
      const known: string[] = this.api.lanCandidates();
      for (let i = 0; i < known.length; i++) {
        if (lanAll.indexOf(known[i]) < 0) {
          lanAll.push(known[i]);
        }
      }
    }
    const saved = Machines.upsertEx(wan, t, lanAll, name, true, hostId, e2eePub);
    const savedLanOne: string = saved.lan.length > 0 ? saved.lan[0] : '';
    const savedHostId: string = saved.hostId !== undefined ? saved.hostId : hostId;
    const savedPub: string = saved.e2eePub !== undefined ? saved.e2eePub : e2eePub;
    this.wanBase = saved.wan;
    this.token = t;
    this.machineName = saved.name;
    this.api.rebase(saved.wan, t, savedLanOne, saved.lan, savedHostId, savedPub);
    if (saved.id !== prevId) {
      this.stack.clear(false);
      this.bumpMachineEpoch();
    }
    Unread.refresh();
    AppStorage.setOrCreate('listDirty', Date.now());
    this.applyNetMode();
    PushBridge.bindApi(this.api);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('base', saved.wan);
      await p.put('token', Secret.save(t) ? '' : t);
      await p.put('lan', savedLanOne);
      await p.flush();
      console.info('DSH_CFG saved base=' + saved.wan + ' lan=' + (savedLanOne !== '' ? savedLanOne : '-'));
    } catch (e) {
      console.error('DSH_CFG save failed :: ' + (e as Error).message);
    }
    if (this.privacyAccepted) {
      this.startPresence();
      void this.syncHostMeta();
      void PushBridge.syncToGateway(this.api, true);
    }
  }

  /** 清空当前活跃配对并停止网络活动。 */
  private async clearActivePairing(): Promise<void> {
    void PushBridge.unregisterGateway(this.api);
    this.stopPresence(false);
    this.wanBase = '';
    this.token = '';
    this.machineName = '';
    this.api.rebase('', '', '', [], '', '');
    this.stack.clear(false);
    this.bumpMachineEpoch();
    Secret.clear();
    Unread.refresh();
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('base', '');
      await p.put('token', '');
      await p.put('lan', '');
      await p.flush();
    } catch (e) {
      console.error('DSH_CFG clear failed :: ' + (e as Error).message);
    }
  }

  /** 切到另一台已配对的电脑：地址、令牌、当前名严格按机器隔离切换。 */
  private async switchMachine(id: string): Promise<void> {
    const m = Machines.activate(id);
    if (m === null) {
      return;
    }
    let mt: string = Secret.loadFor(m.id);
    if (mt === '' && m.token !== undefined && m.token !== '') {
      mt = m.token;
      if (Secret.saveFor(m.id, mt)) {
        m.token = '';
      }
    }
    if (mt === '') {
      Toast.err('这台电脑的访问令牌已失效，请在连接页重新配对');
      this.wanBase = m.wan;
      this.token = '';
      this.machineName = m.name;
      this.api.rebase('', '', '', [], '', '');
      this.stack.clear(false);
      this.bumpMachineEpoch();
      Unread.refresh();
      return;
    }
    this.wanBase = m.wan;
    this.token = mt;
    this.machineName = m.name;
    this.api.rebase(
      m.wan,
      mt,
      m.lan.length > 0 ? m.lan[0] : '',
      m.lan,
      m.hostId !== undefined ? m.hostId : '',
      m.e2eePub !== undefined ? m.e2eePub : ''
    );
    this.stack.clear(false);
    this.bumpMachineEpoch();
    Unread.refresh();
    this.applyNetMode();
    PushBridge.bindApi(this.api);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('base', m.wan);
      const savedPrimary: boolean = Secret.save(mt);
      await p.put('token', savedPrimary ? '' : mt);
      await p.put('lan', m.lan.length > 0 ? m.lan[0] : '');
      await p.flush();
    } catch (e) {
      console.error('DSH_MACH switch save fail :: ' + (e as Error).message);
    }
    console.info('DSH_MACH switch ' + m.name + ' ' + m.wan);
    AppStorage.setOrCreate('listDirty', Date.now());
    if (this.privacyAccepted) {
      this.startPresence();
      void this.syncHostMeta();
      void PushBridge.syncToGateway(this.api, true);
    }
  }

  /** 忘掉一台电脑；删的是最后一台时清空活跃配对，否则切到剩下的第一台。 */
  private async removeMachine(id: string): Promise<void> {
    Machines.remove(id);
    const cur = Machines.active();
    if (cur !== null) {
      await this.switchMachine(cur.id);
    } else {
      await this.clearActivePairing();
    }
  }

  /** 把 netMode 同步到 Api；三处入口（读配置、保存、切电脑）都走它。 */
  private applyNetMode(): void {
    const isWan: boolean = this.netMode === 'wan';
    this.api.setForceWan(isWan);
    this.api.setAutoLan(!isWan);
    this.api.setLanOnly(this.netMode === 'lan');
  }

  private async saveNetMode(mode: string): Promise<void> {
    this.netMode = mode;
    this.applyNetMode();
    console.info('DSH_CFG netMode=' + mode);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('netMode', mode);
      // 保留旧键写入以兼容旧版本回退
      await p.put('forceWan', this.netMode === 'wan' ? '1' : '0');
      await p.put('autoLan', this.netMode === 'auto' ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_CFG netMode save failed :: ' + (e as Error).message);
    }
  }

  private async saveTheme(mode: string): Promise<void> {
    this.themeMode = mode;
    this.applyThemeNow();
    AppStorage.setOrCreate('settingsBack', Date.now());
    AppStorage.setOrCreate('settingsSub', '');
    this.rebuildNav();
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('theme', mode);
      await p.flush();
    } catch (e) {
      console.error('DSH_THEME save failed :: ' + (e as Error).message);
    }
  }

  /** 换主题后让被压栈的页面用新配色重建，但不把用户送回首页 */
  private rebuildNav(): void {
    try {
      const names: string[] = this.stack.getAllPathName();
      if (names.length === 0) {
        return;
      }
      const params: Object[] = [];
      for (let i = 0; i < names.length; i++) {
        params.push(this.stack.getParamByIndex(i) as ChatParam);
      }
      this.stack.clear(false);
      const rev: number = ++this.navRev;
      setTimeout(() => {
        if (rev !== this.navRev || this.stack.getAllPathName().length !== 0) {
          return;
        }
        for (let i = 0; i < names.length; i++) {
          if (names[i].length === 0) {
            continue;
          }
          this.stack.pushPathByName(names[i], params[i], false);
        }
      }, 40);
    } catch (e) {
      console.error('DSH_THEME rebuild nav failed :: ' + (e as Error).message);
    }
  }

  /** 连点开关时只让最后一次落盘，避免旧值后到覆盖新值 */
  private hapticsSeq: number = 0;

  private async saveHaptics(v: boolean): Promise<void> {
    this.haptics = v;
    Haptics.enabled = v;
    const seq: number = ++this.hapticsSeq;
    if (v) {
      Haptics.toggle(true);
    }
    console.info('DSH_HAP enabled=' + v + ' seq=' + seq);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      if (seq !== this.hapticsSeq) {
        return;
      }
      await p.put('haptics', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_HAP save failed :: ' + (e as Error).message);
    }
  }

  /** 沉浸光感开关：关掉后所有系统材质退回普通底色，并立即刷新界面。 */
  private async saveHds(v: boolean): Promise<void> {
    this.hdsOn = v;
    AppStorage.setOrCreate('hdsOn', v);
    if (v) {
      Haptics.toggle(true);
    }
    console.info('DSH_HDS switch=' + v);
    try {
      const p = await preferences.getPreferences(AppCtx.ability(), PREF_STORE);
      await p.put('hdsOn', v ? '1' : '0');
      await p.flush();
    } catch (e) {
      console.error('DSH_HDS save failed :: ' + (e as Error).message);
    }
  }

  @Builder
  splashView() {
    Column({ space: 12 }) {
      Image(Tokens.isDark ? $r('app.media.start_window_icon_dark') : $r('app.media.start_window_icon_light'))
        .width(84)
        .height(84)
        .objectFit(ImageFit.Contain)
      Text('Agent Mobile')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.fg)
      Text('正在准备本地工作区…')
        .fontSize(Tokens.fsCaption)
        .fontColor(Tokens.dim2)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.themeBg)
  }

  @Builder
  privacyGateView() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Column({ space: 14 }) {
          Image(AppIcon.res(this.appIconStyle))
            .width(64)
            .height(64)
            .borderRadius(16)
            .border({ width: 0.5, color: Tokens.line })
          Text('欢迎使用 Agent Mobile')
            .fontSize(21)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.fg)
          Text('Agent Mobile 是一款智能体远程控制与对话客户端，仅在你主动配对后连接你自己的电脑网关服务。我们不会收集你的聊天记录或上传无关个人数据。')
            .fontSize(Tokens.fsBody)
            .fontColor(Tokens.dim)
            .lineHeight(21)
            .textAlign(TextAlign.Start)
            .width('100%')
          Text('在使用扫码配对、附件上传、通知提醒等能力时，应用仅按需调用相机、文件选择、通知与系统凭据存储，所有令牌和加密私钥均保存在本机受保护存储中。')
            .fontSize(Tokens.fsCaption)
            .fontColor(Tokens.dim2)
            .lineHeight(19)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            Text('继续前请阅读并同意：')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.dim2)
            Text('《隐私政策》')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .fontWeight(FontWeight.Medium)
              .margin({ right: 6 })
              .onClick(() => {
                Haptics.tap();
                this.legalKind = 'privacy';
                this.legalOpen = true;
              })
            Text('《用户协议》')
              .fontSize(Tokens.fsCaption)
              .fontColor(Tokens.accent)
              .fontWeight(FontWeight.Medium)
              .onClick(() => {
                Haptics.tap();
                this.legalKind = 'terms';
                this.legalOpen = true;
              })
          }
          .width('100%')

          Row({ space: 10 }) {
            Text('暂不使用')
              .fontSize(Tokens.fsBody)
              .fontColor(Tokens.dim)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(Tokens.surface2)
              .borderRadius(Tokens.rInput)
              .onClick(() => {
                Haptics.tap();
                try {
                  void AppCtx.ability().terminateSelf();
                } catch (e) {
                }
              })
            Text('同意并继续')
              .fontSize(Tokens.fsBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.accentInk)
              .textAlign(TextAlign.Center)
              .layoutWeight(1.4)
              .padding({ top: 12, bottom: 12 })
              .backgroundColor(Tokens.accent)
              .borderRadius(Tokens.rInput)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
              .onClick(() => {
                void this.acceptPrivacy();
              })
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .constraintSize({ maxWidth: 440 })
        .padding(22)
        .backgroundColor(Tokens.surface)
        .borderRadius(Tokens.rXl)
        .border({ width: 1, color: Tokens.line })
      }
      .width('100%')
      .padding({ left: 20, right: 20 })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.themeBg)
    .bindSheet($$this.legalOpen, this.legalSheetView(),
      Mat.sheetOpts(this.hdsOn, '74%', () => {
        this.legalOpen = false;
      }))
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

  @Builder
  pageMap(name: string, param: ChatParam) {
    if (name === 'chat') {
      ChatPage({ api: this.api, param: param })
    } else if (name === 'presets') {
      PresetsPage({ api: this.api, param: param })
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (!this.cfgLoaded) {
        this.splashView()
      } else if (!this.privacyAccepted) {
        this.privacyGateView()
      } else {
        Navigation(this.stack) {
          Stack() {
            if (this.token !== '') {
              ForEach([this.themeRev], (rev: number) => {
                ShellPage({
                  api: this.api,
                  wanBase: this.wanBase,
                  token0: this.token,
                  themeMode: this.themeMode,
                  systemDark: this.systemDark(),
                  netMode: this.netMode,
                  haptics: this.haptics,
                  defaultLan: LAN_BASE,
                  onReset: () => {
                    const cur = Machines.active();
                    if (cur !== null) {
                      Machines.remove(cur.id);
                    }
                    const next = Machines.active();
                    if (next !== null) {
                      void this.switchMachine(next.id);
                    } else {
                      void this.clearActivePairing();
                    }
                  },
                  onSave: (b: string, t: string) => {
                    void this.saveCfg(b, t, []);
                  },
                  machineName: this.machineName,
                  onPickMachine: (id: string) => {
                    void this.switchMachine(id);
                  },
                  onRemoveMachine: (id: string) => {
                    void this.removeMachine(id);
                  },
                  onAddMachine: (wan: string, token: string, name: string) => {
                    void this.saveCfg(wan, token, [], name);
                  },
                  onSaveLan: (b: string, t: string, lan: string[], hostId?: string, e2eePub?: string, hostName?: string) => {
                    void this.saveCfg(b, t, lan, hostName !== undefined ? hostName : '',
                      hostId !== undefined ? hostId : '', e2eePub !== undefined ? e2eePub : '');
                  },
                  onTheme: (m: string) => {
                    void this.saveTheme(m);
                  },
                  onNetMode: (m: string) => {
                    void this.saveNetMode(m);
                  },
                  onHaptics: (v: boolean) => {
                    void this.saveHaptics(v);
                  },
                  onHds: (v: boolean) => {
                    void this.saveHds(v);
                  }
                })
              }, (rev: number) => 'shell-' + rev)
            } else {
              PairPage({
                api: this.api,
                defaultBase: '',
                hasBack: false,
                onExit: () => {
                },
                onPaired: (b: string, t: string, host: string, lan: string[], hostId?: string, e2eePub?: string) => {
                  void this.saveCfg(b, t, lan, host, hostId !== undefined ? hostId : '', e2eePub !== undefined ? e2eePub : '');
                }
              })
            }
          }
          .width('100%')
          .height('100%')
        }
        .navDestination(this.pageMap)
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .hideToolBar(true)
        .backgroundColor(this.themeBg)
        .width('100%')
        .height('100%')
      }

      // 旗舰液态玻璃弹簧 Toast 顶层宿主（外层声明 HitTestMode.None 彻底透传全部触控）
      Row() {
        GlassToastHost()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // 全屏看图：挂在 Navigation 外面，才能盖住状态栏和标题栏；灵动档启用 geometryTransition 一镜到底
      if (this.bigImg !== '') {
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width('100%')
            .height('100%')
            .backgroundColor('#F2000000')
            .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
          Image(this.bigImg)
            .width('100%')
            .objectFit(ImageFit.Contain)
            .geometryTransition(Motion.geoId(this.bigImgGeoId, this.motionMode), { follow: false })
        }
        .width('100%')
        .height('100%')
        .onClick(() => {
          this.closeBigImg();
        })
        .transition(Motion.isVivid(this.motionMode)
          ? TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std })
          : TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
  }
}
