/**
 * DSH 设置面板同源路由：配对状态、二维码、连接与安全权限开关，以及本机管理员可见的反馈工单。
 */
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parsePreviewPorts, validatePublicUrl } from './http-util.ts'
import { dshHome, type AnswerMode, type PairedDeviceRecord } from './state.ts'

export interface PanelPrefs {
  allowLan: boolean
  allowRemote: boolean
  publicUrl: string
  answerMode: AnswerMode
  allowTerminal: boolean
  previewPorts: number[]
}

export interface PanelCtx {
  pairState(): Record<string, unknown>
  rotatePair(): void
  writePrefs(next: PanelPrefs): void
  revokeDevice(deviceId: string, revoked: boolean): { ok: true; devices: PairedDeviceRecord[] } | { ok: false; error: string }
  pairPayload(base: string, code: string, alts: string[]): string
  record(line: string): Promise<void>
}

export interface PanelBundle {
  routes: readonly Record<string, unknown>[]
}

const PANEL_PREFIX = '/api/dsh-mobile/panel'

const panelJson = (status: number, payload: unknown): Response =>
  new Response(JSON.stringify(payload), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })

const qrSvg = async (text: string): Promise<string | null> => {
  try {
    const mod: any = await import('qrcode')
    const code = mod?.default ?? mod
    const svg: unknown = await code.toString(text, { type: 'svg', margin: 1, width: 240, errorCorrectionLevel: 'M' })
    return typeof svg === 'string' ? svg : null
  } catch {
    return null
  }
}

const panelBody = async (request: Request): Promise<{ ok: true; data: Record<string, unknown> } | { ok: false; error: string }> => {
  try {
    const text = await request.text()
    if (text.trim().length === 0) return { ok: true, data: {} }
    const parsed: unknown = JSON.parse(text)
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return { ok: true, data: parsed as Record<string, unknown> }
    }
    return { ok: false, error: '请求体必须是 JSON 对象' }
  } catch {
    return { ok: false, error: '请求体 JSON 格式不合法' }
  }
}

const FEEDBACK_BASE = (process.env.AGENT_MOBILE_FEEDBACK_URL ?? 'https://feedback.juo.de5.net').trim()

const feedbackKey = (): string => {
  if (FEEDBACK_BASE === '') return ''
  try {
    const file = join(dshHome(), 'feedback-admin.key')
    if (!existsSync(file)) return ''
    return readFileSync(file, 'utf8').trim()
  } catch {
    return ''
  }
}

interface FeedbackReply {
  code: number
  data: Record<string, unknown>
}

const feedbackCall = async (method: string, path: string, body?: unknown): Promise<FeedbackReply> => {
  if (FEEDBACK_BASE === '') {
    return { code: 503, data: { error: '未配置反馈服务地址' } }
  }
  const key = feedbackKey()
  try {
    const headers: Record<string, string> = { authorization: `Bearer ${key}` }
    if (body !== undefined) headers['content-type'] = 'application/json; charset=utf-8'
    const res = await fetch(FEEDBACK_BASE + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    let data: Record<string, unknown> = {}
    try {
      const parsed: unknown = JSON.parse(text)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        data = parsed as Record<string, unknown>
      }
    } catch {
      data = { error: text.slice(0, 300) || `HTTP ${String(res.status)}` }
    }
    return { code: res.status, data }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return { code: 0, data: { error: message } }
  }
}

