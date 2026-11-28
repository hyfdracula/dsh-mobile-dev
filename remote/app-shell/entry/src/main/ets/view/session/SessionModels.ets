import preferences from '@ohos.data.preferences';
import { AppCtx } from '../../common/AppCtx';
import { SessionRow } from '../../common/Api';
import { dayKey } from '../../common/Format';
import { Marks } from '../../common/Marks';

export interface RowModel {
  kind: string;
  label: string;
  key: string;
  row: SessionRow;
  preview: string;
  count: number;
}

export interface WsOpt {
  id: string;
  name: string;
  rawCwd: string;
  count: number;
}

export interface WsBuildResult {
  opts: WsOpt[];
  filterLabel: string;
}

export interface ListViewPrefs {
  groupBy: string;
  listState: string;
  sortBy: string;
}

/**
 * 将服务端返回的 Markdown 摘要压成单行纯文本。
 */
export function plainPreview(text: string): string {
  if (text === '') {
    return '';
  }
  return text
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/#{1,6}\s*/g, '')
    .replace(/\*\*([^*]*)\*\*/g, '$1')
    .replace(/^>\s?/g, '')
    .replace(/\|/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * 清理多余重复分隔符但保留宿主原始路径风格（Windows 反斜杠或 Unix 正斜杠），
 * 确保用于创建会话时传给宿主的 cwd 真实准确（I4）。
 */
export function tidyCwd(raw: string): string {
  const trimmed: string = raw.trim();
  if (trimmed === '') {
    return '';
  }
  const hasBackslash: boolean = trimmed.indexOf('\\') >= 0;
  if (hasBackslash) {
    const isUnc: boolean = trimmed.startsWith('\\\\');
    const body: string = (isUnc ? trimmed.substring(2) : trimmed).replace(/[\\/]+/g, '\\');
    let joined: string = isUnc ? '\\\\' + body : body;
    while (joined.length > 3 && joined.endsWith('\\')) {
      joined = joined.substring(0, joined.length - 1);
    }
    if (joined.length === 2 && joined.charAt(1) === ':') {
      return joined + '\\';
    }
    return joined;
  }
  let unix: string = trimmed.replace(/\/+/g, '/');
  while (unix.length > 1 && unix.endsWith('/')) {
    unix = unix.substring(0, unix.length - 1);
  }
  return unix;
}

/**
 * 跨平台归一化工作区路径键，用于精确归并同一目录（同时兼容 / 与 \）。
 */
export function normCwdKey(cwd: string): string {
  const trimmed: string = cwd.trim();
  if (trimmed === '') {
    return '';
  }
  let norm: string = trimmed.replace(/\\/g, '/').replace(/\/+/g, '/');
  while (norm.length > 1 && norm.endsWith('/')) {
    norm = norm.substring(0, norm.length - 1);
  }
  if (/^[A-Za-z]:/.test(norm)) {
    norm = norm.charAt(0).toLowerCase() + norm.substring(1);
  }
  return norm;
}

/**
 * 跨平台提取工作区末尾目录名（兼容 / 与 Windows \）。
 */
export function wsLeafName(cwd: string): string {
  const norm: string = cwd.replace(/\\/g, '/');
  const parts: string[] = norm.split('/').filter((s: string) => s.length > 0);
  if (parts.length === 0) {
    return norm.startsWith('/') ? '/' : '未分组';
  }
  const last: string = parts[parts.length - 1];
  return last !== '' ? last : '默认';
}

/**
 * 跨平台提取工作区末尾两级短路径，用于区分同名目录或弹窗列表展示。
 */
export function wsShortLabel(cwd: string): string {
  const norm: string = cwd.replace(/\\/g, '/');
  const parts: string[] = norm.split('/').filter((s: string) => s.length > 0);
  if (parts.length === 0) {
    return cwd !== '' ? cwd : '默认目录';
  }
  if (parts.length === 1) {
    return parts[0];
  }
  const sep: string = cwd.indexOf('\\') >= 0 ? '\\' : '/';
  return parts[parts.length - 2] + sep + parts[parts.length - 1];
}

/**
 * 跨平台拼接父目录与新子目录名（保留父目录原有的 / 或 \ 分隔符）。
 */
export function joinHostPath(parentDir: string, subName: string): string {
  const cleanSub: string = subName.trim().replace(/[\\/:*?"<>|]/g, '');
  const cleanDir: string = tidyCwd(parentDir);
  if (cleanSub === '') {
    return cleanDir;
  }
  if (cleanDir === '') {
    return cleanSub;
  }
  const sep: string = cleanDir.indexOf('\\') >= 0 ? '\\' : '/';
  if (cleanDir.endsWith('\\') || cleanDir.endsWith('/')) {
    return cleanDir + cleanSub;
  }
  return cleanDir + sep + cleanSub;
}

export function sigOfSessionRows(list: SessionRow[]): string {
  const parts: string[] = [];
  for (let i = 0; i < list.length; i++) {
    const r: SessionRow = list[i];
    parts.push(r.id + ':' + String(r.updatedAt) + ':' + (r.running ? '1' : '0') + ':' +
      (r.asking === true ? '1' : '0') + ':' + r.title + ':' + (r.pinned === true ? '1' : '0') + ':' +
      (r.archived === true ? '1' : '0'));
  }
  return parts.join(',');
}

export function buildWsOptions(rows: SessionRow[], wsFilter: string): WsBuildResult {
  const countMap: Map<string, number> = new Map<string, number>();
  const rawMap: Map<string, string> = new Map<string, string>();
  const leafCount: Map<string, number> = new Map<string, number>();

  for (let i = 0; i < rows.length; i++) {
    const cwd: string = tidyCwd(rows[i].cwd);
    const k: string = normCwdKey(cwd);
    if (k === '') {
      continue;
    }
    countMap.set(k, (countMap.get(k) ?? 0) + 1);
    if (!rawMap.has(k)) {
      rawMap.set(k, cwd);
      const leaf: string = wsLeafName(cwd);
      leafCount.set(leaf, (leafCount.get(leaf) ?? 0) + 1);
    }
  }

  const opts: WsOpt[] = [{ id: '', name: '全部工作区', rawCwd: '', count: rows.length }];
  countMap.forEach((cnt: number, k: string) => {
    const raw: string = rawMap.get(k) ?? '';
    const leaf: string = wsLeafName(raw);
    const dup: boolean = (leafCount.get(leaf) ?? 0) > 1;
    opts.push({
      id: k,
      name: dup ? wsShortLabel(raw) : leaf,
      rawCwd: raw,
      count: cnt
    });
  });

  let label: string = '';
  if (wsFilter !== '') {
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].id === wsFilter) {
        label = opts[i].name;
        break;
      }
    }
    if (label === '') {
      label = wsLeafName(wsFilter);
    }
  }
  return { opts: opts, filterLabel: label };
}

function buildWsLabelMap(rows: SessionRow[]): Map<string, string> {
  const rawMap: Map<string, string> = new Map<string, string>();
  const leafCount: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < rows.length; i++) {
    const cwd: string = tidyCwd(rows[i].cwd);
    const k: string = normCwdKey(cwd);
    if (!rawMap.has(k)) {
      rawMap.set(k, cwd);
      const leaf: string = wsLeafName(cwd);
      leafCount.set(leaf, (leafCount.get(leaf) ?? 0) + 1);
    }
  }
  const labels: Map<string, string> = new Map<string, string>();
  rawMap.forEach((raw: string, k: string) => {
    const leaf: string = wsLeafName(raw);
    const dup: boolean = (leafCount.get(leaf) ?? 0) > 1;
    labels.set(k, dup ? wsShortLabel(raw) : leaf);
  });
  return labels;
}

