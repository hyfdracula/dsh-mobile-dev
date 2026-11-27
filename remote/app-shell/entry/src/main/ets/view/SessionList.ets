import { HdsNavigation, HdsNavigationTitleBarOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import {
  Api,
  BackendCapabilities,
  BackendInfo,
  PreviewRow,
  SessionRow,
  backendIdOfSession,
  backendLabelOf,
  defaultBackendCapabilities
} from '../common/Api';
import { Mat } from '../common/Mat';
import { Tokens } from '../common/Tokens';
import { BloomWaveTracker, Motion, MOTION_VIVID } from '../common/Motion';
import { TopFade, buildTransparentHdsTitle } from '../common/Chrome';
import { EmptyState } from '../common/Widgets';
import { copyText } from '../common/Clipboard';
import { Haptics } from '../common/Haptics';
import { Toast } from '../common/Toast';
import { Unread } from '../common/Unread';
import { ChatParam } from '../common/Types';
import {
  ListViewPrefs, RowModel, SessionDataSource, WsBuildResult, WsOpt,
  buildSessionRowModels, buildWsOptions, collectGroupLabels,
  collectRecentWsChoices, normCwdKey, plainPreview, readCachedPreviews, readListViewPrefs, resolveBaseCwd,
  sigOfSessionRows, tidyCwd, writeCachedPreviews, writeListViewPrefs, wsLeafName
} from './session/SessionModels';
import { SessionTile } from './session/SessionTile';
import { SessionHeaderBar } from './session/SessionHeaderBar';
import { WorkspaceSheet } from './session/WorkspaceSheet';
import {
  SessionBatchBar, SessionListEmptyView, SessionLoadingBox, SessionNewFab, SessionRenameSheet
} from './session/SessionOverlays';

export { SessionTile } from './session/SessionTile';

/**
 * 第一栏：会话列表主视图与状态协调器（F01 / F02 / F05 / F12 / L3 / L4）：
 * - 全屏 Stack 自绘 TopFade + 浮动玻璃顶栏，彻底避让状态栏与挖孔区（F02）
 * - 未读新回复胶囊条定位查看与一键全部已读闭环清理（F12）
 * - 宽屏与折叠屏展开态居中限宽 760vp 自适应布局（L4）
 */
@Component
export struct SessionList {
  api: Api = new Api('', '');
  @Consume('stack') stack: NavPathStack;
  @Prop machineName: string = '';
  onPickMachine: (id: string) => void = () => {};

  @StorageLink('topInset') topInset: number = 40;
  @StorageLink('bottomInset') bottomInset: number = 20;
  @StorageLink('themeBg') themeBg: string = Tokens.bg;
  @StorageLink('hdsOn') hdsOn: boolean = true;
  @StorageLink('themeDark') themeDark: boolean = true;
  @StorageLink('motionMode') motionMode: string = MOTION_VIVID;
  @StorageLink('online') online: boolean = true;
  @StorageLink('wideScreen') wideScreen: boolean = false;
  @StorageLink('unreadCount') unreadCount: number = 0;
  @StorageLink('unreadVer') unreadVer: number = 0;
  @StorageLink('marksVer') @Watch('onMarksVer') marksVer: number = 0;
  @StorageLink('listDirty') @Watch('onListDirty') listDirty: number = 0;
  @StorageLink('backendsDirty') @Watch('onBackendsDirty') backendsDirty: number = 0;
  @StorageLink('sharedSessionsTick') @Watch('onSharedSessions') sharedSessionsTick: number = 0;
  @StorageLink('openSessionReq') @Watch('onOpenReq') openReq: string = '';

  @State private backends: BackendInfo[] = [];
  @State private backendFilter: string = 'all';
  @State private allRows: SessionRow[] = [];
  @State private rows: SessionRow[] = [];
  @State private wsOpts: WsOpt[] = [];
  @State private rowCount: number = 0;
  private previewTextMap: Map<string, string> = new Map<string, string>();
  private previewCountMap: Map<string, number> = new Map<string, number>();
  private dataSource: SessionDataSource = new SessionDataSource();

  @State private loading: boolean = true;
  @State private pullState: RefreshStatus = RefreshStatus.Inactive;
  @State private loadSlow: boolean = false;
  @State private timedOut: boolean = false;
  @State private refreshing: boolean = false;
  @State private creating: boolean = false;
  @State private err: string = '';

  @State private groupBy: string = 'time';
  @State private listState: string = 'all';
  @State private sortBy: string = 'recent';
  @State private archivedView: boolean = false;
  @State private folded: string[] = [];

  @State private q: string = '';
  @State private searching: boolean = false;
  @State private wsFilter: string = '';
  @State private wsFilterLabel: string = '';

  @State @Watch('syncSheet') private selectOn: boolean = false;
  @State private selected: string[] = [];
  @State @Watch('syncSheet') private renameOn: boolean = false;
  @State private renameId: string = '';
  @State private renameText: string = '';
  @State @Watch('syncSheet') private wsSheetOn: boolean = false;
  @State private wsSheetTab: string = 'pick';
  @State @Watch('syncSheet') private headerSheetOn: boolean = false;

  @State private listEntered: boolean = false;
  private wave: BloomWaveTracker = new BloomWaveTracker();
  private scroller: Scroller = new Scroller();
  private loadStart: number = 0;
  private slowTimer: number = -1;
  private loadGen: number = 0;
  private rowSig: string = '';
  private poll: number = 0;
  private revealDone: boolean = false;
  private revealFinishAt: number = 0;
  private revealTimer: number = -1;
  private previewFlushTimer: number = -1;
  private backendsFlushTimer: number = -1;
  private coldRevealInFlight: boolean = false;

  aboutToAppear(): void {
    const prefs: ListViewPrefs = readListViewPrefs();
    this.groupBy = prefs.groupBy;
    this.listState = prefs.listState;
    this.sortBy = prefs.sortBy;
    readCachedPreviews(this.previewTextMap, this.previewCountMap);

    const age: number = Date.now() - this.api.cachedSessionsUpdatedAt();
    if (this.api.cachedSessionsUpdatedAt() > 0 && age < 8000) {
      this.applyFetchedRows(this.api.cachedSessions());
      this.loading = false;
      this.triggerInitialReveal();
    } else {
      void this.load(true);
    }
    void this.loadBackends();

    this.poll = setInterval(() => {
      if (AppStorage.get<boolean>('appFg') === false) {
        return;
      }
      const tab: number | undefined = AppStorage.get<number>('shellTab');
      if (tab !== undefined && tab !== 0) {
        return;
      }
      if (Date.now() - this.api.cachedSessionsUpdatedAt() < 10000 && !this.loading) {
        return;
      }
      void this.pollRows();
    }, 10000);
  }

  aboutToDisappear(): void {
    if (this.poll !== 0) {
      clearInterval(this.poll);
      this.poll = 0;
    }
    if (this.slowTimer !== -1) {
      clearTimeout(this.slowTimer);
      this.slowTimer = -1;
    }
    if (this.revealTimer !== -1) {
      clearTimeout(this.revealTimer);
      this.revealTimer = -1;
    }
    if (this.previewFlushTimer !== -1) {
      clearTimeout(this.previewFlushTimer);
      this.previewFlushTimer = -1;
    }
    if (this.backendsFlushTimer !== -1) {
      clearTimeout(this.backendsFlushTimer);
      this.backendsFlushTimer = -1;
    }
    AppStorage.setOrCreate('sheetOpen', false);
  }

  private syncSheet(): void {
    AppStorage.setOrCreate('sheetOpen',
      this.selectOn || this.renameOn || this.wsSheetOn || this.headerSheetOn);
  }

  private onOpenReq(): void {
    const raw: string = this.openReq;
    if (raw === '') {
      return;
    }
    this.openReq = '';
    const cut: number = raw.lastIndexOf('|');
    const id: string = cut > 0 ? raw.substring(0, cut) : raw;
    if (id === '') {
      return;
    }
    Unread.markRead(id);
    const row: SessionRow | undefined = this.allRows.find((r: SessionRow) => r.id === id);
    const p: ChatParam = { id: id, title: row === undefined ? '' : row.title };
    this.stack.pushPathByName('chat', p);
  }

  private onListDirty(): void {
    if (!this.loading) {
      void this.load(true);
    }
  }

  private onSharedSessions(): void {
    if (this.sharedSessionsTick <= 0 || this.renameOn || this.creating) {
      return;
    }
    this.timedOut = false;
    this.err = '';
    if (this.loading) {
      void this.finishColdApply(this.api.cachedSessions(), false);
      return;
    }
    this.applyFetchedRows(this.api.cachedSessions());
    this.triggerInitialReveal();
  }

  private onMarksVer(): void {
    if (this.marksVer >= 0) {
      this.rebuildModels();
    }
  }

  private openFirstUnread(): void {
    Haptics.tap();
    const pool: SessionRow[] = this.archivedView ? this.allRows : this.rows;
    let target: SessionRow | undefined = pool.find((r: SessionRow) => r.archived !== true && Unread.has(r.id));
    if (target === undefined) {
      target = this.allRows.find((r: SessionRow) => Unread.has(r.id));
    }
    if (target !== undefined) {
      Unread.markRead(target.id);
      const p: ChatParam = { id: target.id, title: target.title };
      this.stack.pushPathByName('chat', p);
      return;
    }
    const ids: string[] = Unread.ids();
    if (ids.length > 0) {
      Unread.markRead(ids[0]);
      const p: ChatParam = { id: ids[0], title: '' };
      this.stack.pushPathByName('chat', p);
    } else {
      Unread.clearAll();
    }
  }

  private clearAllUnread(): void {
    Haptics.tap();
    Unread.clearAll();
    Toast.ok('已全部标为已读');
  }

  private triggerInitialReveal(): void {
    if (this.revealDone || this.loading) {
      return;
    }
    this.revealDone = true;
    if (this.rowCount === 0 || !Motion.isFlagship(this.motionMode)) {
      this.listEntered = true;
      this.revealFinishAt = 0;
      return;
    }
    const visN: number = this.rowCount > 14 ? 14 : this.rowCount;
    this.revealFinishAt = Date.now() + Motion.bloomTotalMsBySpan(
      this.wave.maxVisibleSpan(visN * Motion.BLOOM_FALLBACK_STEP_VP), 20);
    if (this.revealTimer !== -1) {
      clearTimeout(this.revealTimer);
    }
    this.revealTimer = setTimeout(() => {
      this.revealTimer = -1;
      this.listEntered = true;
    }, 28);
  }

  private scheduleRebuildAfterReveal(): void {
    const remain: number = this.revealFinishAt - Date.now();
    if (remain <= 0) {
      this.rebuildModels();
      return;
    }
    if (this.previewFlushTimer !== -1) {
      clearTimeout(this.previewFlushTimer);
    }
    this.previewFlushTimer = setTimeout(() => {
      this.previewFlushTimer = -1;
      this.rebuildModels();
    }, remain + 24);
  }

  private orderedActiveIds(fetched: SessionRow[], limit: number): string[] {
    const active: SessionRow[] = fetched.filter((r: SessionRow) => r.archived !== true);
    active.sort((a: SessionRow, b: SessionRow) => {
      const pa: number = a.pinned === true ? 0 : 1;
      const pb: number = b.pinned === true ? 0 : 1;
      if (pa !== pb) {
        return pa - pb;
      }
      return b.updatedAt - a.updatedAt;
    });
    const ids: string[] = [];
    for (let i = 0; i < active.length && ids.length < limit; i++) {
      const id: string = active[i].id;
      if (id !== '' && ids.indexOf(id) < 0) {
        ids.push(id);
      }
    }
    return ids;
  }

  private async prefetchInitialPreviews(fetched: SessionRow[], timeoutMs: number): Promise<void> {
    const ordered: string[] = this.orderedActiveIds(fetched, 24);
    if (ordered.length === 0) {
      return;
    }
    const topCheck: number = ordered.length < 12 ? ordered.length : 12;
    let missingTop: number = 0;
    for (let i = 0; i < topCheck; i++) {
      if (!this.previewTextMap.has(ordered[i])) {
        missingTop++;
      }
    }
    if (missingTop === 0) {
      return;
    }
    const ids: string[] = [];
    for (let i = 0; i < ordered.length; i++) {
      if (!this.previewTextMap.has(ordered[i])) {
        ids.push(ordered[i]);
      }
    }
    if (ids.length === 0) {
      return;
    }
    let timer: number = -1;
    const timeoutPromise: Promise<PreviewRow[]> = new Promise<PreviewRow[]>((resolve) => {
      timer = setTimeout(() => {
        timer = -1;
        resolve([]);
      }, timeoutMs);
    });
    const fetchPromise: Promise<PreviewRow[]> = this.api.previews(ids).catch((): PreviewRow[] => []);
    try {
      const got: PreviewRow[] = await Promise.race([fetchPromise, timeoutPromise]);
      for (let i = 0; i < got.length; i++) {
        const clean: string = plainPreview(got[i].preview);
        const cnt: number = got[i].count === undefined ? 0 : got[i].count;
        this.previewTextMap.set(got[i].id, clean);
        this.previewCountMap.set(got[i].id, cnt);
      }
      if (got.length > 0) {
        writeCachedPreviews(this.previewTextMap, this.previewCountMap, this.orderedActiveIds(fetched, 80));
      }
    } catch (e) {
    } finally {
      if (timer !== -1) {
        clearTimeout(timer);
        timer = -1;
      }
    }
  }

  private async finishColdApply(fetched: SessionRow[], clearSig: boolean): Promise<void> {
    if (!this.loading || this.coldRevealInFlight) {
      return;
    }
    this.coldRevealInFlight = true;
    try {
      for (let i = 0; i < fetched.length; i++) {
        const r: SessionRow = fetched[i];
        if (r.preview !== undefined && r.preview !== '' && !this.previewTextMap.has(r.id)) {
          this.previewTextMap.set(r.id, plainPreview(r.preview));
        }
      }
      const timeoutMs: number = this.api.onWan() ? 1400 : 800;
      await this.prefetchInitialPreviews(fetched, timeoutMs);
      if (clearSig) {
        this.rowSig = '';
      }
      this.applyFetchedRows(fetched);
      this.loading = false;
      this.loadSlow = false;
      if (this.slowTimer !== -1) {
        clearTimeout(this.slowTimer);
        this.slowTimer = -1;
      }
      this.triggerInitialReveal();
    } finally {
      this.coldRevealInFlight = false;
    }
  }

  private applyFetchedRows(fetched: SessionRow[]): void {
    const sig: string = sigOfSessionRows(fetched) + '|arch=' + (this.archivedView ? '1' : '0');
    this.allRows = fetched;
    if (sig === this.rowSig && !this.loading) {
      return;
    }
    this.rowSig = sig;
    const want: boolean = this.archivedView;
    const filtered: SessionRow[] = fetched.filter((r: SessionRow) => (r.archived === true) === want);
    filtered.sort((a: SessionRow, b: SessionRow) => b.updatedAt - a.updatedAt);
    this.rows = filtered;
    const wsRes: WsBuildResult = buildWsOptions(filtered, this.wsFilter);
    this.wsOpts = wsRes.opts;
    this.wsFilterLabel = wsRes.filterLabel;
    this.applyListState(false);
    this.rebuildModels();
    void this.loadPreviews();
  }

  private async pollRows(): Promise<void> {
    if (this.loading) {
      const limitMs: number = this.api.onWan() ? 18000 : 10000;
      if (Date.now() - this.loadStart < limitMs) {
        return;
      }
      this.loading = false;
      this.loadSlow = false;
      this.timedOut = true;
    }
    if (this.renameOn || this.creating) {
      return;
    }
    try {
      const fetched: SessionRow[] = await this.api.sessions();
      this.api.cacheSessions(fetched);
      this.timedOut = false;
      this.applyFetchedRows(fetched);
    } catch (e) {
    }
  }

  private async load(forceNetwork: boolean = true, clearSig: boolean = false): Promise<void> {
    if (!forceNetwork) {
      const age: number = Date.now() - this.api.cachedSessionsUpdatedAt();
      if (this.api.cachedSessionsUpdatedAt() > 0 && age < 6000) {
        this.err = '';
        this.timedOut = false;
        this.applyFetchedRows(this.api.cachedSessions());
        this.loading = false;
        this.loadSlow = false;
        this.triggerInitialReveal();
        return;
      }
    }
    this.loadGen++;
    const gen: number = this.loadGen;
    this.loadStart = Date.now();
    if (this.slowTimer !== -1) {
      clearTimeout(this.slowTimer);
    }
    this.slowTimer = setTimeout(() => {
      this.slowTimer = -1;
      if (gen === this.loadGen) {
        this.loadSlow = true;
      }
    }, 6000);

    try {
      this.err = '';
      const fetched: SessionRow[] = await this.api.sessions();
      if (gen !== this.loadGen) {
        return;
      }
      this.api.cacheSessions(fetched);
      this.timedOut = false;
      if (this.loading) {
        await this.finishColdApply(fetched, clearSig);
      } else {
        if (clearSig) {
          this.rowSig = '';
        }
        this.applyFetchedRows(fetched);
      }
    } catch (e) {
      if (gen !== this.loadGen) {
        return;
      }
      this.err = (e as Error).message;
    } finally {
      if (gen === this.loadGen && this.loading && !this.coldRevealInFlight) {
        this.loading = false;
        this.loadSlow = false;
        if (this.slowTimer !== -1) {
          clearTimeout(this.slowTimer);
          this.slowTimer = -1;
        }
        this.triggerInitialReveal();
      }
    }
  }

  private async loadPreviews(): Promise<void> {
    try {
      const ids: string[] = [];
      const total: number = this.dataSource.totalCount();
      for (let i = 0; i < total && ids.length < 60; i++) {
        const m: RowModel = this.dataSource.getData(i);
        if (m.kind === 'row' && ids.indexOf(m.row.id) < 0) {
          ids.push(m.row.id);
        }
      }
      if (ids.length === 0) {
        return;
      }
      const got: PreviewRow[] = await this.api.previews(ids);
      let changed: boolean = false;
      for (let i = 0; i < got.length; i++) {
        const clean: string = plainPreview(got[i].preview);
        const cnt: number = got[i].count === undefined ? 0 : got[i].count;
        if (this.previewTextMap.get(got[i].id) !== clean || this.previewCountMap.get(got[i].id) !== cnt) {
          this.previewTextMap.set(got[i].id, clean);
          this.previewCountMap.set(got[i].id, cnt);
          changed = true;
        }
      }
      if (changed) {
        writeCachedPreviews(this.previewTextMap, this.previewCountMap, this.orderedActiveIds(this.allRows, 80));
        this.scheduleRebuildAfterReveal();
      }
    } catch (e) {
    }
  }

  private onBackendsDirty(): void {
    void this.loadBackends();
    void this.load(true);
  }

  private applyBackendsList(list: BackendInfo[]): void {
    this.backends = list;
    if (this.backendFilter !== 'all') {
      const stillOn: boolean = list.some((b: BackendInfo): boolean => b.id === this.backendFilter && b.enabled);
      if (!stillOn) {
        this.backendFilter = 'all';
        this.rebuildModels();
      }
    }
  }

  private async loadBackends(): Promise<void> {
    try {
      const list: BackendInfo[] = await this.api.backends(false);
      const remain: number = this.revealFinishAt - Date.now();
      if (this.backends.length === 0 && remain > 0) {
        if (this.backendsFlushTimer !== -1) {
          clearTimeout(this.backendsFlushTimer);
        }
        this.backendsFlushTimer = setTimeout(() => {
          this.backendsFlushTimer = -1;
          this.applyBackendsList(list);
        }, remain + 24);
        return;
      }
      this.applyBackendsList(list);
    } catch (e) {
      // 旧网关无 /api/backends 时静默保持仅 DSH 模式
    }
  }

  private enabledBackends(): BackendInfo[] {
    return this.backends.filter((b: BackendInfo): boolean => b.enabled);
  }

  private capsForRow(r: SessionRow): BackendCapabilities {
    const bid: string = (r.backend !== undefined && r.backend !== '') ? r.backend : backendIdOfSession(r.id);
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].id === bid && this.backends[i].capabilities !== undefined) {
        return this.backends[i].capabilities;
      }
    }
    return defaultBackendCapabilities(bid);
  }

  private rebuildModels(): void {
    for (let i = 0; i < this.rows.length; i++) {
      const r: SessionRow = this.rows[i];
      if (r.preview !== undefined && r.preview !== '' && !this.previewTextMap.has(r.id)) {
        this.previewTextMap.set(r.id, plainPreview(r.preview));
      }
    }
    const filtered: SessionRow[] = this.backendFilter === 'all'
      ? this.rows
      : this.rows.filter((r: SessionRow): boolean => {
          const bid: string = (r.backend !== undefined && r.backend !== '') ? r.backend : backendIdOfSession(r.id);
          return bid === this.backendFilter;
        });
    const out: RowModel[] = buildSessionRowModels(
      filtered, this.q, this.wsFilter, this.sortBy, this.groupBy,
      this.archivedView, this.folded, this.selectOn, this.selected,
      this.previewTextMap, this.previewCountMap
    );
    this.rowCount = out.length;
    this.dataSource.replaceAll(out);
  }

  private applyListState(rebuild: boolean = true): void {
    if (this.listState === 'all') {
      this.folded = [];
    } else {
      const labels: string[] = collectGroupLabels(this.rows, this.groupBy, this.archivedView);
      this.folded = this.listState === 'none' ? labels : (labels.length > 1 ? labels.slice(1) : []);
    }
    if (rebuild) {
      this.rebuildModels();
    }
  }

  private isFolded(label: string): boolean {
    return this.folded.indexOf(label) >= 0;
  }

  private toggleFold(label: string): void {
    Haptics.tap();
    this.folded = this.isFolded(label)
      ? this.folded.filter((s: string) => s !== label)
      : this.folded.concat([label]);
    this.rebuildModels();
  }

  private setArchivedMode(want: boolean): void {
    if (this.archivedView === want) {
      return;
    }
    Haptics.tap();
    this.selectOn = false;
    this.selected = [];
    this.archivedView = want;
    this.rowSig = '';
    if (this.allRows.length > 0) {
      this.applyFetchedRows(this.allRows);
    } else {
      this.loading = true;
    }
    void this.load(true);
  }

  private async newSessionIn(dir: string, backend: string = 'dsh'): Promise<void> {
    if (this.creating) {
      return;
    }
    this.creating = true;
    try {
      const fallbackDir: string = resolveBaseCwd(this.wsOpts, this.wsFilter, this.allRows);
      const cwd: string = dir !== '' ? tidyCwd(dir) : fallbackDir;
      const targetBackend: string = backend !== '' ? backend : 'dsh';
      const id: string = await this.api.createSession(cwd, targetBackend);
      this.wsSheetOn = false;
      if (cwd !== '' && !this.archivedView && this.wsFilter !== '') {
        this.wsFilter = normCwdKey(cwd);
      }
      const bLabel: string = targetBackend !== 'dsh' ? (backendLabelOf(targetBackend) + ' ') : '';
      Toast.ok(cwd !== '' ? ('已在「' + wsLeafName(cwd) + '」新建 ' + bLabel + '会话') : ('已新建 ' + bLabel + '会话'));
      void this.load(true);
      if (id !== '') {
        const p: ChatParam = { id: id, title: targetBackend !== 'dsh' ? (backendLabelOf(targetBackend) + ' 新会话') : '新会话' };
        this.stack.pushPathByName('chat', p);
      }
    } catch (e) {
      Toast.err('新建失败：' + (e as Error).message);
    } finally {
      this.creating = false;
    }
  }

  private async doPin(r: SessionRow): Promise<void> {
    const want: boolean = r.pinned !== true;
    Haptics.soft();
    try {
      await this.api.pin(r.id, want);
      const nextAll: SessionRow[] = this.allRows.map((x: SessionRow): SessionRow => {
        if (x.id !== r.id) {
          return x;
        }
        return {
          id: x.id, title: x.title, updatedAt: x.updatedAt, cwd: x.cwd,
          running: x.running, asking: x.asking, archived: x.archived,
          pinned: want, agents: x.agents, model: x.model, context: x.context,
          plan: x.plan, backend: x.backend, preview: x.preview
        };
      });
      this.rowSig = '';
      this.applyFetchedRows(nextAll);
      Toast.ok(want ? '已置顶' : '已取消置顶');
    } catch (e) {
      Toast.err((want ? '置顶失败：' : '取消失败：') + (e as Error).message);
    }
  }

  private async doArchiveOrRestore(r: SessionRow, restore: boolean): Promise<void> {
    Haptics.soft();
    try {
      if (restore) {
        await this.api.unarchive(r.id);
      } else {
        await this.api.archive(r.id);
        Unread.markRead(r.id);
      }
      const nextAll: SessionRow[] = this.allRows.map((x: SessionRow): SessionRow => {
        if (x.id !== r.id) {
          return x;
        }
        return {
          id: x.id, title: x.title, updatedAt: x.updatedAt, cwd: x.cwd,
          running: x.running, asking: x.asking, archived: !restore,
          pinned: x.pinned, agents: x.agents, model: x.model, context: x.context,
          plan: x.plan, backend: x.backend, preview: x.preview
        };
      });
      this.api.cacheSessions(nextAll);
      this.rowSig = '';
      this.applyFetchedRows(nextAll);
      Toast.ok((restore ? '已恢复「' : '已归档「') + (r.title === '' ? '(untitled)' : r.title) + '」');
    } catch (e) {
      Toast.err((restore ? '恢复失败：' : '归档失败：') + (e as Error).message);
    }
  }

  private async doFork(r: SessionRow): Promise<void> {
    Haptics.soft();
    try {
      const id: string = await this.api.fork(r.id);
      if (id === '') {
        Toast.err('分叉失败');
        return;
      }
      Toast.ok('已分叉「' + (r.title === '' ? '(untitled)' : r.title) + '」');
      void this.load(true);
    } catch (e) {
      Toast.err('分叉失败：' + (e as Error).message);
    }
  }

  private async doRename(nextTitle: string): Promise<void> {
    const title: string = nextTitle.trim();
    if (title === '') {
      Toast.err('标题不能为空');
      return;
    }
    try {
      await this.api.rename(this.renameId, title);
      this.renameOn = false;
      Toast.ok('已重命名');
      void this.load(true);
    } catch (e) {
      Toast.err('重命名失败：' + (e as Error).message);
    }
  }

  private enterSelect(initialId: string = ''): void {
    Haptics.tap();
    this.selectOn = true;
    this.selected = initialId !== '' ? [initialId] : [];
    this.rebuildModels();
  }

  private exitSelect(): void {
    Haptics.soft();
    this.selectOn = false;
    this.selected = [];
    this.rebuildModels();
  }

  private toggleOne(id: string): void {
    Haptics.tap();
    const at: number = this.selected.indexOf(id);
    if (at >= 0) {
      const next: string[] = this.selected.slice();
      next.splice(at, 1);
      this.selected = next;
    } else {
      this.selected = this.selected.concat([id]);
    }
    this.rebuildModels();
  }

  private selectAllVisible(): void {
    Haptics.tap();
    const ids: string[] = [];
    const total: number = this.dataSource.totalCount();
    for (let i = 0; i < total; i++) {
      const m: RowModel = this.dataSource.getData(i);
      if (m.kind === 'row') {
        ids.push(m.row.id);
      }
    }
    this.selected = (ids.length > 0 && this.selected.length === ids.length) ? [] : ids;
    this.rebuildModels();
  }

  private async batchArchiveOrRestore(): Promise<void> {
    if (this.selected.length === 0) {
      return;
    }
    const ids: string[] = this.selected.slice();
    const restore: boolean = this.archivedView;
    Haptics.tap();
    let ok: number = 0;
    for (let i = 0; i < ids.length; i++) {
      try {
        const done: boolean = restore ? await this.api.unarchive(ids[i]) : await this.api.archive(ids[i]);
        if (done) {
          if (!restore) {
            Unread.markRead(ids[i]);
          }
          ok++;
        }
      } catch (e) {
      }
    }
    this.exitSelect();
    Toast.ok((restore ? '已恢复 ' : '已归档 ') + String(ok) + ' 个会话');
    await this.load(true);
  }

  private onEmptyAction(): void {
    Haptics.tap();
    if (this.q.trim() !== '') {
      this.q = '';
      this.searching = false;
      this.rebuildModels();
    } else if (this.timedOut) {
      this.timedOut = false;
      this.loading = true;
      void this.load(true, true);
    } else if (this.archivedView) {
      this.setArchivedMode(false);
    } else if (this.rows.length > 0 && this.backendFilter !== 'all') {
      this.backendFilter = 'all';
      this.rebuildModels();
    } else if (this.rows.length > 0 && this.wsFilter !== '') {
      this.wsFilter = '';
      this.wsFilterLabel = '';
      this.rebuildModels();
      void this.loadPreviews();
    }
  }

  @Builder
  private swipeActions(r: SessionRow) {
    Row() {
      if (!this.archivedView) {
        Text(r.pinned === true ? '取消置顶' : '置顶')
          .fontSize(Tokens.fsBody).fontColor(Tokens.accentInk)
          .width(60).height(56).textAlign(TextAlign.Center)
          .borderRadius(Tokens.rMd).backgroundColor(Tokens.accentStrong)
          .margin({ right: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
          .onClick(() => { void this.doPin(r); })
      }
      Text(this.archivedView ? '恢复' : '归档')
        .fontSize(Tokens.fsBody).fontColor(Tokens.accentInk)
        .width(60).height(56).textAlign(TextAlign.Center)
        .borderRadius(Tokens.rMd)
        .backgroundColor(this.archivedView ? Tokens.accentStrong : Tokens.err)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => { void this.doArchiveOrRestore(r, this.archivedView); })
    }
    .height(60).alignItems(VerticalAlign.Center).padding({ left: 8 })
  }

  @Builder
  private renameSheetBody() {
    SessionRenameSheet({
      initialTitle: this.renameText,
      onCancel: () => { this.renameOn = false; },
      onConfirm: (nextTitle: string) => { void this.doRename(nextTitle); }
    })
  }

  @Builder
  private wsSheetBody() {
    WorkspaceSheet({
      api: this.api,
      initialTab: this.wsSheetTab,
      wsChoices: collectRecentWsChoices(resolveBaseCwd(this.wsOpts, this.wsFilter, this.allRows), this.allRows),
      defaultDir: resolveBaseCwd(this.wsOpts, this.wsFilter, this.allRows),
      creating: this.creating,
      enabledBackends: this.enabledBackends(),
      onClose: () => { this.wsSheetOn = false; },
      onCreateInDir: (cwd: string, backend: string) => { void this.newSessionIn(cwd, backend); }
    })
  }

  @Builder
  private refreshArea() {
    Row({ space: 8 }) {
      if (this.refreshing || this.pullState === RefreshStatus.Drag || this.pullState === RefreshStatus.OverDrag) {
        LoadingProgress().width(20).height(20).color(Tokens.dim2)
        Text(this.refreshing ? '正在刷新' : '松开刷新').fontSize(Tokens.fsFoot).fontColor(Tokens.dim2)
      }
    }
    .width('100%').translate({ y: this.topInset + 70 }).justifyContent(FlexAlign.Center)
  }

  @Builder
  private headerBlock() {
    SessionHeaderBar({
      wsOpts: this.wsOpts,
      wsFilter: this.wsFilter,
      wsFilterLabel: this.wsFilterLabel,
      archivedView: this.archivedView,
      groupBy: this.groupBy,
      sortBy: this.sortBy,
      listState: this.listState,
      searching: this.searching,
      q: this.q,
      onSearchingChange: (v: boolean) => { this.searching = v; },
      onQueryChange: (v: string) => { this.q = v; this.rebuildModels(); },
      onSheetActiveChange: (active: boolean) => { this.headerSheetOn = active; },
      onPickWs: (o: WsOpt) => {
        this.wsFilter = o.id;
        this.wsFilterLabel = o.id === '' ? '' : o.name;
        this.rebuildModels();
        void this.loadPreviews();
      },
      onOpenNewWs: () => { this.wsSheetTab = 'browse'; this.wsSheetOn = true; },
      onExitArchived: () => { this.setArchivedMode(false); },
      onPickMachine: (id: string) => { this.onPickMachine(id); },
      onSelectGroupBy: (g: string) => {
        Haptics.tap(); this.groupBy = g;
        writeListViewPrefs(this.groupBy, this.listState, this.sortBy); this.applyListState();
      },
      onSelectSortBy: (sb: string) => {
        Haptics.tap(); this.sortBy = sb;
        writeListViewPrefs(this.groupBy, this.listState, this.sortBy); this.applyListState();
      },
      onSetArchived: (want: boolean) => { this.setArchivedMode(want); },
      onSelectListState: (st: string) => {
        Haptics.tap(); this.listState = st;
        writeListViewPrefs(this.groupBy, this.listState, this.sortBy); this.applyListState();
      },
      onEnterSelect: () => { this.enterSelect(); }
    })
  }

  private hdsTitle(): HdsNavigationTitleBarOptions {
    const stack: CustomBuilder = (): void => { this.headerBlock(); };
    return buildTransparentHdsTitle(stack);
  }

  build() {
    HdsNavigation() {
      Stack({ alignContent: Alignment.Top }) {
      Column() {
        if (this.loading) {
          Column() {
            SessionLoadingBox({
              loadSlow: this.loadSlow,
              onRetry: () => {
                this.loading = true;
                this.loadSlow = false;
                void this.load(true, true);
              }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: 760 })
        } else if (this.err !== '') {
          Column() {
            EmptyState({
              icon: $r('app.media.ic_set_pc'),
              title: '读取会话失败',
              hint: Api.kind(this.err) === 'net'
                ? (this.err + '\n电脑可能更换了地址，可前往「设置 -> 连接」修改地址或重新扫码配对')
                : this.err,
              action: '重试',
              onAction: () => {
                this.loading = true;
                void this.load(true, true);
              }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: 760 })
          .padding({
            top: this.topInset + 76,
            left: this.wideScreen ? 28 : 16,
            right: this.wideScreen ? 28 : 16
          })
        } else {
          Refresh({ refreshing: $$this.refreshing, builder: this.refreshArea() }) {
            List({ space: 8, scroller: this.scroller }) {
              ListItem() {
                Row().width('100%').height(this.topInset + 72)
              }

              if (!this.online) {
                ListItem() {
                  Row() {
                    Text('当前离线').fontSize(Tokens.fsFoot).fontWeight(FontWeight.Medium).fontColor(Tokens.err)
                    Text('消息会暂存在手机，网络恢复后可在聊天页重发')
                      .fontSize(Tokens.fsFoot).fontColor(Tokens.dim).margin({ left: 8 }).layoutWeight(1)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%').padding({ left: 14, right: 14, top: 9, bottom: 9 })
                  .backgroundColor(this.themeDark ? '#1FFF5C5C' : '#12FF3B30')
                  .borderRadius(Tokens.rMd).alignItems(VerticalAlign.Center)
                }
              }

              if (this.archivedView) {
                ListItem() {
                  Row() {
                    Text('正在查看已归档会话').fontSize(Tokens.fsFoot).fontColor(Tokens.accent).layoutWeight(1)
                    Text('返回正常列表')
                      .fontSize(Tokens.fsFoot).fontWeight(FontWeight.Medium).fontColor(Tokens.accent)
                      .onClick(() => { this.setArchivedMode(false); })
                  }
                  .width('100%').padding({ left: 14, right: 14, top: 9, bottom: 9 })
                  .backgroundColor(Tokens.accentSoft).borderRadius(Tokens.rMd)
                }
              }

              // 多 Agent 引擎筛选胶囊条（仅当启用了 >= 2 个后端时出现，单 DSH 零变化）
              if (this.enabledBackends().length >= 2 && !this.archivedView) {
                ListItem() {
                  Scroll() {
                    Row({ space: 6 }) {
                      Text('全部')
                        .fontSize(Tokens.fsFoot)
                        .fontWeight(this.backendFilter === 'all' ? FontWeight.Medium : FontWeight.Normal)
                        .fontColor(this.backendFilter === 'all' ? Tokens.accentInk : Tokens.dim)
                        .backgroundColor(this.backendFilter === 'all' ? Tokens.accent : Mat.cardBg(this.hdsOn))
                        .border({
                          width: 1,
                          color: this.backendFilter === 'all' ? Tokens.accent : Mat.cardBorderColor(this.hdsOn)
                        })
                        .borderRadius(Tokens.rPill)
                        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                        .onClick(() => {
                          Haptics.tap();
                          this.backendFilter = 'all';
                          this.rebuildModels();
                        })
                      ForEach(this.enabledBackends(), (b: BackendInfo) => {
                        Text(b.label)
                          .fontSize(Tokens.fsFoot)
                          .fontWeight(this.backendFilter === b.id ? FontWeight.Medium : FontWeight.Normal)
                          .fontColor(this.backendFilter === b.id ? Tokens.accentInk : Tokens.dim)
                          .backgroundColor(this.backendFilter === b.id ? Tokens.accent : Mat.cardBg(this.hdsOn))
                          .border({
                            width: 1,
                            color: this.backendFilter === b.id ? Tokens.accent : Mat.cardBorderColor(this.hdsOn)
                          })
                          .borderRadius(Tokens.rPill)
                          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                          .onClick(() => {
                            Haptics.tap();
                            this.backendFilter = b.id;
                            this.rebuildModels();
                          })
                      }, (b: BackendInfo) => b.id)
                    }
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                  .width('100%')
                }
              }

              // 未读新回复定位与闭环清理胶囊横条（F12）
              if (this.unreadCount > 0 && !this.selectOn && this.unreadVer >= 0) {
                ListItem() {
                  Row({ space: 8 }) {
                    Row()
                      .width(8)
                      .height(8)
                      .borderRadius(Tokens.rPill)
                      .backgroundColor(Tokens.accent)
                    Row() {
                      Text(String(this.unreadCount))
                        .fontSize(Tokens.fsFoot)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Tokens.fg)
                        .contentTransition(Motion.numTransition(this.motionMode))
                      Text(' 条新回复未读')
                        .fontSize(Tokens.fsFoot)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(Tokens.fg)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(VerticalAlign.Center)
                    Text('定位查看')
                      .fontSize(Tokens.fsCaption)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Tokens.accentInk)
                      .backgroundColor(Tokens.accent)
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                      .onClick(() => {
                        this.openFirstUnread();
                      })
                    Text('全部已读')
                      .fontSize(Tokens.fsCaption)
                      .fontColor(Tokens.dim)
                      .backgroundColor(Mat.subCardBg(this.hdsOn))
                      .border(Mat.subCardBorder(this.hdsOn))
                      .borderRadius(Tokens.rPill)
                      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
                      .onClick(() => {
                        this.clearAllUnread();
                      })
                  }
                  .width('100%')
                  .padding({ left: 14, right: 10, top: 9, bottom: 9 })
                  .backgroundColor(Mat.cardBg(this.hdsOn))
                  .borderRadius(Tokens.rPill)
                  .border({ width: 1, color: this.hdsOn ? Tokens.accentGlass : Tokens.accent })
                  .shadow(Mat.cardShadow(this.hdsOn))
                  .alignItems(VerticalAlign.Center)
                }
                .transition(Motion.panelTransition(this.motionMode))
              }

              if (this.rowCount === 0) {
                ListItem() {
                  SessionListEmptyView({
                    hasQuery: this.q.trim() !== '',
                    archivedView: this.archivedView,
                    timedOut: this.timedOut,
                    hasWsFilterOnly: this.rows.length > 0 && this.wsFilter !== '',
                    hasBackendFilterOnly: this.rows.length > 0 && this.backendFilter !== 'all',
                    onAction: () => { this.onEmptyAction(); }
                  })
                }
                .width('100%')
              } else {
                LazyForEach(this.dataSource, (m: RowModel, idx: number) => {
                  if (m.kind === 'head') {
                    ListItem() {
                      Row() {
                        Text(m.label).fontSize(Tokens.fsFoot).fontColor(Tokens.dim2).letterSpacing(1.1)
                        Blank()
                        if (m.label !== '置顶') {
                          Path()
                            .commands('M0 0 L5 5 L10 0')
                            .stroke(Tokens.dim2).strokeWidth(1.6).strokeLineCap(LineCapStyle.Round)
                            .fill(Color.Transparent).width(11).height(6)
                            .rotate({ angle: this.isFolded(m.label) ? -90 : 0 })
                            .animation(Motion.fadeOpts(this.motionMode))
                        }
                      }
                      .width('100%').padding({ left: 6, right: 6, top: 10, bottom: 2 })
                      .onClick(() => {
                        if (m.label !== '置顶') {
                          this.toggleFold(m.label);
                        }
                      })
                    }
                    .onAreaChange((_old: Area, area: Area) => {
                      if (idx < 18) {
                        this.wave.record(m.key, area);
                      }
                    })
                    .animation(null)
                    .opacity(this.listEntered || idx >= 18 ? 1 : 0)
                    .animation(this.listEntered && idx < 18
                      ? Motion.bloomHeaderOpacityAnimByDist(this.wave.distanceOf(m.key, idx * 66), this.motionMode, 20)
                      : null)
                    .scale({
                      x: this.listEntered || idx >= 18 ? 1 : Motion.BLOOM_HEADER_SCALE_START,
                      y: this.listEntered || idx >= 18 ? 1 : Motion.BLOOM_HEADER_SCALE_START,
                      centerX: '0%',
                      centerY: '50%'
                    })
                    .animation(this.listEntered && idx < 18
                      ? Motion.bloomHeaderScaleAnimByDist(this.wave.distanceOf(m.key, idx * 66), this.motionMode, 20)
                      : null)
                  } else {
                    ListItem() {
                      SessionTile({
                        row: m.row,
                        preview: m.preview,
                        count: m.count,
                        archivedView: this.archivedView,
                        selectMode: this.selectOn,
                        checked: this.selected.indexOf(m.row.id) >= 0,
                        caps: this.capsForRow(m.row),
                        onToggle: () => { this.toggleOne(m.row.id); },
                        onLongSelect: () => { this.enterSelect(m.row.id); },
                        onTap: () => {
                          Haptics.tap();
                          Unread.markRead(m.row.id);
                          const p: ChatParam = { id: m.row.id, title: m.row.title };
                          this.stack.pushPathByName('chat', p);
                        },
                        onRename: () => {
                          this.renameId = m.row.id;
                          this.renameText = m.row.title;
                          this.renameOn = true;
                        },
                        onPin: () => { void this.doPin(m.row); },
                        onArchive: () => { void this.doArchiveOrRestore(m.row, this.archivedView); },
                        onCopyId: () => { void copyText(m.row.id, '已复制会话 ID'); },
                        onFork: () => { void this.doFork(m.row); }
                      })
                    }
                    .onAreaChange((_old: Area, area: Area) => {
                      if (idx < 18) {
                        this.wave.record(m.key, area);
                      }
                    })
                    .animation(null)
                    .opacity(this.listEntered || idx >= 18 ? 1 : 0)
                    .animation(this.listEntered && idx < 18
                      ? Motion.bloomOpacityAnimByDist(this.wave.distanceOf(m.key, idx * 82), this.motionMode, 20)
                      : null)
                    .scale({
                      x: this.listEntered || idx >= 18 ? 1 : Motion.BLOOM_SCALE_START,
                      y: this.listEntered || idx >= 18 ? 1 : Motion.BLOOM_SCALE_START,
                      centerX: '50%',
                      centerY: '50%'
                    })
                    .animation(this.listEntered && idx < 18
                      ? Motion.bloomScaleAnimByDist(this.wave.distanceOf(m.key, idx * 82), this.motionMode, 20)
                      : null)
                    .swipeAction(this.capsForRow(m.row).archivePin
                      ? {
                          end: {
                            builder: () => {
                              this.swipeActions(m.row);
                            }
                          },
                          edgeEffect: SwipeEdgeEffect.Spring
                        }
                      : {
                          edgeEffect: SwipeEdgeEffect.None
                        })
                  }
                }, (m: RowModel) => m.key)
              }
            }
            .width('100%')
            .height('100%')
            .padding({
              left: this.wideScreen ? 28 : 16,
              right: this.wideScreen ? 28 : 16
            })
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(8)
            .contentEndOffset(this.selectOn ? this.bottomInset + 96 : this.bottomInset + 164)
          }
          .width('100%')
          .layoutWeight(1)
          .constraintSize({ maxWidth: 760 })
          .onStateChange((st: RefreshStatus) => { this.pullState = st; })
          .onRefreshing(() => {
            this.refreshing = true;
            this.load(true, true).finally(() => {
              this.refreshing = false;
              this.pullState = RefreshStatus.Inactive;
            });
          })
        }
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)

      // 顶部同色渐隐：在 HDS 浮动顶栏正下方承接滚动列表（F02）
      Row() {
        TopFade({ fadeHeight: this.topInset + 68 })
      }
      .width('100%')
      .position({ x: 0, y: 0 })
      .hitTestBehavior(HitTestMode.None)
      .visibility(this.refreshing ? Visibility.Hidden : Visibility.Visible)

      if (!this.selectOn && !this.archivedView) {
        Column() {
          SessionNewFab({
            creating: this.creating,
            onTap: () => {
              this.wsSheetTab = 'pick';
              this.wsSheetOn = true;
            }
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.animation({ duration: Motion.fade, curve: Motion.std }))
      }

      if (this.selectOn) {
        Column() {
          Blank()
          SessionBatchBar({
            selectedCount: this.selected.length,
            archivedView: this.archivedView,
            onSelectAll: () => { this.selectAllVisible(); },
            onBatchAct: () => { void this.batchArchiveOrRestore(); },
            onCancel: () => { this.exitSelect(); }
          })
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.move(TransitionEdge.BOTTOM))
            .animation({ duration: Motion.move, curve: Motion.std })
        )
      }

      Row().width(0).height(0)
        .bindSheet($$this.wsSheetOn, this.wsSheetBody(),
          Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.wsSheetOn = false; }))

      Row().width(0).height(0)
        .bindSheet($$this.renameOn, this.renameSheetBody(),
          Mat.sheetOpts(this.hdsOn, SheetSize.FIT_CONTENT, () => { this.renameOn = false; }))
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.themeBg)
    }
    .titleBar(this.hdsTitle())
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .bindToScrollable([this.scroller])
    .backgroundColor(this.themeBg)
    .width('100%')
    .height('100%')
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, ratio: number) => {
      if (isVisible && ratio > 0.5 && !this.loading) {
        void this.load(false);
      }
    })
  }
}
