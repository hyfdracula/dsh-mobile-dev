/**
 * 工作区文件系统与本机目录浏览路由：
 * - `GET /api/host/dirs`（本机常用根与盘符探测、会话近期工作区、逐级子目录浏览）
 * - `GET /api/sessions/:id/fs`（支持 `offset` / `limit` 分页）
 * - `POST /api/sessions/:id/fs/mkdir`（创建单层目录）
 * - `POST /api/sessions/:id/fs/upload`（Base64 批量上传文件，防覆盖 409）
 * - `/fs/file`、`/fs/rename`、`/fs/delete`、`/fs/sign`、`/fs/raw`、`/fs/download`
 */
import {
  createReadStream,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmdirSync,
  statSync,
  unlinkSync,
} from 'node:fs'
import { writeFile } from 'node:fs/promises'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { homedir } from 'node:os'
import { basename, dirname, extname, join, resolve, sep } from 'node:path'
import { readJson, send } from '../http-util.ts'
import { projectSessions } from '../projections.ts'
import { record } from '../state.ts'

const MAX_FS_UPLOAD_BYTES = 32 * 1024 * 1024

const SYSTEM_SKIP_DIRS = new Set([
  '$recycle.bin',
  '$winreagent',
  'system volume information',
  'recovery',
  'perflogs',
  'config.msi',
  'documents and settings',
  'node_modules',
  '.git',
  '.hvigor',
  'oh_modules',
])

export interface WorkspaceFsHelper {
  cwdOf: (sid: string) => Promise<string>
  rootOf: (sid: string) => Promise<{ root: string; fallback: boolean }>
  underRoot: (root: string, rel: string) => string | null
  writeTarget: (root: string, rel: string, mustExist: boolean) => string | null
  tryHandle: (req: IncomingMessage, res: ServerResponse, url: URL, path: string, method: string) => Promise<boolean>
}