export function collectGroupLabels(rows: SessionRow[], groupBy: string, archivedView: boolean): string[] {
  const out: string[] = [];
  const wsLabels: Map<string, string> = groupBy === 'ws' ? buildWsLabelMap(rows) : new Map<string, string>();
  for (let i = 0; i < rows.length; i++) {
    const r: SessionRow = rows[i];
    if (r.pinned === true && !archivedView) {
      continue;
    }
    let g: string = dayKey(r.updatedAt);
    if (groupBy === 'ws') {
      const k: string = normCwdKey(tidyCwd(r.cwd));
      g = wsLabels.get(k) ?? wsLeafName(r.cwd);
    }
    if (out.indexOf(g) < 0) {
      out.push(g);
    }
  }
  return out;
}

export function resolveBaseCwd(wsOpts: WsOpt[], wsFilter: string, allRows: SessionRow[]): string {
  for (let i = 0; i < wsOpts.length; i++) {
    if (wsFilter !== '' && wsOpts[i].id === wsFilter && wsOpts[i].rawCwd !== '') {
      return wsOpts[i].rawCwd;
    }
  }
  for (let i = 0; i < allRows.length; i++) {
    const r: SessionRow = allRows[i];
    if (r.archived !== true && r.cwd !== '') {
      return tidyCwd(r.cwd);
    }
  }
  return '';
}

export function collectRecentWsChoices(baseDir: string, allRows: SessionRow[]): string[] {
  const out: string[] = [];
  const seen: string[] = [];
  const push = (raw: string): void => {
    const clean: string = tidyCwd(raw);
    const k: string = normCwdKey(clean);
    if (clean !== '' && seen.indexOf(k) < 0) {
      seen.push(k);
      out.push(clean);
    }
  };
  if (baseDir !== '') {
    push(baseDir);
  }
  for (let i = 0; i < allRows.length && out.length < 8; i++) {
    if (allRows[i].archived !== true) {
      push(allRows[i].cwd);
    }
  }
  return out;
}

