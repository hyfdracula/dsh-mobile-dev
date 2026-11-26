/**
 * 插件持久化状态、路径解析、原子落盘、日志轮转与配对码防爆破管理。
 */
import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { appendFile, mkdir, rename, stat, unlink } from 'node:fs/promises'
import { homedir, hostname } from 'node:os'
import { dirname, join } from 'node:path'
import { decodeBase64Flexible, generateX25519Keypair, x25519PublicFromPrivate } from './crypto/noise.ts'
import { hostPort, isLocalHostHeader, lanAddresses, lanRank, tokenMatches } from './http-util.ts'

export const VERSION = '3.1.0'
export const DEFAULT_PORT = 8901
export const PAIR_TTL_MS = 15 * 60 * 1000
export const PAIR_FAIL_LIMIT = 8
export const PAIR_LOCK_MS = 5 * 60 * 1000
export const PHONE_ONLINE_MS = 10 * 60 * 1000
export const PRESENCE_TTL_MS = 15 * 1000
const PAIR_FAIL_MAP_CAP = 256
const PAIR_FAIL_EXPIRE_MS = 10 * 60 * 1000
const MAX_LOG_BYTES = 5 * 1024 * 1024

export type AnswerMode = 'phone' | 'desktop'

/** 配对开关与公网入口配置。 */
export interface PairPrefs {
  allowLan: boolean
  allowRemote: boolean
  publicUrl: string
}

/** 已配对且建立过端到端加密身份的设备记录。 */
export interface PairedDeviceRecord {
  deviceId: string
  pubKey: string
  name: string
  createdAt: number
  lastSeenAt: number
  revoked?: boolean
}

/** 手机端推送注册记录（仅保存经授权配对手机的 Push Token 与偏好）。 */
export interface PushRegistration {
  deviceId: string
  pushToken: string
  relayUrl: string
  enabled: boolean
  bgOnly: boolean
  showTitle: boolean
  updatedAt: number
}

/** 落盘在 `<dshHome>/dsh-mobile.json` 中的完整结构。 */
export interface MobileState {
  token: string
  hostId?: string
  e2eePriv?: string
  e2eePub?: string
  devices?: PairedDeviceRecord[]
  pushTargets?: PushRegistration[]
  pair?: Partial<PairPrefs>
  answerMode?: AnswerMode
  allowTerminal?: boolean
  previewPorts?: number[]
  enabledBackends?: Record<string, boolean>
}

/** 当前有效的 6 位一次性配对码，自带累计错误次数。 */
export interface PairCode {
  code: string
  expiresAt: number
  fails: number
}

/** 统一解析 DSH 主目录，尊重 `DSH_HOME` 环境变量覆盖。 */
export function dshHome(): string {
  const override = process.env.DSH_HOME
  return override !== undefined && override.length > 0 ? override : join(homedir(), '.dsh')
}

export const statePath = (): string => join(dshHome(), 'dsh-mobile.json')

/**
 * 原子写入文件：先写入带 pid 与随机后缀的同目录临时文件，再 rename 覆盖目标。
 */
export function atomicWriteSync(file: string, content: string, mode?: number): void {
  const temp = `${file}.${String(process.pid)}.${randomBytes(4).toString('hex')}.tmp`
  try {
    mkdirSync(dirname(file), { recursive: true })
    if (mode !== undefined) {
      writeFileSync(temp, content, { encoding: 'utf8', mode })
    } else {
      writeFileSync(temp, content, 'utf8')
    }
    renameSync(temp, file)
    if (mode !== undefined) {
      try {
        chmodSync(file, mode)
      } catch {
        // Windows 下 chmod 仅作最佳努力。
      }
    }
  } catch (error) {
    try {
      unlinkSync(temp)
    } catch {
      // 临时文件未创建或已被消费。
    }
    throw error
  }
}

interface StateCacheEntry {
  file: string
  mtimeMs: number
  size: number
  data: Partial<MobileState>
}

let stateCache: StateCacheEntry | null = null

