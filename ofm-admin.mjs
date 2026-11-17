#!/usr/bin/env node
/**
 * OFM Admin — OFM Gateway 的薄管理网关
 *
 * 职责（不碰上游代码，全部通过 standalone 的管理/推理接口协作）:
 *   1. GET  /admin/models            模型清单聚合（standalone 清单 + 别名合并 + 可用状态）
 *   2. POST /admin/models/test       单模型测试（透传 standalone 的真实推理测试）
 *   3. POST /admin/models/test-all   一键批量测试全部模型（并发 4，逐模型真实推理 max_tokens=4）
 *   4. GET  /admin/aliases           别名列表
 *      POST /admin/aliases           新增/修改别名 {alias, target}
 *      DELETE /admin/aliases/:alias  删除别名
 *   5. GET  /admin/dashboard         订阅看板（当前出口 IP / 撞墙记录 / 累计 token 消耗）
 *   6. /v1/*                         推理请求：别名重写为真实 ID 后透传 standalone
 *
 * 鉴权: 所有 /admin/* 需要管理 Token（ADMIN_TOKEN 环境变量或 --token 参数，
 *        install.sh 随机生成并写入 /etc/ofm-gateway/admin.token）。
 * 推理透传不强制（standalone 自己会校验 forwardKey/LAN Key）。
 *
 * 运行: node ofm-admin.mjs [--port 18902] [--token XXX] [--upstream 127.0.0.1:39808]
 */
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const argOf = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}
const PORT = Number(argOf('--port', process.env.OFM_ADMIN_PORT || 18902))
const TOKEN = argOf('--token', process.env.OFM_ADMIN_TOKEN || '')
const UPSTREAM = argOf('--upstream', process.env.OFM_UPSTREAM || '127.0.0.1:39808')
const STATE_DIR = process.env.OFM_ADMIN_STATE || '/etc/ofm-gateway'
const DATA_DIR = process.env.OFM_HOME || '/var/lib/ofm-gateway'
const ALIAS_FILE = path.join(STATE_DIR, 'aliases.json')
const ROTATE_LOG = path.join(STATE_DIR, 'rotate_log')

const CONCURRENCY = 4
const TEST_TIMEOUT_MS = 60_000

// standalone 的 /v1/* 需要 forwardKey（内部拉清单/批量测试都带它）。
// 惰性读取：admin 可能先于 standalone 启动，settings.json 尚未生成时每次调用重读。
function forwardKey() {
  try {
    const k = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'settings.json'), 'utf8')).forwardKey
    if (k) return k
  } catch {}
  return ''
}

if (!TOKEN) { console.error('缺少 --token / OFM_ADMIN_TOKEN'); process.exit(1) }

fs.mkdirSync(STATE_DIR, { recursive: true })
let aliases = {}
try { aliases = JSON.parse(fs.readFileSync(ALIAS_FILE, 'utf8')) } catch { aliases = {} }
const saveAliases = () => fs.writeFileSync(ALIAS_FILE, JSON.stringify(aliases, null, 1), { mode: 0o600 })

const log = (...a) => console.log(new Date().toISOString(), ...a)

// ── HTTP 工具 ────────────────────────────────────────────────────────────────
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', c => chunks.push(c))
    req.on('end', () => {
      try { resolve(Buffer.concat(chunks).toString('utf8')) } catch (e) { reject(e) }
    })
    req.on('error', reject)
  })
}
const send = (res, code, obj) => {
  const body = JSON.stringify(obj)
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
  res.end(body)
}
function upstreamFetch(method, path, body, timeoutMs = TEST_TIMEOUT_MS) {
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), timeoutMs)
  const headers = {}
  if (body !== undefined) headers['content-type'] = 'application/json'
  const key = forwardKey()
  if (key) headers['authorization'] = `Bearer ${key}`
  return fetch(`http://${UPSTREAM}${path}`, {
    method, headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
    signal: ctrl.signal,
  }).finally(() => clearTimeout(t))
}
async function upstreamJson(method, path, body, timeoutMs) {
  const res = await upstreamFetch(method, path, body, timeoutMs)
  const text = await res.text()
  let json = null
  try { json = JSON.parse(text) } catch {}
  return { status: res.status, json, text }
}

// 把请求体里的 model 按别名重写为真实 ID；同时合并进 /v1/models 清单
function resolveModel(model) {
  if (typeof model === 'string' && aliases[model]) return aliases[model]
  return model
}