function sortSessionRows(list: SessionRow[], sortBy: string): SessionRow[] {
  if (sortBy !== 'title') {
    return list;
  }
  const copy: SessionRow[] = list.slice();
  copy.sort((a: SessionRow, b: SessionRow) => {
    const x: string = (a.title === '' ? '(untitled)' : a.title).toLowerCase();
    const y: string = (b.title === '' ? '(untitled)' : b.title).toLowerCase();
    if (x < y) {
      return -1;
    }
    if (x > y) {
      return 1;
    }
    return b.updatedAt - a.updatedAt;
  });
  return copy;
}

function makeRowKey(
  r: SessionRow,
  pv: string,
  cnt: number,
  archivedView: boolean,
  selectOn: boolean,
  selected: string[]
): string {
  const selTag: string = selectOn ? (selected.indexOf(r.id) >= 0 ? '1' : '0') : 'n';
  return r.id + '|' + r.title + '|' + String(r.updatedAt) + '|' + (r.running ? '1' : '0') +
    '|' + (r.asking === true ? '1' : '0') + '|' + Marks.get(r.id) +
    '|' + (r.pinned === true ? '1' : '0') + '|' + (archivedView ? 'a' : 'l') +
    '|' + selTag + '|' + String(cnt) + '|' + pv;
}

export function buildSessionRowModels(
  rows: SessionRow[],
  query: string,
  wsFilter: string,
  sortBy: string,
  groupBy: string,
  archivedView: boolean,
  folded: string[],
  selectOn: boolean,
  selected: string[],
  previewTextMap: Map<string, string>,
  previewCountMap: Map<string, number>
): RowModel[] {
  const kw: string = query.trim().toLowerCase();
  const out: RowModel[] = [];
  const wsLabels: Map<string, string> = groupBy === 'ws' ? buildWsLabelMap(rows) : new Map<string, string>();
  let lastGroup: string = '';

  const matchesWs = (cwd: string): boolean => {
    return wsFilter === '' || normCwdKey(cwd) === wsFilter || wsLeafName(cwd) === wsFilter;
  };

  const pinned: SessionRow[] = archivedView
    ? []
    : sortSessionRows(rows.filter((r: SessionRow) => r.pinned === true), sortBy);
  const rest: SessionRow[] = sortSessionRows(archivedView
    ? rows
    : rows.filter((r: SessionRow) => r.pinned !== true), sortBy);

  const pinnedShown: SessionRow[] = pinned.filter((r: SessionRow) => {
    if (!matchesWs(r.cwd)) {
      return false;
    }
    if (kw !== '' && (r.title === '' ? '(untitled)' : r.title).toLowerCase().indexOf(kw) < 0) {
      return false;
    }
    return true;
  });

  if (pinnedShown.length > 0) {
    out.push({ kind: 'head', label: '置顶', key: 'h-pin', row: pinnedShown[0], preview: '', count: 0 });
    for (let i = 0; i < pinnedShown.length; i++) {
      const r: SessionRow = pinnedShown[i];
      const pv: string = previewTextMap.get(r.id) ?? '';
      const cnt: number = previewCountMap.get(r.id) ?? 0;
      out.push({
        kind: 'row',
        label: '',
        key: makeRowKey(r, pv, cnt, archivedView, selectOn, selected),
        row: r,
        preview: pv,
        count: cnt
      });
    }
  }

  for (let i = 0; i < rest.length; i++) {
    const r: SessionRow = rest[i];
    if (!matchesWs(r.cwd)) {
      continue;
    }
    if (kw !== '' && (r.title === '' ? '(untitled)' : r.title).toLowerCase().indexOf(kw) < 0) {
      continue;
    }
    const pv: string = previewTextMap.get(r.id) ?? '';
    const cnt: number = previewCountMap.get(r.id) ?? 0;

    if (archivedView) {
      out.push({
        kind: 'row',
        label: '',
        key: makeRowKey(r, pv, cnt, archivedView, selectOn, selected),
        row: r,
        preview: pv,
        count: cnt
      });
      continue;
    }

    let grp: string = dayKey(r.updatedAt);
    if (groupBy === 'ws') {
      const k: string = normCwdKey(tidyCwd(r.cwd));
      grp = wsLabels.get(k) ?? wsLeafName(r.cwd);
    }
    const isFold: boolean = folded.indexOf(grp) >= 0;
    if (grp !== lastGroup) {
      lastGroup = grp;
      out.push({
        kind: 'head',
        label: grp,
        key: 'h-' + groupBy + '-' + grp + (isFold ? '-c' : '-o'),
        row: r,
        preview: '',
        count: 0
      });
    }
    if (!isFold) {
      out.push({
        kind: 'row',
        label: '',
        key: makeRowKey(r, pv, cnt, archivedView, selectOn, selected),
        row: r,
        preview: pv,
        count: cnt
      });
    }
  }
  return out;
}