export const createPanel = (ctx: PanelCtx): PanelBundle => {
  const panelSnapshot = (): Record<string, unknown> => {
    const snapshot = ctx.pairState()
    const base = String(snapshot.base ?? '')
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const payload = base.length > 0 ? ctx.pairPayload(base, String(snapshot.code ?? ''), alts) : ''
    return { ...snapshot, payload }
  }

  const panelConfig = async (request: Request): Promise<Response> => {
    const parsedBody = await panelBody(request)
    if (!parsedBody.ok) {
      return panelJson(400, { error: parsedBody.error })
    }
    const body = parsedBody.data
    const current = ctx.pairState() as Record<string, unknown>

    let publicUrl = String(current.publicUrl ?? '')
    if (body.publicUrl !== undefined) {
      if (typeof body.publicUrl !== 'string') {
        return panelJson(400, { error: '公网地址必须是字符串' })
      }
      const checked = validatePublicUrl(body.publicUrl)
      if (!checked.ok) {
        return panelJson(400, { error: checked.error })
      }
      publicUrl = checked.url
    }

    let nextAnswerMode: AnswerMode = current.answerMode === 'desktop' ? 'desktop' : 'phone'
    if (body.answerMode !== undefined) {
      if (body.answerMode !== 'phone' && body.answerMode !== 'desktop') {
        return panelJson(400, { error: '回答模式只能是 phone 或 desktop' })
      }
      nextAnswerMode = body.answerMode
    }

    let nextAllowTerminal = current.allowTerminal !== false
    if (body.allowTerminal !== undefined) {
      if (typeof body.allowTerminal !== 'boolean') {
        return panelJson(400, { error: '允许远程终端开关必须是布尔值' })
      }
      nextAllowTerminal = body.allowTerminal
    }

    let nextPreviewPorts: number[] = Array.isArray(current.previewPorts)
      ? (current.previewPorts as number[])
      : []
    if (body.previewPorts !== undefined) {
      const checkedPorts = parsePreviewPorts(body.previewPorts)
      if (!checkedPorts.ok) {
        return panelJson(400, { error: checkedPorts.error })
      }
      nextPreviewPorts = checkedPorts.ports
    }

    const next: PanelPrefs = {
      allowLan: typeof body.allowLan === 'boolean' ? body.allowLan : Boolean(current.allowLan),
      allowRemote: typeof body.allowRemote === 'boolean' ? body.allowRemote : Boolean(current.allowRemote),
      publicUrl,
      answerMode: nextAnswerMode,
      allowTerminal: nextAllowTerminal,
      previewPorts: nextPreviewPorts,
    }

    ctx.writePrefs(next)
    await ctx.record(
      `200 PANEL config lan=${String(next.allowLan)} remote=${String(next.allowRemote)} answer=${next.answerMode} term=${String(next.allowTerminal)} ports=${next.previewPorts.join(',')}`,
    )
    return panelJson(200, panelSnapshot())
  }

  const panelQr = async (request: Request): Promise<Response> => {
    const url = new URL(request.url)
    const asked = url.searchParams.get('payload')
    const snapshot = ctx.pairState()
    const base = String(snapshot.base ?? '')
    const alts = Array.isArray(snapshot.alts) ? (snapshot.alts as string[]) : []
    const text = asked !== null && asked.length > 0
      ? asked
      : base.length > 0
        ? ctx.pairPayload(base, String(snapshot.code ?? ''), alts)
        : ''
    if (text.length === 0) {
      return panelJson(409, { error: '当前没有可用的连接地址，请开启「局域网直连」或填写公网地址' })
    }
    const svg = await qrSvg(text)
    if (svg === null) {
      return panelJson(503, { error: '二维码组件未就绪，请使用下方 6 位配对码连接' })
    }
    return new Response(svg, {
      status: 200,
      headers: { 'content-type': 'image/svg+xml; charset=utf-8', 'cache-control': 'no-store' },
    })
  }

  const feedbackState = async (): Promise<Response> => {
    if (FEEDBACK_BASE === '' || feedbackKey() === '') return panelJson(200, { configured: false })
    const list = await feedbackCall('GET', '/v1/admin/tickets?limit=60')
    if (list.code !== 200) {
      return panelJson(list.code === 0 ? 502 : list.code, { configured: true, error: String(list.data.error ?? '获取反馈列表失败') })
    }
    const sum = await feedbackCall('GET', '/v1/admin/summary')
    const tickets = Array.isArray(list.data.tickets) ? list.data.tickets : []
    return panelJson(200, { configured: true, tickets, summary: sum.data })
  }

  const feedbackReply = async (request: Request): Promise<Response> => {
    const parsedBody = await panelBody(request)
    if (!parsedBody.ok) return panelJson(400, { error: parsedBody.error })
    const body = parsedBody.data
    const id = typeof body.id === 'string' ? body.id : ''
    const text = typeof body.text === 'string' ? body.text.trim() : ''
    if (id === '' || text === '') return panelJson(400, { error: '工单 ID 和回复内容不能为空' })
    const status = typeof body.status === 'string' ? body.status : ''
    const payload: Record<string, unknown> = { text }
    if (status !== '') payload.status = status
    const r = await feedbackCall('POST', `/v1/admin/tickets/${encodeURIComponent(id)}/reply`, payload)
    return panelJson(r.code === 0 ? 502 : r.code, r.data)
  }

  const feedbackStatus = async (request: Request): Promise<Response> => {
    const parsedBody = await panelBody(request)
    if (!parsedBody.ok) return panelJson(400, { error: parsedBody.error })
    const body = parsedBody.data
    const id = typeof body.id === 'string' ? body.id : ''
    const status = typeof body.status === 'string' ? body.status : ''
    if (id === '' || status === '') return panelJson(400, { error: '工单 ID 和目标状态不能为空' })
    const r = await feedbackCall('POST', `/v1/admin/tickets/${encodeURIComponent(id)}/status`, { status })
    return panelJson(r.code === 0 ? 502 : r.code, r.data)
  }

  const feedbackFile = async (request: Request): Promise<Response> => {
    if (FEEDBACK_BASE === '') return panelJson(503, { error: '未配置反馈服务地址' })
    const key = feedbackKey()
    if (key === '') return panelJson(503, { error: '未配置管理员密钥' })
    const url = new URL(request.url)
    const id = url.searchParams.get('id') ?? ''
    const name = url.searchParams.get('name') ?? ''
    if (id === '' || name === '') return panelJson(400, { error: '缺少附件参数 id 或 name' })
    try {
      const res = await fetch(
        `${FEEDBACK_BASE}/v1/admin/files/${encodeURIComponent(id)}/${encodeURIComponent(name)}`,
        { headers: { authorization: `Bearer ${key}` } },
      )
      if (!res.ok) return panelJson(res.status, { error: `上游返回 HTTP ${String(res.status)}` })
      const bytes = Buffer.from(await res.arrayBuffer())
      return new Response(bytes, {
        status: 200,
        headers: {
          'content-type': res.headers.get('content-type') ?? 'application/octet-stream',
          'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
          'cache-control': 'no-store',
        },
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return panelJson(502, { error: message })
    }
  }

  const panelDeviceRevoke = async (request: Request): Promise<Response> => {
    const parsedBody = await panelBody(request)
    if (!parsedBody.ok) return panelJson(400, { error: parsedBody.error })
    const body = parsedBody.data
    const deviceId = typeof body.deviceId === 'string' ? body.deviceId.trim() : ''
    if (deviceId === '' || typeof body.revoked !== 'boolean') {
      return panelJson(400, { error: 'deviceId 不能为空且 revoked 必须为布尔值' })
    }
    const result = ctx.revokeDevice(deviceId, body.revoked)
    if (!result.ok) {
      return panelJson(404, { error: result.error })
    }
    await ctx.record(`200 PANEL device-revoke device=${deviceId} revoked=${String(body.revoked)}`)
    return panelJson(200, panelSnapshot())
  }

  const routes: readonly Record<string, unknown>[] = [
    { path: `${PANEL_PREFIX}/state`, methods: ['GET'], requestBody: 'buffered', fetch: async () => panelJson(200, panelSnapshot()) },
    {
      path: `${PANEL_PREFIX}/newcode`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async () => {
        ctx.rotatePair()
        return panelJson(200, panelSnapshot())
      },
    },
    { path: `${PANEL_PREFIX}/config`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => panelConfig(request) },
    { path: `${PANEL_PREFIX}/devices/revoke`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => panelDeviceRevoke(request) },
    { path: `${PANEL_PREFIX}/qr.svg`, methods: ['GET'], requestBody: 'buffered', fetch: async (request: Request) => panelQr(request) },
    { path: `${PANEL_PREFIX}/feedback/state`, methods: ['GET'], requestBody: 'buffered', fetch: async () => feedbackState() },
    { path: `${PANEL_PREFIX}/feedback/reply`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => feedbackReply(request) },
    { path: `${PANEL_PREFIX}/feedback/status`, methods: ['POST'], requestBody: 'buffered', fetch: async (request: Request) => feedbackStatus(request) },
    { path: `${PANEL_PREFIX}/feedback/file`, methods: ['GET'], requestBody: 'buffered', fetch: async (request: Request) => feedbackFile(request) },
  ]

  return { routes }
}
