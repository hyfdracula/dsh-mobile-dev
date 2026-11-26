/**
 * 设计令牌：雾面白 + DeepSeek 蓝 + 沉浸光感。
 * 所有页面只从这里取色，避免散落的硬编码。
 *
 * 深浅两套调色板是两份完整对象：applyDark() 只做一次整体赋值，
 * 新增字段时 Palette 接口会强制两边补齐，不会再出现「深色设了、浅色忘了」。
 */
interface Palette {
  // 底色
  bg: string;
  bgEl: string;
  surface: string;
  surface2: string;
  surface3: string;
  line: string;
  lineSoft: string;

  // 文字
  fg: string;
  dim: string;
  dim2: string;

  // 信号色
  accent: string;
  accentStrong: string;
  accentInk: string;
  accentGlow: string;
  accentSoft: string;
  ok: string;
  err: string;

  // 玻璃层与浮层
  glassStrong: string;
  glassLine: string;
  pillEdge: string;
  glassTop: string;
  glassBar: string;
  glassFloat: string;
  sheetWarm: string;
  accentGlass: string;
  chip: string;
  shadow: string;
  glassBtnBg: string;
  glassBtnLine: string;
  glassBtnShadow: string;
  popBg: string;
  popLine: string;
  popShadow: string;
  scrim: string;

  // 设置一级图标（统一单色）
  navIconBg: string;
  navIconInk: string;

  // 会话状态：运行中 / 已完成 / 已中断 / 等待回答
  runInk: string;
  runBg: string;
  doneInk: string;
  doneBg: string;
  intrInk: string;
  intrBg: string;
  askInk: string;
  askBg: string;

  // 存储分类
  bucket0: string;
  bucket1: string;
  bucket2: string;
  bucket3: string;
}

const DARK: Palette = {
  bg: '#0A0C10',
  bgEl: '#12151C',
  surface: '#161A22',
  surface2: '#1C212B',
  surface3: '#232936',
  line: '#252B37',
  lineSoft: '#1A1F28',

  fg: '#F2F4F7',
  dim: '#9AA3B2',
  dim2: '#8A93A6',

  accent: '#5B8CFF',
  accentStrong: '#3B6EF6',
  accentInk: '#FFFFFF',
  accentGlow: '#335B8CFF',
  accentSoft: '#1A3B6EF6',
  ok: '#3DDC97',
  err: '#FF5C5C',

  glassStrong: '#E6171B24',
  glassLine: '#33FFFFFF',
  pillEdge: '#4DFFFFFF',
  glassTop: '#5CFFFFFF',
  glassBar: '#E6171B24',
  glassFloat: '#331B2030',
  sheetWarm: '#9E171B22',
  accentGlass: '#1A3B6EF6',
  chip: '#1F2A3A',
  shadow: '#4D000000',
  glassBtnBg: '#3DFFFFFF',
  glassBtnLine: '#40FFFFFF',
  glassBtnShadow: '#40000000',
  popBg: '#F21B1F27',
  popLine: '#33FFFFFF',
  popShadow: '#40000000',
  scrim: '#33000000',

  navIconBg: '#1F2634',
  navIconInk: '#9DB4FF',

  runInk: '#7FA8FF',
  runBg: '#295B8CFF',
  doneInk: '#3DDC97',
  doneBg: '#243DDC97',
  intrInk: '#F2B36C',
  intrBg: '#24F2A23C',
  askInk: '#F5C43D',
  askBg: '#26F5C43D',

  bucket0: '#5B8CFF',
  bucket1: '#F2A23C',
  bucket2: '#3DDC97',
  bucket3: '#B48CFF',
};

const LIGHT: Palette = {
  bg: '#E9EDF4',
  bgEl: '#F7F9FC',
  surface: '#FFFFFF',
  surface2: '#F3F6FB',
  surface3: '#E7EDF7',
  line: '#E2E8F2',
  lineSoft: '#EDF1F8',

  fg: '#10131A',
  dim: '#5B6474',
  dim2: '#6B7486',

  accent: '#2F6BFF',
  accentStrong: '#1E56E0',
  accentInk: '#FFFFFF',
  accentGlow: '#332F6BFF',
  accentSoft: '#122F6BFF',
  ok: '#0F9D63',
  err: '#DC3545',

  glassStrong: '#D9FFFFFF',
  glassLine: '#1A10131A',
  pillEdge: '#1F000000',
  glassTop: '#FFFFFFFF',
  glassBar: '#E6FFFFFF',
  glassFloat: '#EBFFFFFF',
  sheetWarm: '#B8FFF6E4',
  accentGlass: '#262F6BFF',
  chip: '#EAF0FB',
  shadow: '#1F2F4A80',
  glassBtnBg: '#8CFFFFFF',
  glassBtnLine: '#D9FFFFFF',
  glassBtnShadow: '#26000000',
  popBg: '#F7FFFFFF',
  popLine: '#D9FFFFFF',
  popShadow: '#26000000',
  scrim: '#33000000',

  navIconBg: '#EAF0FB',
  navIconInk: '#2F6BFF',

  runInk: '#2F6BFF',
  runBg: '#142F6BFF',
  doneInk: '#0F9D63',
  doneBg: '#1410A56A',
  intrInk: '#B5730E',
  intrBg: '#18C97A12',
  askInk: '#B88200',
  askBg: '#1EF5B800',

  bucket0: '#2F6BFF',
  bucket1: '#C9821A',
  bucket2: '#0F9D63',
  bucket3: '#7A4FE0',
};

export class Tokens {
  static bg: string = DARK.bg;
  static bgEl: string = DARK.bgEl;
  static surface: string = DARK.surface;
  static surface2: string = DARK.surface2;
  static surface3: string = DARK.surface3;
  static line: string = DARK.line;
  static lineSoft: string = DARK.lineSoft;