export function createWorkspaceFsRoutes(deps: {
  controller: () => any
  service: (name: string) => any
  sigOf: (kind: string, value: string, exp: string) => string
  sigTtlSec: number
  logFile: string
  resolveExternalCwd?: (sid: string) => Promise<string>
}): WorkspaceFsHelper {
  const tidyCwd = (raw: string): string => raw.replace(/\\\\/g, '\\')

  const cwdOf = async (sid: string): Promise<string> => {
    if (deps.resolveExternalCwd) {
      try {
        const extCwd = await deps.resolveExternalCwd(sid)
        if (extCwd) return tidyCwd(extCwd)
      } catch {
        // fall through
      }
    }
    const sessions = deps.service('sessions')
    if (sessions !== null && typeof sessions.get === 'function') {
      let live: unknown = null
      try {
        live = (sessions.get as (id: string) => unknown)(sid)
      } catch {
        live = null
      }
      if (live !== null && live !== undefined) {
        const cwd = (live as Record<string, unknown>).cwd
        if (typeof cwd === 'string' && cwd.length > 0) return tidyCwd(cwd)
      }
    }
    const ctl = deps.controller()
    if (ctl && typeof ctl.list === 'function') {
      try {
        const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(10000)))
        const row = projectSessions(listed).find((r) => r.id === sid)
        if (row !== undefined && row.cwd.length > 0) return tidyCwd(row.cwd)
      } catch {
        // fall through
      }
    }
    return ''
  }

  const rootOf = async (sid: string): Promise<{ root: string; fallback: boolean }> => {
    const cwd = await cwdOf(sid)
    if (cwd !== '') return { root: cwd, fallback: false }
    try {
      return { root: process.cwd(), fallback: true }
    } catch {
      return { root: '', fallback: false }
    }
  }

  const underRoot = (root: string, rel: string): string | null => {
    const base = resolve(root)
    const target = resolve(base, rel.length === 0 ? '.' : rel)
    if (!(target === base || target.startsWith(base + sep))) return null
    try {
      const realBase = realpathSync(base)
      const realTarget = realpathSync(target)
      return realTarget === realBase || realTarget.startsWith(realBase + sep) ? realTarget : null
    } catch {
      if (existsSync(target)) return null
      try {
        const realBase = realpathSync(base)
        let probe = dirname(target)
        while (probe.length >= base.length && !existsSync(probe)) {
          const up = dirname(probe)
          if (up === probe) break
          probe = up
        }
        const realAncestor = realpathSync(probe)
        return realAncestor === realBase || realAncestor.startsWith(realBase + sep) ? target : null
      } catch {
        return null
      }
    }
  }

  const writeTarget = (root: string, rel: string, mustExist: boolean): string | null => {
    if (rel === '') return null
    const base = resolve(root)
    const lexical = resolve(base, rel)
    if (lexical === base || !lexical.startsWith(base + sep)) return null
    let realBase = ''
    let realParent = ''
    try {
      realBase = realpathSync(base)
      realParent = realpathSync(dirname(lexical))
    } catch {
      return null
    }
    if (!(realParent === realBase || realParent.startsWith(realBase + sep))) return null
    const joined = join(realParent, basename(lexical))
    if (!mustExist) {
      try {
        const st = lstatSync(joined)
        if (st.isSymbolicLink()) return null
      } catch {
        // 目标尚不存在，符合预期。
      }
      return joined
    }
    try {
      const st = lstatSync(joined)
      if (st.isSymbolicLink()) return null
      return joined
    } catch {
      return null
    }
  }

  /** 收集已有会话中去重后的近期有效工作目录。 */
  const recentWorkspaces = async (): Promise<string[]> => {
    const ctl = deps.controller()
    if (!ctl || typeof ctl.list !== 'function') return []
    try {
      const listed = await Promise.resolve(ctl.list({}, AbortSignal.timeout(8000)))
      const seen = new Set<string>()
      const out: string[] = []
      for (const row of projectSessions(listed)) {
        const clean = tidyCwd(row.cwd).trim()
        if (clean === '') continue
        const key = process.platform === 'win32' ? clean.toLowerCase() : clean
        if (seen.has(key)) continue
        try {
          if (statSync(clean).isDirectory()) {
            seen.add(key)
            out.push(clean)
            if (out.length >= 20) break
          }
        } catch {
          // 跳过已删除的历史目录。
        }
      }
      return out
    } catch {
      return []
    }
  }

  /** 探测本机常用根目录与驱动器。 */
  const hostRootDirs = (): Array<{ name: string; path: string }> => {
    const out: Array<{ name: string; path: string }> = []
    const seen = new Set<string>()
    const addIfExists = (name: string, p: string): void => {
      const key = process.platform === 'win32' ? p.toLowerCase() : p
      if (seen.has(key)) return
      try {
        if (statSync(p).isDirectory()) {
          seen.add(key)
          out.push({ name, path: p })
        }
      } catch {
        // ignore missing dir
      }
    }

    const home = homedir()
    if (process.platform === 'win32') {
      addIfExists('用户主目录', home)
      addIfExists('Documents', join(home, 'Documents'))
      addIfExists('Desktop', join(home, 'Desktop'))
      for (let code = 65; code <= 90; code += 1) {
        const drive = `${String.fromCharCode(code)}:\\`
        addIfExists(drive, drive)
      }
    } else {
      addIfExists('用户主目录', home)
      addIfExists('Documents', join(home, 'Documents'))
      addIfExists('/', '/')
    }
    return out
  }

  const tryHandle = async (
    req: IncomingMessage,
    res: ServerResponse,
    url: URL,
    path: string,
    method: string,
  ): Promise<boolean> => {
    if (path === '/api/host/dirs' && method === 'GET') {
      const rawPath = (url.searchParams.get('path') ?? '').trim()
      const recent = await recentWorkspaces()
      if (rawPath === '') {
        const roots = hostRootDirs()
        send(res, 200, { ok: true, path: '', parent: '', roots, dirs: roots, recent })
        return true
      }

      const normalizedInput = process.platform === 'win32' && /^[A-Za-z]:$/.test(rawPath)
        ? `${rawPath}\\`
        : rawPath
      const target = resolve(normalizedInput)
      try {
        if (!statSync(target).isDirectory()) {
          send(res, 400, { error: '指定路径不是文件夹' })
          return true
        }
      } catch {
        send(res, 404, { error: '目录不存在或无权访问' })
        return true
      }

      let entries: import('node:fs').Dirent[] = []
      try {
        entries = readdirSync(target, { withFileTypes: true })
      } catch (err) {
        send(res, 403, { error: `无法读取目录：${err instanceof Error ? err.message : String(err)}` })
        return true
      }

      const dirs: Array<{ name: string; path: string }> = []
      for (const item of entries) {
        const name = item.name
        if (name.startsWith('.') || name.startsWith('$')) continue
        if (SYSTEM_SKIP_DIRS.has(name.toLowerCase())) continue
        let isDir = item.isDirectory()
        if (!isDir && item.isSymbolicLink()) {
          try {
            isDir = statSync(join(target, name)).isDirectory()
          } catch {
            isDir = false
          }
        }
        if (!isDir) continue
        dirs.push({ name, path: join(target, name) })
      }
      dirs.sort((a, b) => a.name.localeCompare(b.name))
      const limited = dirs.slice(0, 200)
      const up = dirname(target)
      const parent = up !== target ? up : ''
      send(res, 200, { ok: true, path: target, parent, dirs: limited, recent })
      return true
    }

    const fsMatch = /^\/api\/sessions\/([^/]+)\/fs$/.exec(path)
    if (fsMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(fsMatch[1] as string)
      const picked = await rootOf(sid)
      const root = picked.root
      if (root === '') {
        send(res, 404, { error: `session ${sid} has no working directory` })
        return true
      }
      const rel = String(url.searchParams.get('path') ?? '')
      const target = underRoot(root, rel)
      if (target === null) {
        send(res, 400, { error: 'path escapes the working directory' })
        return true
      }
      let names: string[] = []
      try {
        names = readdirSync(target)
      } catch (err) {
        send(res, 404, { error: `cannot read folder: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      const entries: Array<{ name: string; dir: boolean; size: number; mtime: number }> = []
      for (const name of names) {
        if (name === '.git' || name === 'node_modules' || name === '.hvigor' || name === 'oh_modules') continue
        try {
          const st = statSync(join(target, name))
          entries.push({ name, dir: st.isDirectory(), size: st.size, mtime: Math.round(st.mtimeMs) })
        } catch {
          // 跳过不可访问项。
        }
      }
      entries.sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : a.dir ? -1 : 1))

      const offsetRaw = Number(url.searchParams.get('offset') ?? '0')
      const offset = Number.isFinite(offsetRaw) ? Math.max(Math.trunc(offsetRaw), 0) : 0
      const limitRaw = Number(url.searchParams.get('limit') ?? '400')
      const limit = Number.isFinite(limitRaw) ? Math.min(Math.max(Math.trunc(limitRaw), 1), 1000) : 400

      const total = entries.length
      const page = entries.slice(offset, offset + limit)
      const nextOffset = offset + page.length
      const more = nextOffset < total

      await record(deps.logFile, `200 GET fs session=${sid} path=${rel} offset=${String(offset)} n=${String(page.length)}`)
      send(res, 200, {
        ok: true,
        root,
        path: rel,
        entries: page,
        total,
        offset,
        nextOffset,
        more,
        fallback: picked.fallback,
      })
      return true
    }

    const fsMkdirMatch = /^\/api\/sessions\/([^/]+)\/fs\/mkdir$/.exec(path)
    if (fsMkdirMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(fsMkdirMatch[1] as string)
      const picked = await rootOf(sid)
      const root = picked.root
      if (root === '' || picked.fallback) {
        send(res, 400, { error: 'session has no working directory' })
        return true
      }
      const body = await readJson(req)
      const rel = String(body.path ?? '').trim()
      const target = writeTarget(root, rel, false)
      if (target === null) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      if (existsSync(target)) {
        send(res, 409, { error: '同名文件或目录已存在' })
        return true
      }
      try {
        mkdirSync(target)
        await record(deps.logFile, `200 POST fs/mkdir session=${sid} path=${rel}`)
        send(res, 200, { ok: true, path: rel })
      } catch (err) {
        send(res, 400, { error: `cannot create folder: ${err instanceof Error ? err.message : String(err)}` })
      }
      return true
    }

    const fsUploadMatch = /^\/api\/sessions\/([^/]+)\/fs\/upload$/.exec(path)
    if (fsUploadMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(fsUploadMatch[1] as string)
      const picked = await rootOf(sid)
      const root = picked.root
      if (root === '' || picked.fallback) {
        send(res, 400, { error: 'session has no working directory' })
        return true
      }
      const body = await readJson(req, MAX_FS_UPLOAD_BYTES)
      const dirRel = String(body.dir ?? '').trim()
      const dirTarget = underRoot(root, dirRel)
      if (dirTarget === null || !existsSync(dirTarget) || !statSync(dirTarget).isDirectory()) {
        send(res, 400, { error: '目标上传目录不存在或越界' })
        return true
      }
      const rawFiles = Array.isArray(body.files) ? body.files : []
      if (rawFiles.length === 0) {
        send(res, 400, { error: 'files is empty' })
        return true
      }
      if (rawFiles.length > 50) {
        send(res, 400, { error: '单次最多上传 50 个文件' })
        return true
      }

      const planned: Array<{ relFile: string; dest: string; buf: Buffer }> = []
      const seenNames = new Set<string>()
      for (const item of rawFiles) {
        if (item === null || typeof item !== 'object') {
          send(res, 400, { error: 'each file must be an object' })
          return true
        }
        const f = item as Record<string, unknown>
        const rawName = String(f.name ?? '').trim()
        if (
          rawName === ''
          || rawName === '.'
          || rawName === '..'
          || rawName.length > 180
          || /[\\/:*?"<>|\u0000-\u001f]/.test(rawName)
        ) {
          send(res, 400, { error: `文件名不合法：${rawName || '(empty)'}` })
          return true
        }
        const nameKey = process.platform === 'win32' ? rawName.toLowerCase() : rawName
        if (seenNames.has(nameKey)) {
          send(res, 409, { error: `上传列表中存在重名文件：${rawName}` })
          return true
        }
        seenNames.add(nameKey)

        const data = String(f.data ?? '')
        if (data === '') {
          send(res, 400, { error: `文件数据为空：${rawName}` })
          return true
        }
        const relFile = dirRel === '' ? rawName : `${dirRel.replace(/[\\/]+$/, '')}/${rawName}`
        const dest = writeTarget(root, relFile, false)
        if (dest === null) {
          send(res, 400, { error: `非法的目标文件路径：${relFile}` })
          return true
        }
        if (existsSync(dest)) {
          send(res, 409, { error: `目标文件已存在：${rawName}` })
          return true
        }
        planned.push({ relFile, dest, buf: Buffer.from(data, 'base64') })
      }

      const saved: string[] = []
      let bytes = 0
      for (const one of planned) {
        try {
          await writeFile(one.dest, one.buf, { flag: 'wx' })
          saved.push(one.relFile)
          bytes += one.buf.length
        } catch (err) {
          const code = (err as NodeJS.ErrnoException).code
          if (code === 'EEXIST') {
            send(res, 409, { error: `目标文件已存在：${one.relFile}` })
            return true
          }
          send(res, 500, { error: `写入文件失败：${err instanceof Error ? err.message : String(err)}` })
          return true
        }
      }
      await record(deps.logFile, `200 POST fs/upload session=${sid} dir=${dirRel} n=${String(saved.length)} bytes=${String(bytes)}`)
      send(res, 200, { ok: true, saved, bytes })
      return true
    }

    const fsFileMatch = /^\/api\/sessions\/([^/]+)\/fs\/file$/.exec(path)
    if (fsFileMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(fsFileMatch[1] as string)
      const root = (await rootOf(sid)).root
      const rel = String(url.searchParams.get('path') ?? '')
      const target = root === '' ? null : underRoot(root, rel)
      if (root === '' || target === null) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      const LIMIT = 512 * 1024
      let buf: Buffer
      try {
        const st = statSync(target)
        if (!st.isFile()) {
          send(res, 400, { error: 'not a file' })
          return true
        }
        if (st.size > LIMIT) {
          send(res, 413, { error: `file is too large to preview (${String(st.size)} bytes)` })
          return true
        }
        buf = readFileSync(target)
      } catch (err) {
        send(res, 404, { error: `cannot read file: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      if (buf.indexOf(0) >= 0) {
        send(res, 415, { error: 'binary file: no text preview' })
        return true
      }
      send(res, 200, { ok: true, name: String(rel).split(/[\\/]/).pop() ?? rel, size: buf.length, text: buf.toString('utf8') })
      return true
    }

    const fsRenameMatch = /^\/api\/sessions\/([^/]+)\/fs\/rename$/.exec(path)
    if (fsRenameMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(fsRenameMatch[1] as string)
      const picked = await rootOf(sid)
      const root = picked.root
      if (root === '' || picked.fallback) {
        send(res, 400, { error: 'session has no working directory' })
        return true
      }
      const body = await readJson(req)
      const rel = String(body.path ?? '')
      const to = String(body.to ?? '')
      const from = writeTarget(root, rel, true)
      const dest = writeTarget(root, to, false)
      if (from === null || dest === null || from === dest) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      if (existsSync(dest)) {
        send(res, 409, { error: '目标已存在' })
        return true
      }
      try {
        renameSync(from, dest)
        await record(deps.logFile, `200 POST fs/rename session=${sid} from=${rel} to=${to}`)
        send(res, 200, { ok: true })
      } catch (err) {
        send(res, 400, { error: `cannot rename: ${err instanceof Error ? err.message : String(err)}` })
      }
      return true
    }

    const fsDeleteMatch = /^\/api\/sessions\/([^/]+)\/fs\/delete$/.exec(path)
    if (fsDeleteMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(fsDeleteMatch[1] as string)
      const picked = await rootOf(sid)
      const root = picked.root
      if (root === '' || picked.fallback) {
        send(res, 400, { error: 'session has no working directory' })
        return true
      }
      const body = await readJson(req)
      const rel = String(body.path ?? '')
      const target = writeTarget(root, rel, true)
      if (target === null) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      try {
        const st = statSync(target)
        if (st.isDirectory()) {
          rmdirSync(target)
        } else {
          unlinkSync(target)
        }
        await record(deps.logFile, `200 POST fs/delete session=${sid} path=${rel}`)
        send(res, 200, { ok: true })
      } catch (err) {
        send(res, 400, { error: `cannot delete: ${err instanceof Error ? err.message : String(err)}` })
      }
      return true
    }

    const fsSignMatch = /^\/api\/sessions\/([^/]+)\/fs\/sign$/.exec(path)
    if (fsSignMatch !== null && method === 'POST') {
      const sid = decodeURIComponent(fsSignMatch[1] as string)
      const body = await readJson(req)
      const rel = String(body.path ?? '')
      if (rel === '') {
        send(res, 400, { error: 'path is required' })
        return true
      }
      const exp = String(Math.floor(Date.now() / 1000) + deps.sigTtlSec)
      send(res, 200, { ok: true, e: exp, sig: deps.sigOf('raw', `${sid}|${rel}`, exp) })
      return true
    }

    const fsRawMatch = /^\/api\/sessions\/([^/]+)\/fs\/raw$/.exec(path)
    if (fsRawMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(fsRawMatch[1] as string)
      const root = (await rootOf(sid)).root
      const rel = String(url.searchParams.get('path') ?? '')
      const target = root === '' ? null : underRoot(root, rel)
      if (root === '' || target === null) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      const ext = extname(target).toLowerCase()
      const types: Record<string, string> = {
        '.png': 'image/png',
        '.jpg': 'image/jpeg',
        '.jpeg': 'image/jpeg',
        '.webp': 'image/webp',
        '.gif': 'image/gif',
        '.bmp': 'image/bmp',
        '.svg': 'image/svg+xml',
      }
      const type = types[ext]
      if (type === undefined) {
        send(res, 415, { error: 'not an image' })
        return true
      }
      const RAW_LIMIT = 16 * 1024 * 1024
      let size = 0
      try {
        const st = statSync(target)
        if (!st.isFile()) {
          send(res, 400, { error: 'not a file' })
          return true
        }
        if (st.size > RAW_LIMIT) {
          send(res, 413, { error: `image is too large (${String(st.size)} bytes)` })
          return true
        }
        size = st.size
      } catch (err) {
        send(res, 404, { error: `cannot read image: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      res.writeHead(200, { 'content-type': type, 'content-length': String(size), 'cache-control': 'private, max-age=60' })
      const imgStream = createReadStream(target)
      imgStream.on('error', () => {
        res.destroy()
      })
      res.on('close', () => {
        imgStream.destroy()
      })
      imgStream.pipe(res)
      return true
    }

    const fsDownloadMatch = /^\/api\/sessions\/([^/]+)\/fs\/download$/.exec(path)
    if (fsDownloadMatch !== null && method === 'GET') {
      const sid = decodeURIComponent(fsDownloadMatch[1] as string)
      const root = (await rootOf(sid)).root
      const rel = String(url.searchParams.get('path') ?? '')
      const target = root === '' ? null : underRoot(root, rel)
      if (root === '' || target === null) {
        send(res, 400, { error: 'bad path' })
        return true
      }
      const LIMIT = 64 * 1024 * 1024
      let size = 0
      try {
        const st = statSync(target)
        if (!st.isFile()) {
          send(res, 400, { error: 'not a file' })
          return true
        }
        if (st.size > LIMIT) {
          send(res, 413, { error: `file is too large to download (${String(st.size)} bytes)` })
          return true
        }
        size = st.size
      } catch (err) {
        send(res, 404, { error: `cannot read file: ${err instanceof Error ? err.message : String(err)}` })
        return true
      }
      const name = String(rel).split(/[\\/]/).pop() ?? rel
      await record(deps.logFile, `200 GET fs/download session=${sid} path=${rel} n=${String(size)}`)
      res.writeHead(200, {
        'content-type': 'application/octet-stream',
        'content-length': String(size),
        'content-disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
        'cache-control': 'private, max-age=0',
      })
      const dlStream = createReadStream(target)
      dlStream.on('error', () => {
        res.destroy()
      })
      res.on('close', () => {
        dlStream.destroy()
      })
      dlStream.pipe(res)
      return true
    }

    return false
  }

  return { cwdOf, rootOf, underRoot, writeTarget, tryHandle }
}