/** 读取持久化状态（内存缓存 + mtime/size 校验，避免每次请求 readFileSync）。 */
export function readState(): Partial<MobileState> {
  const file = statePath()
  let mtimeMs = -1
  let size = -1
  try {
    const st = statSync(file)
    mtimeMs = st.mtimeMs
    size = st.size
  } catch {
    stateCache = { file, mtimeMs: -1, size: -1, data: {} }
    return {}
  }
  if (
    stateCache !== null
    && stateCache.file === file
    && stateCache.mtimeMs === mtimeMs
    && stateCache.size === size
  ) {
    return stateCache.data
  }
  try {
    const parsed: unknown = JSON.parse(readFileSync(file, 'utf8'))
    const data = parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Partial<MobileState>)
      : {}
    stateCache = { file, mtimeMs, size, data }
    return data
  } catch {
    return {}
  }
}

/** 合并补丁并原子写回 `dsh-mobile.json`（权限 0600），同步刷新内存缓存；永不覆盖丢失既有身份字段。 */
export function writeState(patch: Partial<MobileState>, onError?: (error: unknown) => void): boolean {
  const file = statePath()
  const existing = readState()
  const cleanPatch: Partial<MobileState> = {}
  for (const [k, v] of Object.entries(patch)) {
    if (v !== undefined) {
      ;(cleanPatch as Record<string, unknown>)[k] = v
    }
  }
  const next: Partial<MobileState> = { ...existing, ...cleanPatch }
  try {
    atomicWriteSync(file, `${JSON.stringify(next, null, 2)}\n`, 0o600)
    try {
      const st = statSync(file)
      stateCache = { file, mtimeMs: st.mtimeMs, size: st.size, data: next }
    } catch {
      stateCache = { file, mtimeMs: Date.now(), size: 0, data: next }
    }
    return true
  } catch (error) {
    onError?.(error)
    return false
  }
}

/** 当前配对偏好（默认开启局域网与公网开关，兼容已有升级用户）。 */
export function pairPrefs(): PairPrefs {
  const raw = readState().pair
  const envPublic = process.env.DSH_MOBILE_PUBLIC_URL
  return {
    allowLan: raw?.allowLan !== false,
    allowRemote: raw?.allowRemote !== false,
    publicUrl:
      typeof raw?.publicUrl === 'string'
        ? raw.publicUrl
        : typeof envPublic === 'string'
          ? envPublic
          : '',
  }
}

/** 当前提问回答模式（默认 `phone`）。 */
export function answerMode(): AnswerMode {
  return readState().answerMode === 'desktop' ? 'desktop' : 'phone'
}

/** 是否允许手机使用远程交互终端（默认 `true`）。 */
export function allowTerminal(): boolean {
  return readState().allowTerminal !== false
}

/** 允许手机预览的本机 127.0.0.1 端口白名单（默认 `[]`）。 */
export function previewPorts(): number[] {
  const raw = readState().previewPorts
  if (!Array.isArray(raw)) return []
  const out: number[] = []
  const seen = new Set<number>()
  for (const item of raw) {
    const n = Number(item)
    if (Number.isInteger(n) && n >= 1 && n <= 65535 && !seen.has(n)) {
      seen.add(n)
      out.push(n)
    }
  }
  return out
}

/** 读取已启用的外部 Agent 后端开关（默认全部关闭，保障本机权限边界）。 */
export function enabledBackends(): Record<string, boolean> {
  const raw = readState().enabledBackends
  if (!raw || typeof raw !== 'object') return {}
  const out: Record<string, boolean> = {}
  for (const [k, v] of Object.entries(raw)) {
    if (v === true) out[k] = true
  }
  return out
}

/** 持久化某个外部 Agent 后端的开关状态。 */
export function setBackendEnabled(id: string, enabled: boolean): void {
  const next = enabledBackends()
  next[id] = enabled
  writeState({ enabledBackends: next })
}

