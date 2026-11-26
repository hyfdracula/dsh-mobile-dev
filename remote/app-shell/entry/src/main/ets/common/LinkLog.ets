import { appVersion, envLine } from './Feedback';

const MAX_ENTRIES: number = 500;
const MAX_DETAIL_LEN: number = 240;

function pad2(n: number): string {
  return n < 10 ? '0' + String(n) : String(n);
}

function pad3(n: number): string {
  if (n < 10) {
    return '00' + String(n);
  }
  if (n < 100) {
    return '0' + String(n);
  }
  return String(n);
}

function nowStamp(): string {
  const d: Date = new Date();
  return pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' +
    pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds()) + '.' +
    pad3(d.getMilliseconds());
}

/**
 * 运行诊断日志（R7）：
 * 维护容量 500 条的内存环形缓冲，有限度地记录时间戳、类别（PROBE / NET / API / SSE / PAIR /
 * APP / NAV / ENGINE / NOTIFY / ERR）与脱敏摘要，并附带运行状态快照，
 * 绝不记录长期令牌、短签名、密钥或对话正文。
 */
export class LinkLog {
  private static ring: string[] = [];

  /** 剥离 URL / 日志片段中的敏感查询参数与 Bearer 凭据。 */
  static sanitize(raw: string): string {
    if (raw === '') {
      return '';
    }
    let clean: string = raw
      .replace(/([?&](?:t|sig|token|payload|c|key|g|grant)=)[^&\s#]+/gi, '$1***')
      .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer ***');
    if (clean.length > MAX_DETAIL_LEN) {
      clean = clean.slice(0, MAX_DETAIL_LEN) + '...';
    }
    return clean;
  }

  /** 记录一条诊断事件。 */
  static record(cat: string, detail: string): void {
    const tag: string = cat !== '' ? cat.toUpperCase() : 'INFO';
    const line: string = nowStamp() + ' [' + tag + '] ' + LinkLog.sanitize(detail);
    LinkLog.ring.push(line);
    while (LinkLog.ring.length > MAX_ENTRIES) {
      LinkLog.ring.shift();
    }
  }

  /** 当前已缓冲的日志条数。 */
  static count(): number {
    return LinkLog.ring.length;
  }

  /** 取最近 limit 条日志（按时间正序，末尾为最新）。 */
  static recent(limit: number = 100): string[] {
    if (limit <= 0 || LinkLog.ring.length === 0) {
      return [];
    }
    if (limit >= LinkLog.ring.length) {
      return LinkLog.ring.slice();
    }
    return LinkLog.ring.slice(LinkLog.ring.length - limit);
  }

  /** 清空内存诊断缓冲。 */
  static clear(): void {
    LinkLog.ring = [];
  }

  private static runtimeSnapshotLine(): string {
    const online: boolean = AppStorage.get<boolean>('online') === true;
    const linkMode: string = AppStorage.get<string>('linkMode') ?? 'unknown';
    const encrypted: boolean = AppStorage.get<boolean>('linkEncrypted') === true;
    const fg: boolean = AppStorage.get<boolean>('appFg') !== false;
    const hdsOn: boolean = AppStorage.get<boolean>('hdsOn') !== false;
    const dark: boolean = AppStorage.get<boolean>('themeDark') !== false;
    const motionMode: string = AppStorage.get<string>('motionMode') ?? 'vivid';
    const unreadCount: number = AppStorage.get<number>('unreadCount') ?? 0;
    return (online ? '在线' : '离线') +
      ' | link=' + linkMode + (encrypted ? '(E2EE)' : '') +
      ' | state=' + (fg ? 'fg' : 'bg') +
      ' | skin=' + (hdsOn ? 'glass' : 'solid') + (dark ? '/dark' : '/light') +
      ' | motion=' + motionMode +
      ' | unread=' + String(unreadCount);
  }

  private static categorySummaryLine(): string {
    if (LinkLog.ring.length === 0) {
      return '无';
    }
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < LinkLog.ring.length; i++) {
      const line: string = LinkLog.ring[i];
      const lbr: number = line.indexOf('[');
      const rbr: number = lbr >= 0 ? line.indexOf(']', lbr + 1) : -1;
      const tag: string = (lbr >= 0 && rbr > lbr) ? line.slice(lbr + 1, rbr) : 'OTHER';
      counts.set(tag, (counts.get(tag) ?? 0) + 1);
    }
    const parts: string[] = [];
    counts.forEach((n: number, tag: string) => {
      parts.push(tag + ':' + String(n));
    });
    return parts.join(' ');
  }

  /** 拼装运行状态快照、分类计数 + 最近 500 条日志文本，供复制或导出 .txt。 */
  static exportContent(appVer: string = ''): string {
    const ver: string = appVer !== '' ? appVer : appVersion();
    const d: Date = new Date();
    const exportedAt: string = String(d.getFullYear()) + '-' + pad2(d.getMonth() + 1) + '-' +
      pad2(d.getDate()) + ' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
    const header: string[] = [
      '# Agent Mobile 运行诊断日志',
      '导出时间: ' + exportedAt,
      '应用版本: ' + (ver !== '' ? ver : 'unknown'),
      '运行环境: ' + envLine(),
      '状态快照: ' + LinkLog.runtimeSnapshotLine(),
      '记录条数: ' + String(LinkLog.ring.length) + ' (' + LinkLog.categorySummaryLine() + ')',
      '覆盖范围: 网络链路 / 应用前后台 / 页面导航 / 多引擎状态 / 通知触发 / 脱敏异常',
      '隐私说明: 已自动剥离令牌、签名、密钥与全部对话正文',
      '----------------------------------------'
    ];
    const body: string[] = LinkLog.recent(MAX_ENTRIES);
    if (body.length === 0) {
      header.push('(暂无运行诊断日志)');
      return header.join('\n');
    }
    return header.join('\n') + '\n' + body.join('\n');
  }
}