export function readListViewPrefs(): ListViewPrefs {
  try {
    const opts: preferences.Options = { name: 'dsh_mobile_listview' };
    const p: preferences.Preferences = preferences.getPreferencesSync(AppCtx.ability(), opts);
    const g: string = p.getSync('groupBy', 'time') as string;
    const st: string = p.getSync('listState', 'all') as string;
    const sb: string = p.getSync('sortBy', 'recent') as string;
    return {
      groupBy: g === 'ws' ? 'ws' : 'time',
      listState: st === 'first' || st === 'none' ? st : 'all',
      sortBy: sb === 'title' ? 'title' : 'recent'
    };
  } catch (e) {
    return { groupBy: 'time', listState: 'all', sortBy: 'recent' };
  }
}

export function writeListViewPrefs(groupBy: string, listState: string, sortBy: string): void {
  try {
    const opts: preferences.Options = { name: 'dsh_mobile_listview' };
    const p: preferences.Preferences = preferences.getPreferencesSync(AppCtx.ability(), opts);
    p.putSync('groupBy', groupBy);
    p.putSync('listState', listState);
    p.putSync('sortBy', sortBy);
    p.flushSync();
  } catch (e) {
  }
}

interface CachedPreviewEntry {
  id: string;
  p: string;
  c: number;
}

const PREVIEW_CACHE_STORE: string = 'dsh_mobile_previews';

/**
 * 同步读取本地最近一次会话摘要与消息数缓存，使冷启动首屏渲染即可按完整三行高度展示，避免公网等待摘要造成的高度跳变。
 */
export function readCachedPreviews(textMap: Map<string, string>, countMap: Map<string, number>): void {
  try {
    const opts: preferences.Options = { name: PREVIEW_CACHE_STORE };
    const store: preferences.Preferences = preferences.getPreferencesSync(AppCtx.ability(), opts);
    const raw: string = store.getSync('items', '') as string;
    if (raw === '') {
      return;
    }
    const parsed: CachedPreviewEntry[] = JSON.parse(raw) as CachedPreviewEntry[];
    if (!Array.isArray(parsed)) {
      return;
    }
    for (let i = 0; i < parsed.length; i++) {
      const item: CachedPreviewEntry = parsed[i];
      if (item === null || item === undefined || typeof item.id !== 'string' || item.id === '' ||
        typeof item.p !== 'string') {
        continue;
      }
      if (!textMap.has(item.id)) {
        textMap.set(item.id, item.p);
      }
      if (!countMap.has(item.id)) {
        const cnt: number = typeof item.c === 'number' && item.c >= 0 ? item.c : 0;
        countMap.set(item.id, cnt);
      }
    }
  } catch (e) {
  }
}

/**
 * 将首屏与近期活跃会话的摘要与消息数写入本地轻量缓存（最多保留 80 条）。
 */
export function writeCachedPreviews(
  textMap: Map<string, string>,
  countMap: Map<string, number>,
  orderIds: string[]
): void {
  try {
    const out: CachedPreviewEntry[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < orderIds.length && out.length < 80; i++) {
      const id: string = orderIds[i];
      if (id === '' || seen.has(id)) {
        continue;
      }
      if (textMap.has(id) || (countMap.get(id) ?? 0) > 0) {
        seen.add(id);
        out.push({
          id: id,
          p: textMap.get(id) ?? '',
          c: countMap.get(id) ?? 0
        });
      }
    }
    textMap.forEach((pv: string, id: string) => {
      if (out.length >= 80 || id === '' || seen.has(id)) {
        return;
      }
      const cnt: number = countMap.get(id) ?? 0;
      if (pv !== '' || cnt > 0) {
        seen.add(id);
        out.push({ id: id, p: pv, c: cnt });
      }
    });
    const opts: preferences.Options = { name: PREVIEW_CACHE_STORE };
    const store: preferences.Preferences = preferences.getPreferencesSync(AppCtx.ability(), opts);
    store.putSync('items', JSON.stringify(out));
    store.flushSync();
  } catch (e) {
  }
}

/**
 * 会话列表 LazyForEach 轻量数据源（M4）。
 */
export class SessionDataSource implements IDataSource {
  private items: RowModel[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): RowModel {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  replaceAll(next: RowModel[]): void {
    this.items = next;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
