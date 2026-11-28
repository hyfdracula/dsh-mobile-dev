/**
 * HTTP 工具函数：请求体解析（含 413 限额）、常量时间令牌校验、网卡枚举与入口分类。
 */
import type { IncomingMessage, ServerResponse } from 'node:http'
import { networkInterfaces } from 'node:os'
import { timingSafeEqual } from 'node:crypto'

/** 普通请求体上限 1 MiB；上传路由显式传入更大限额。 */
export const DEFAULT_BODY_BYTES = 1 << 20

/** 带 HTTP 状态码的请求错误，供顶层路由直接返回对应状态码。 */
export class HttpError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

/** 判断是否为 Clash/Mihomo 等 TUN 虚拟网卡（198.18.0.0/15）或 APIPA 链路本地地址（169.254.0.0/16）。 */
function isVirtualOrLinkLocalV4(address: string): boolean {
  const parts = address.split('.').map((p) => Number.parseInt(p, 10))
  if (parts.length !== 4 || parts.some((p) => !Number.isFinite(p))) return false
  const a = parts[0] as number
  const b = parts[1] as number
  if (a === 198 && (b === 18 || b === 19)) return true
  if (a === 169 && b === 254) return true
  return false
}

/** 枚举本机所有非回环 IPv4（过滤 TUN 虚拟网卡与链路本地地址）与全局可达 IPv6 地址。 */
export function lanAddresses(): string[] {
  const out: string[] = []
  const nets = networkInterfaces()
  for (const entries of Object.values(nets)) {
    if (entries === undefined) continue
    for (const entry of entries) {
      if (entry.internal) continue
      const v4 = entry.family === 'IPv4'
      const v6 = entry.family === 'IPv6'
      if (v4) {
        if (isVirtualOrLinkLocalV4(entry.address)) continue
        out.push(entry.address)
        continue
      }
      if (v6 && !entry.address.startsWith('fe80')) out.push(entry.address)
    }
  }
  return out
}

/** 为 IPv6 字面量补上方括号后拼接端口。 */
export function hostPort(address: string, port: number): string {
  return address.includes(':') ? `[${address}]:${String(port)}` : `${address}:${String(port)}`
}

/**
 * 判断请求是否经由本机或局域网 Host 头到达。
 * Cloudflare 等隧道从 127.0.0.1 转发，因此依据 Host 头而非 socket 对端区分内外网。
 */
export function isLocalHostHeader(host: string | undefined): boolean {
  if (typeof host !== 'string' || host.length === 0) return true
  const bracketed = host.startsWith('[') ? host.slice(1, host.indexOf(']') >= 0 ? host.indexOf(']') : undefined) : ''
  const bare = bracketed !== '' ? bracketed : (host.split(':')[0] ?? '')
  if (bare === 'localhost' || bare === '127.0.0.1' || bare === '::1' || bare === '0.0.0.0') return true
  if (bare.includes(':')) return /^f[cd]/i.test(bare) || /^fe80/i.test(bare)
  const parts = bare.split('.').map((part) => Number.parseInt(part, 10))
  if (parts.length !== 4) return false
  if (parts.some((part) => !Number.isFinite(part))) return false
  const a = parts[0] as number
  const b = parts[1] as number
  if (a === 127) return true
  if (a === 10) return true
  if (a === 192 && b === 168) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  return false
}

/**
 * 对局域网候选地址或完整 http(s) URL 按手机可达性排序，越小越优先。
 * 同时识别裸 IP、host:port 以及 http:// / https:// 域名或地址。
 */
export function lanRank(input: string): number {
  const raw = input.trim()
  let host = raw
  let scheme = ''
  if (/^https?:\/\//i.test(raw)) {
    try {
      const parsed = new URL(raw)
      scheme = parsed.protocol.toLowerCase()
      host = parsed.hostname
    } catch {
      return 8
    }
  } else if (raw.startsWith('[')) {
    const close = raw.indexOf(']')
    host = close > 1 ? raw.slice(1, close) : raw
  } else {
    const colons = (raw.match(/:/g) ?? []).length
    if (colons === 1) host = raw.split(':')[0] ?? raw
  }
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.slice(1, -1)
  }
  if (host.includes(':')) return 9
  if (host.startsWith('192.168.')) return host.startsWith('192.168.56.') ? 6 : 0
  if (host.startsWith('10.')) return host.startsWith('10.0.2.') ? 7 : 1
  if (host.startsWith('172.')) {
    const second = Number.parseInt(host.split('.')[1] ?? '', 10)
    return second >= 16 && second <= 31 ? 5 : 2
  }
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host)) return 3
  return scheme === 'https:' ? 2 : 3
}