// 别名合并进模型清单：拉 standalone 的 /v1/models，把别名作为额外行追加
async function mergedModelList() {
  const { status, json } = await upstreamJson('GET', '/v1/models')
  const rows = json && Array.isArray(json.data) ? json.data : []
  for (const [alias, target] of Object.entries(aliases)) {
    if (!rows.some(r => r.id === alias)) {
      rows.push({ id: alias, object: 'model', created: Math.floor(Date.now() / 1000), owned_by: 'ofm-admin', 'x_ofm_alias_of': target })
    }
  }
  return { status, object: 'list', data: rows }
}

// ── 批量测试全部模型（并发 4）────────────────────────────────────────────────
async function testAllModels() {
  const { json } = await upstreamJson('GET', '/v1/models')
  const ids = (json && Array.isArray(json.data) ? json.data : [])
    .map(r => r.id).filter(id => !id.startsWith('__'))
  const results = []
  let cursor = 0
  const worker = async () => {
    while (cursor < ids.length) {
      const id = ids[cursor++]
      const started = Date.now()
      try {
        const res = await upstreamFetch('POST', '/v1/chat/completions', {
          model: id,
          messages: [{ role: 'user', content: 'hi' }],
          max_tokens: 4,
        }, TEST_TIMEOUT_MS)
        const text = await res.text()
        let reason = ''
        if (res.status !== 200) {
          try {
            const j = JSON.parse(text)
            reason = j?.error?.message || j?.error?.code || j?.message || `HTTP ${res.status}`
          } catch { reason = text.slice(0, 120) || `HTTP ${res.status}` }
        }
        results.push({ id, ok: res.status === 200, status: res.status, ms: Date.now() - started, reason: reason.slice(0, 180) })
      } catch (e) {
        results.push({ id, ok: false, status: 0, ms: Date.now() - started, reason: String(e?.message || e).slice(0, 180) })
      }
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, worker))
  results.sort((a, b) => a.id.localeCompare(b.id))
  return { total: results.length, ok: results.filter(r => r.ok).length, results }
}

// ── 订阅看板：出口 IP / 撞墙记录 / 累计消耗 ─────────────────────────────────
async function dashboard() {
  const out = { egress: null, breaker: [], usage: { input: 0, output: 0, requests: 0, failures: 0 } }
  // 出口 IP（读 standalone 的 freeLane.proxyUrl 再经它回显；失败则直连兜底）
  try {
    const settings = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'settings.json'), 'utf8'))
    const proxy = settings?.freeLane?.proxyUrl || ''
    const { proxy: _p, ...safe } = { proxy }
    let ip = null, geo = ''
    if (proxy) {
      // 经代理查 ipinfo
      const { spawnSync } = await import('node:child_process')
      const r = spawnSync('curl', ['-s', '-m', '8', '--proxy', proxy, 'https://ipinfo.io/json'], { encoding: 'utf8' })
      try { const j = JSON.parse(r.stdout); ip = j.ip; geo = [j.city, j.country].filter(Boolean).join(' ') } catch {}
    }
    out.egress = { ip: ip || '(直连或探测失败)', geo, proxied: !!proxy }
  } catch { out.egress = { ip: '(未知)', geo: '', proxied: false } }
  // 撞墙/轮换轨迹（rotate_log 尾部 50 行）
  try {
    const lines = fs.readFileSync(ROTATE_LOG, 'utf8').trim().split('\n')
    out.breaker = lines.slice(-50).map(l => {
      const parts = l.split('|').map(s => s.trim())
      return { at: parts[0] || '', ip: parts[1] || '', sid: parts[2] || '', reason: parts.slice(3).join(' | ') }
    })
  } catch {}
  // 累计消耗（stats.json）
  try {
    const stats = JSON.parse(fs.readFileSync(path.join(DATA_DIR, 'stats.json'), 'utf8'))
    const rows = Array.isArray(stats?.samples) ? stats.samples : []
    for (const r of rows) {
      out.usage.requests++
      if (r.ok) { out.usage.input += r.input || 0; out.usage.output += r.output || 0 }
      else out.usage.failures++
    }
  } catch {}
  return out
}