/** 读取或首次铸造 Bearer 令牌（绝不向日志打印明文）。 */
export function resolveToken(fromConfig: string | undefined): string {
  if (fromConfig !== undefined && fromConfig.length > 0) return fromConfig
  const env = process.env.DSH_MOBILE_TOKEN
  if (env !== undefined && env.length > 0) return env
  const existing = readState().token
  if (typeof existing === 'string' && existing.length >= 16) return existing
  const token = randomBytes(24).toString('base64url')
  writeState({ token })
  return token
}

/** 读取或首次生成持久 `hostId`（UUID v4，后续永久不变）。 */
export function resolveHostId(): string {
  const existing = readState().hostId
  if (typeof existing === 'string' && existing.trim().length > 0) {
    return existing.trim()
  }
  const hostId = randomUUID()
  writeState({ hostId })
  return hostId
}

/** 读取或首次生成 32 字节 X25519 静态密钥对（标准 Base64 落盘）。 */
export function resolveE2eeKeypair(): { priv: string; pub: string } {
  const state = readState()
  if (typeof state.e2eePriv === 'string' && state.e2eePriv.trim().length > 0) {
    try {
      const privBuf = decodeBase64Flexible(state.e2eePriv)
      if (privBuf.length === 32) {
        const priv = privBuf.toString('base64')
        const pub = x25519PublicFromPrivate(privBuf).toString('base64')
        if (state.e2eePriv !== priv || state.e2eePub !== pub) {
          writeState({ e2eePriv: priv, e2eePub: pub })
        }
        return { priv, pub }
      }
    } catch {
      // 密钥损坏则重新生成。
    }
  }
  const pair = generateX25519Keypair()
  const priv = pair.privateKey.toString('base64')
  const pub = pair.publicKey.toString('base64')
  writeState({ e2eePriv: priv, e2eePub: pub })
  return { priv, pub }
}

const MAX_PAIRED_DEVICES = 64

/** 读取已配对设备列表（按最近活跃时间倒序）。 */
export function pairedDevices(): PairedDeviceRecord[] {
  const raw = readState().devices
  if (!Array.isArray(raw)) return []
  const out: PairedDeviceRecord[] = []
  for (const item of raw) {
    if (item === null || typeof item !== 'object') continue
    const r = item as Partial<PairedDeviceRecord>
    const deviceId = typeof r.deviceId === 'string' ? r.deviceId.trim() : ''
    const pubKey = typeof r.pubKey === 'string' ? r.pubKey.trim() : ''
    if (deviceId === '' || pubKey === '') continue
    out.push({
      deviceId,
      pubKey,
      name: typeof r.name === 'string' && r.name.trim() !== '' ? r.name.trim() : '未命名设备',
      createdAt: typeof r.createdAt === 'number' && Number.isFinite(r.createdAt) ? r.createdAt : 0,
      lastSeenAt: typeof r.lastSeenAt === 'number' && Number.isFinite(r.lastSeenAt) ? r.lastSeenAt : 0,
      revoked: r.revoked === true,
    })
  }
  out.sort((a, b) => b.lastSeenAt - a.lastSeenAt)
  return out
}

/** 写入或更新已配对设备记录。 */
export function upsertPairedDevice(entry: PairedDeviceRecord): PairedDeviceRecord[] {
  const list = pairedDevices()
  const idx = list.findIndex((d) => d.deviceId === entry.deviceId)
  if (idx >= 0) {
    list[idx] = { ...list[idx], ...entry }
  } else {
    list.push({ ...entry })
  }
  list.sort((a, b) => b.lastSeenAt - a.lastSeenAt)
  const bounded = list.slice(0, MAX_PAIRED_DEVICES)
  writeState({ devices: bounded })
  return bounded
}

/** 撤销或恢复指定设备授权。 */
export function setDeviceRevoked(
  deviceId: string,
  revoked: boolean,
): { ok: true; devices: PairedDeviceRecord[] } | { ok: false } {
  const list = pairedDevices()
  const idx = list.findIndex((d) => d.deviceId === deviceId)
  if (idx < 0) return { ok: false }
  const current = list[idx] as PairedDeviceRecord
  list[idx] = { ...current, revoked }
  writeState({ devices: list })
  return { ok: true, devices: list }
}