  static fg: string = DARK.fg;
  static dim: string = DARK.dim;
  static dim2: string = DARK.dim2;

  static accent: string = DARK.accent;
  static accentStrong: string = DARK.accentStrong;
  static accentInk: string = DARK.accentInk;
  static accentGlow: string = DARK.accentGlow;
  static accentSoft: string = DARK.accentSoft;
  static ok: string = DARK.ok;
  static err: string = DARK.err;

  static glassStrong: string = DARK.glassStrong;
  static glassLine: string = DARK.glassLine;
  static pillEdge: string = DARK.pillEdge;
  static glassTop: string = DARK.glassTop;
  static glassBar: string = DARK.glassBar;
  static glassFloat: string = DARK.glassFloat;
  static sheetWarm: string = DARK.sheetWarm;
  static accentGlass: string = DARK.accentGlass;
  static chip: string = DARK.chip;
  static shadow: string = DARK.shadow;
  static glassBtnBg: string = DARK.glassBtnBg;
  static glassBtnLine: string = DARK.glassBtnLine;
  static glassBtnShadow: string = DARK.glassBtnShadow;
  static popBg: string = DARK.popBg;
  static popLine: string = DARK.popLine;
  static popShadow: string = DARK.popShadow;
  static scrim: string = DARK.scrim;

  static navIconBg: string = DARK.navIconBg;
  static navIconInk: string = DARK.navIconInk;

  static runInk: string = DARK.runInk;
  static runBg: string = DARK.runBg;
  static doneInk: string = DARK.doneInk;
  static doneBg: string = DARK.doneBg;
  static intrInk: string = DARK.intrInk;
  static intrBg: string = DARK.intrBg;
  static askInk: string = DARK.askInk;
  static askBg: string = DARK.askBg;

  static bucket0: string = DARK.bucket0;
  static bucket1: string = DARK.bucket1;
  static bucket2: string = DARK.bucket2;
  static bucket3: string = DARK.bucket3;

  /** 当前是否深色。applyDark() 每次切换时更新，供运行时需要分支的绘制用。 */
  static isDark: boolean = true;

  // 圆角：五档语义圆角 + 组件别名
  static readonly rXs: number = 6;
  static readonly rSm: number = 10;
  static readonly rMd: number = 14;
  static readonly rRow: number = 16;
  static readonly rLg: number = 20;
  static readonly rXl: number = 24;
  static readonly rGroup: number = 20;
  static readonly rCard: number = 20;
  static readonly rInput: number = 14;
  static readonly rPill: number = 999;

  // 间距：8pt 栅格
  static readonly sp1: number = 4;
  static readonly sp2: number = 8;
  static readonly sp3: number = 12;
  static readonly sp4: number = 16;
  static readonly sp5: number = 24;
  static readonly sp6: number = 32;
  static readonly pad: number = 16;
  static readonly gap: number = 12;

  // 字阶（动效时长统一使用 Motion）
  static readonly fsCaption: number = 11;
  static readonly fsFoot: number = 12;
  static readonly fsBody: number = 13;
  static readonly fsBodyLg: number = 15;
  static readonly fsTitle: number = 20;
  static readonly fsDisplay: number = 24;

  /** 切换调色板：true 深色，false 浅色。两份对象字段齐全，一次整体赋值。 */
  static applyDark(dark: boolean): void {
    Tokens.isDark = dark;
    const p: Palette = dark ? DARK : LIGHT;
    Tokens.bg = p.bg;
    Tokens.bgEl = p.bgEl;
    Tokens.surface = p.surface;
    Tokens.surface2 = p.surface2;
    Tokens.surface3 = p.surface3;
    Tokens.line = p.line;
    Tokens.lineSoft = p.lineSoft;
    Tokens.fg = p.fg;
    Tokens.dim = p.dim;
    Tokens.dim2 = p.dim2;
    Tokens.accent = p.accent;
    Tokens.accentStrong = p.accentStrong;
    Tokens.accentInk = p.accentInk;
    Tokens.accentGlow = p.accentGlow;
    Tokens.accentSoft = p.accentSoft;
    Tokens.ok = p.ok;
    Tokens.err = p.err;
    Tokens.glassStrong = p.glassStrong;
    Tokens.glassLine = p.glassLine;
    Tokens.pillEdge = p.pillEdge;
    Tokens.glassTop = p.glassTop;
    Tokens.glassBar = p.glassBar;
    Tokens.glassFloat = p.glassFloat;
    Tokens.sheetWarm = p.sheetWarm;
    Tokens.accentGlass = p.accentGlass;
    Tokens.chip = p.chip;
    Tokens.shadow = p.shadow;
    Tokens.glassBtnBg = p.glassBtnBg;
    Tokens.glassBtnLine = p.glassBtnLine;
    Tokens.glassBtnShadow = p.glassBtnShadow;
    Tokens.popBg = p.popBg;
    Tokens.popLine = p.popLine;
    Tokens.popShadow = p.popShadow;
    Tokens.scrim = p.scrim;
    Tokens.navIconBg = p.navIconBg;
    Tokens.navIconInk = p.navIconInk;
    Tokens.runInk = p.runInk;
    Tokens.runBg = p.runBg;
    Tokens.doneInk = p.doneInk;
    Tokens.doneBg = p.doneBg;
    Tokens.intrInk = p.intrInk;
    Tokens.intrBg = p.intrBg;
    Tokens.askInk = p.askInk;
    Tokens.askBg = p.askBg;
    Tokens.bucket0 = p.bucket0;
    Tokens.bucket1 = p.bucket1;
    Tokens.bucket2 = p.bucket2;
    Tokens.bucket3 = p.bucket3;
  }
}