/**
 * 校验公网访问地址：允许空字符串（表示清空）；非空时必须为合法的 http:// 或 https:// URL。
 */
export function validatePublicUrl(raw: string): { ok: true; url: string } | { ok: false; error: string } {
  const trimmed = raw.trim()
  if (trimmed === '') return { ok: true, url: '' }
  if (/\s/.test(trimmed)) {
    return { ok: false, error: '公网地址不能包含空格' }
  }
  if (!/^https?:\/\//i.test(trimmed)) {
    return { ok: false, error: '公网地址必须以 http:// 或 https:// 开头' }
  }
  try {
    const parsed = new URL(trimmed)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return { ok: false, error: '公网地址协议仅支持 http:// 或 https://' }
    }
    if (!parsed.hostname || parsed.hostname.length === 0) {
      return { ok: false, error: '公网地址缺少有效的主机名或域名' }
    }
    const cleanPath = parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/+$/, '')
    return { ok: true, url: `${parsed.origin}${cleanPath}` }
  } catch {
    return { ok: false, error: '公网地址格式不合法，请填写完整的 http:// 或 https:// 地址' }
  }
}

/**
 * 校验并归一化允许预览的本机开发端口列表（支持数组或逗号分隔字符串，范围 1..65535）。
 */
export function parsePreviewPorts(raw: unknown): { ok: true; ports: number[] } | { ok: false; error: string } {
  const tokens: unknown[] = Array.isArray(raw)
    ? raw
    : typeof raw === 'string'
      ? raw.split(/[,，\s]+/).filter((s) => s.length > 0)
      : []
  if (!Array.isArray(raw) && typeof raw !== 'string') {
    return { ok: false, error: 'previewPorts 必须是端口数组或逗号分隔的端口字符串' }
  }
  const seen = new Set<number>()
  const ports: number[] = []
  for (const item of tokens) {
    const str = String(item).trim()
    if (str === '') continue
    if (!/^\d+$/.test(str)) {
      return { ok: false, error: `端口号「${str}」不合法，请填写 1 到 65535 之间的整数` }
    }
    const n = Number.parseInt(str, 10)
    if (!Number.isInteger(n) || n < 1 || n > 65535) {
      return { ok: false, error: `端口号 ${String(n)} 超出范围（允许 1..65535）` }
    }
    if (!seen.has(n)) {
      seen.add(n)
      ports.push(n)
    }
    if (ports.length > 64) {
      return { ok: false, error: '最多允许配置 64 个预览端口' }
    }
  }
  return { ok: true, ports }
}

/** 常量时间字符串比较，防时序侧信道。 */
export function tokenMatches(given: string, expected: string): boolean {
  if (given.length === 0 || expected.length === 0) return false
  const a = Buffer.from(given, 'utf8')
  const b = Buffer.from(expected, 'utf8')
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** 从 Authorization: Bearer 头或查询参数 ?t= 提取访问令牌。 */
export function presentedToken(req: IncomingMessage, url: URL): string {
  const header = req.headers.authorization
  if (typeof header === 'string' && header.toLowerCase().startsWith('bearer ')) {
    return header.slice(7).trim()
  }
  const query = url.searchParams.get('t')
  return query === null ? '' : query.trim()
}

/** 读取并解析有界 JSON 对象请求体；超限抛出 status=413 的 HttpError。 */
export async function readJson(req: IncomingMessage, limit: number = DEFAULT_BODY_BYTES): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string)
    size += buf.length
    if (size > limit) {
      req.resume()
      throw new HttpError(413, `body too large (limit ${String(limit)} bytes)`)
    }
    chunks.push(buf)
  }
  if (size === 0) return {}
  const text = Buffer.concat(chunks).toString('utf8')
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    throw new HttpError(400, 'body must be valid JSON')
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new HttpError(400, 'body must be a JSON object')
  }
  return parsed as Record<string, unknown>
}

/** 发送 JSON 或纯文本响应（若响应头已发送则安全忽略）。 */
export const send = (res: ServerResponse, status: number, body: unknown): void => {
  if (res.headersSent) return
  const text = typeof body === 'string' ? body : JSON.stringify(body)
  const headers: Record<string, string> = {
    'content-type': typeof body === 'string' ? 'text/plain; charset=utf-8' : 'application/json; charset=utf-8',
    'content-length': String(Buffer.byteLength(text)),
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'authorization,content-type,idempotency-key',
    'access-control-allow-methods': 'GET,HEAD,POST,PATCH,OPTIONS',
    'cache-control': 'no-store',
  }
  if (status === 413) {
    headers.connection = 'close'
  }
  res.writeHead(status, headers)
  res.end(text)
}