const MAX_PUSH_TARGETS = 16

/** 读取已注册的手机推送目标列表（按更新时间倒序）。 */
export function pushTargets(): PushRegistration[] {
  const raw = readState().pushTargets
  if (!Array.isArray(raw)) return []
  const out: PushRegistration[] = []
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue
    const r = item as Partial<PushRegistration>
    const pushToken = typeof r.pushToken === 'string' ? r.pushToken.trim() : ''
    if (pushToken.length < 16) continue
    out.push({
      deviceId: typeof r.deviceId === 'string' && r.deviceId.trim() !== '' ? r.deviceId.trim() : pushToken.slice(0, 16),
      pushToken,
      relayUrl: typeof r.relayUrl === 'string' && r.relayUrl.trim() !== '' ? r.relayUrl.trim() : 'https://feedback.juo.de5.net',
      enabled: r.enabled !== false,
      bgOnly: r.bgOnly !== false,
      showTitle: r.showTitle !== false,
      updatedAt: Number(r.updatedAt) || 0,
    })
  }
  out.sort((a, b) => b.updatedAt - a.updatedAt)
  return out
}

/** 写入或更新手机 Push Token 与推送偏好（按 deviceId 或 pushToken 去重，上限 16 条）。 */
export function upsertPushTarget(reg: PushRegistration): PushRegistration[] {
  const list = pushTargets().filter((t) => t.deviceId !== reg.deviceId && t.pushToken !== reg.pushToken)
  list.unshift({ ...reg, updatedAt: Date.now() })
  const bounded = list.slice(0, MAX_PUSH_TARGETS)
  writeState({ pushTargets: bounded })
  return bounded
}

/** 按 deviceId 或 pushToken 移除失效的手机推送目标。 */
export function removePushTarget(deviceIdOrToken: string): PushRegistration[] {
  const clean = deviceIdOrToken.trim()
  if (clean === '') return pushTargets()
  const next = pushTargets().filter((t) => t.deviceId !== clean && t.pushToken !== clean)
  writeState({ pushTargets: next })
  return next
}

/** 生成 6 位密码学随机数字码。 */
export function freshPairCode(): string {
  return String(randomInt(0, 1_000_000)).padStart(6, '0')
}