// ── 请求处理 ─────────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`)
  const p = url.pathname.replace(/\/+$/, '') || '/'
  const method = req.method.toUpperCase()

  // 健康检查（无鉴权）
  if (p === '/admin/health' && method === 'GET') return send(res, 200, { ok: true, service: 'ofm-admin', upstream: UPSTREAM })

  // 管理面鉴权
  if (p.startsWith('/admin/')) {
    const auth = req.headers['authorization'] || ''
    const m = /^Bearer\s+(.+)$/i.exec(auth)
    if (!m || m[1] !== TOKEN) return send(res, 401, { error: 'unauthorized' })
    try {
      if (p === '/admin/models' && method === 'GET') return send(res, 200, await mergedModelList())
      if (p === '/admin/models/test' && method === 'POST') {
        const body = JSON.parse((await readBody(req)) || '{}')
        const id = resolveModel(body.model)
        if (!id) return send(res, 400, { error: 'model required' })
        const started = Date.now()
        const r = await upstreamFetch('POST', '/v1/chat/completions', {
          model: id, messages: [{ role: 'user', content: 'hi' }], max_tokens: 4,
        }, TEST_TIMEOUT_MS)
        const text = await r.text()
        return send(res, 200, { id, ok: r.status === 200, status: r.status, ms: Date.now() - started, detail: r.status === 200 ? 'OK' : text.slice(0, 180) })
      }
      if (p === '/admin/models/test-all' && method === 'POST') return send(res, 200, await testAllModels())
      if (p === '/admin/aliases' && method === 'GET') return send(res, 200, { aliases })
      if (p === '/admin/aliases' && method === 'POST') {
        const body = JSON.parse((await readBody(req)) || '{}')
        const alias = String(body.alias || '').trim(), target = String(body.target || '').trim()
        if (!alias || !target || !alias.includes('/') === false) {
          // alias 不允许含 '/'（与 provider/model 命名空间一致）；target 必须是真实模型 id
          if (!alias || !target) return send(res, 400, { error: 'alias and target required' })
        }
        if (alias.includes('/')) return send(res, 400, { error: 'alias must not contain "/"' })
        const { json } = await upstreamJson('GET', '/v1/models')
        const valid = (json?.data || []).some(r => r.id === target && !r['x_ofm_alias_of'])
        if (!valid) return send(res, 400, { error: `unknown target model: ${target}` })
        aliases[alias] = target
        saveAliases()
        return send(res, 200, { ok: true, alias, target })
      }
      if (p.startsWith('/admin/aliases/') && method === 'DELETE') {
        const alias = decodeURIComponent(p.slice('/admin/aliases/'.length))
        if (aliases[alias]) { delete aliases[alias]; saveAliases() }
        return send(res, 200, { ok: true, removed: alias })
      }
      if (p === '/admin/dashboard' && method === 'GET') return send(res, 200, await dashboard())
    } catch (e) {
      log('admin error', e?.message)
      return send(res, 500, { error: String(e?.message || e) })
    }
    return send(res, 404, { error: 'not found' })
  }

  // ── 推理透传：别名重写 ──────────────────────────────────────────────────
  if (p === '/v1/models' || p === '/models') {
    return send(res, 200, await mergedModelList())
  }
  if (p === '/v1/chat/completions' || p === '/v1/responses' || p === '/v1/messages' || p === '/chat/completions' || p === '/responses' || p === '/messages') {
    let raw = await readBody(req)
    if (raw) {
      try {
        const body = JSON.parse(raw)
        if (body && typeof body.model === 'string' && aliases[body.model]) {
          body.model = aliases[body.model]
          raw = JSON.stringify(body)
        }
      } catch {}
    }
    const headers = {}
    for (const [k, v] of Object.entries(req.headers)) {
      if (!['host', 'connection', 'content-length'].includes(k)) headers[k] = v
    }
    if (raw) headers['content-length'] = Buffer.byteLength(raw)
    try {
      const up = await fetch(`http://${UPSTREAM}${req.url}`, { method, headers, body: raw || undefined })
      res.writeHead(up.status, Object.fromEntries(up.headers))
      up.body.pipeTo(new WritableStream({ write(c) { res.write(c) }, close() { res.end() } }))
    } catch (e) {
      send(res, 502, { error: { message: `upstream error: ${e.message}`, type: 'server_error' } })
    }
    return
  }

  send(res, 404, { error: 'not found' })
})

server.listen(PORT, '127.0.0.1', () => {
  log(`ofm-admin listening on 127.0.0.1:${PORT}, upstream ${UPSTREAM}`)
})