/** 生成二维码承载的 `dshmobile://pair?...` 深链，公网隧道优先排在首个备选。 */
export function pairPayload(base: string, code: string, alts: readonly string[] = []): string {
  const list = alts.filter((one) => one.length > 0 && one !== base)
  const tunnel = list.find((one) => {
    if (/^https:\/\//i.test(one)) return true
    if (/^http:\/\//i.test(one)) {
      try {
        return !isLocalHostHeader(new URL(one).host)
      } catch {
        return false
      }
    }
    return false
  }) ?? ''
  const rest = list.filter((one) => one !== tunnel)
  const kept = rest.slice(0, tunnel !== '' ? 3 : 4)
  const ordered = tunnel !== '' ? [tunnel, ...kept] : kept
  const extra = ordered.map((one) => `&a=${encodeURIComponent(one)}`).join('')
  return `dshmobile://pair?b=${encodeURIComponent(base)}&c=${encodeURIComponent(code)}${extra}`
}

/** 计算本机局域网可拨号的基础 URL 列表（IPv4 按可达性排前，IPv6 兜底）。 */
export function lanBases(port: number): string[] {
  const all = lanAddresses()
  const v6 = all.filter((address) => address.includes(':') && !/^f[cd]/i.test(address))
  const v4 = all.filter((address) => !address.includes(':')).sort((left, right) => lanRank(left) - lanRank(right))
  return [...v4, ...v6].map((address) => `http://${hostPort(address, port)}`)
}

/** 追加诊断日志；超过 5 MiB 自动轮转为 `.1`。 */
export async function record(file: string, line: string): Promise<void> {
  if (file.length === 0) return
  try {
    await mkdir(dirname(file), { recursive: true })
    try {
      const st = await stat(file)
      if (st.size >= MAX_LOG_BYTES) {
        const backup = `${file}.1`
        await unlink(backup).catch(() => undefined)
        await rename(file, backup).catch(() => undefined)
      }
    } catch {
      // 日志文件尚未创建。
    }
    await appendFile(file, `${new Date().toISOString()} pid=${String(process.pid)} ${line}\n`, 'utf8')
  } catch {
    // 诊断日志异常绝不影响主请求。
  }
}

export interface PairFailEntry {
  n: number
  until: number
  updatedAt: number
}

/**
 * 配对状态与防爆破控制器：
 * 1) `pairFails` 有界（上限 256 + 10 分钟过期清理）；
 * 2) 每个 6 位配对码自身记录 `fails`，累计错满 8 次立即作废并自动旋转新码；
 * 3) 远程隧道经 127.0.0.1 转发时优先按转发头识别来源，避免把本机回环整体锁死。
 */
export class PairingRuntime {
  private pairCode: PairCode | null = null
  private readonly pairFails = new Map<string, PairFailEntry>()
  phoneSeenAt = 0

  private readonly port: number
  private readonly logFile: string

  constructor(port: number, logFile: string) {
    this.port = port
    this.logFile = logFile
  }

  private pruneFails(now: number): void {
    for (const [peer, item] of this.pairFails) {
      if (now - item.updatedAt > PAIR_FAIL_EXPIRE_MS && item.until <= now) {
        this.pairFails.delete(peer)
      }
    }
    while (this.pairFails.size > PAIR_FAIL_MAP_CAP) {
      const oldest = this.pairFails.keys().next().value
      if (oldest === undefined) break
      this.pairFails.delete(oldest)
    }
  }

  /** 解析限流键：若经本机回环代理外网隧道请求，结合转发客户端 IP 区分来源。 */
  peerKey(remoteAddress: string | undefined, local: boolean, headers: Record<string, string | string[] | undefined>): string {
    const rawPeer = remoteAddress ?? '?'
    const isLoopback = rawPeer === '127.0.0.1' || rawPeer === '::1' || rawPeer === '::ffff:127.0.0.1'
    if (!local && isLoopback) {
      const cf = headers['cf-connecting-ip']
      if (typeof cf === 'string' && cf.trim().length > 0) return `cf:${cf.trim()}`
      const xff = headers['x-forwarded-for']
      if (typeof xff === 'string' && xff.trim().length > 0) {
        const first = xff.split(',')[0]?.trim() ?? ''
        if (first.length > 0) return `xff:${first}`
      }
      return `tunnel:${String(headers.host ?? 'remote')}`
    }
    return rawPeer
  }

  /** 获取当前有效配对码（过期则自动换新）。 */
  ensurePair(): PairCode {
    if (this.pairCode === null || this.pairCode.expiresAt <= Date.now()) {
      this.pairCode = { code: freshPairCode(), expiresAt: Date.now() + PAIR_TTL_MS, fails: 0 }
      void record(this.logFile, `pair code minted ttl=${String(PAIR_TTL_MS)}`)
    }
    return this.pairCode
  }

  /** 立即作废旧码并铸造新 6 位配对码。 */
  rotatePair(clearPeerLocks = false): PairCode {
    this.pairCode = { code: freshPairCode(), expiresAt: Date.now() + PAIR_TTL_MS, fails: 0 }
    if (clearPeerLocks) this.pairFails.clear()
    void record(this.logFile, 'pair code rotated')
    return this.pairCode
  }

  /** 检查该 peer 是否处于冷却锁定期。 */
  lockedUntil(peer: string, now = Date.now()): number {
    this.pruneFails(now)
    const gate = this.pairFails.get(peer)
    return gate !== undefined && gate.until > now ? gate.until : 0
  }

  /** 在读取请求体前预占一次尝试计数，防止并发猜码共享同一次计数。 */
  reserveAttempt(peer: string, now = Date.now()): PairFailEntry {
    this.pruneFails(now)
    const gate = this.pairFails.get(peer)
    const expired = gate !== undefined && gate.until !== 0 && gate.until <= now
    const attempt: PairFailEntry = gate === undefined || expired
      ? { n: 1, until: 0, updatedAt: now }
      : { n: gate.n + 1, until: 0, updatedAt: now }
    this.pairFails.delete(peer)
    this.pairFails.set(peer, attempt)
    this.pruneFails(now)
    return attempt
  }

  /**
   * 核验配对码：
   * - 成功：旋转新码并清除该 peer 失败记录；
   * - 失败：累增 peer 失败次数与配对码自身 `fails`，满 8 次立即作废旧码并旋转新码。
   */
  verifyClaim(
    peer: string,
    attempt: PairFailEntry,
    given: string,
    isLoopbackTunnel: boolean,
  ): { ok: true } | { ok: false; left: number; rotated: boolean } {
    const pending = this.ensurePair()
    if (given.length === 6 && tokenMatches(given, pending.code)) {
      this.rotatePair(false)
      this.pairFails.delete(peer)
      this.phoneSeenAt = Date.now()
      return { ok: true }
    }

    pending.fails += 1
    let rotated = false
    if (pending.fails >= PAIR_FAIL_LIMIT) {
      this.rotatePair(false)
      rotated = true
      void record(this.logFile, `pair code burned after ${String(PAIR_FAIL_LIMIT)} wrong claims; rotated`)
    }

    // 若为无独立转发 IP 的回环隧道桶，依赖每码 8 次即焚旋转防爆破，不锁死整个隧道入口。
    const lockPeer = !isLoopbackTunnel && attempt.n >= PAIR_FAIL_LIMIT
    const next: PairFailEntry = {
      n: attempt.n,
      until: lockPeer ? Date.now() + PAIR_LOCK_MS : 0,
      updatedAt: Date.now(),
    }
    this.pairFails.set(peer, next)
    const codeLeft = Math.max(0, PAIR_FAIL_LIMIT - pending.fails)
    const peerLeft = Math.max(0, PAIR_FAIL_LIMIT - next.n)
    return { ok: false, left: rotated ? 0 : Math.min(codeLeft, peerLeft), rotated }
  }

  /** 构造桌面设置面板与 `/api/pair/state` 共享的状态快照（不含明文 token）。 */
  snapshot(): Record<string, unknown> {
    const prefs = pairPrefs()
    const pending = this.ensurePair()
    const lan = lanBases(this.port)
    const primary = prefs.allowLan && lan.length > 0 ? (lan[0] as string) : prefs.publicUrl
    const tunnelUrl = prefs.allowRemote ? prefs.publicUrl : ''
    const restLan = lan.slice(1).filter((one) => one !== primary)
    const v4rest = restLan.filter((one) => !one.includes('['))
    const v6rest = restLan.filter((one) => one.includes('['))
    const alts = [tunnelUrl, ...v4rest, ...v6rest].filter((one) => one.length > 0 && one !== primary)
    return {
      ok: true,
      host: hostname(),
      hostId: resolveHostId(),
      e2ee: true,
      e2eePub: resolveE2eeKeypair().pub,
      devices: pairedDevices(),
      version: VERSION,
      port: this.port,
      code: pending.code,
      expiresAt: pending.expiresAt,
      allowLan: prefs.allowLan,
      allowRemote: prefs.allowRemote,
      publicUrl: prefs.publicUrl,
      answerMode: answerMode(),
      allowTerminal: allowTerminal(),
      previewPorts: previewPorts(),
      lan,
      alts,
      base: primary,
      phoneSeenAt: this.phoneSeenAt,
      phoneOnline: this.phoneSeenAt > 0 && Date.now() - this.phoneSeenAt < PHONE_ONLINE_MS,
      sessions: true,
    }
  }
}

/** 幂等请求体摘要（SHA-256 前 32 位十六进制）。 */
export const hashText = (text: string): string => createHash('sha256').update(text).digest('hex').slice(0, 32)
