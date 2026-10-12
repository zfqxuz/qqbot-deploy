#!/usr/bin/env node
/**
 * dsh-web-run.mjs —— dsh web 的启动器（四种启动方式共用同一份实现）
 *
 *   容器 entrypoint-harness.sh / Linux systemd / macOS launchd / Windows 计划任务
 *   全部用它起 dsh，于是**不管哪种部署模式**都会做同一件事：
 *     把 dsh 真正监听的地址登记下来，控制台就不用"猜"宿主端口了。
 *
 * 为什么需要（2026-10-12 的坑）：
 *   桥接插件和 DSH 是解耦的（插件在 dsh 进程里跑，只自己开 6700 听 OneBot 反连），
 *   DSH 监听哪个端口它完全不关心。真正需要知道端口的是**控制台**（另一个进程/容器）：
 *   它要探活、要给"打开 DSH"的链接。容器模式下控制台是独立 PID 命名空间，
 *   扫 /proc 找不到 dsh 进程，于是只能靠环境变量 QQ_DSH_PORT —— 一旦配置漂了，
 *   页面就报"宿主不可用"，而机器上其实跑得好好的。
 *   控制台已经支持读 <数据根>/state/dsh-web-url.txt 与 <数据根>/logs/dsh-web.log，
 *   这里负责把它们写新鲜。
 *
 * 用法：
 *   node dsh-web-run.mjs --port 3081 --data-root ~/qqbot -- <命令…>
 *   # 省略 `--` 就是起 dsh web --no-open --port <port>
 *
 * 参数：
 *   --port <n>        端口（默认取 DSH_PORT / QQ_DSH_PORT / 3081；只用于默认命令与预告地址）
 *   --data-root <dir> 数据根（默认 QQ_DATA_ROOT 或当前目录）；写 state/ 与 logs/
 *   --no-log          不追加 logs/dsh-web.log（只登记 state/dsh-web-url.txt）
 *   -h, --help        这段
 *
 * 行为：
 *   1. 起命令，stdout/stderr 原样转发（docker logs / journald / launchd 照旧能看到）；
 *   2. 立刻登记 `http://127.0.0.1:<port>/`（端口已知、token 还不知道），
 *      之后一旦从输出里认出 `http://…:<port>/?token=…` 就补全成带 token 的真实地址；
 *   3. 收到 TERM/INT/HUP 转发给子进程，退出码照原样带出。
 *
 * 登记文件写入是"临时文件 + rename"，控制台不会读到半截；文件权限 0600（里面有 token）。
 */
import { spawn, spawnSync } from 'node:child_process'
import { appendFileSync, chmodSync, existsSync, mkdirSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const HELP = `用法：node dsh-web-run.mjs --port <端口> --data-root <数据根> [--no-log] -- <命令…>

不写 <命令…> 时默认起：dsh web --no-open --port <端口>
[--harness-owner <qq-harness-owner.mjs>] 起 dsh 前先登记宿主心跳（托管权，见 SPEC §3 L1），退出时移除。
它会顺带把真实地址登记到 <数据根>/state/dsh-web-url.txt 并追加 <数据根>/logs/dsh-web.log。`

const URL_RE = /https?:\/\/[^\s"'`]+?:(\d+)\/\?token=([A-Za-z0-9._~-]+)/

function parseArgv(argv) {
  const opts = { port: null, dataRoot: '', log: true, harnessOwner: '' }
  let i = 0
  for (; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--') return { opts, cmd: argv.slice(i + 1) }
    if (a === '-h' || a === '--help') { console.log(HELP); process.exit(0) }
    if (a === '--port') { opts.port = Number(argv[++i]); continue }
    if (a === '--data-root') { opts.dataRoot = String(argv[++i] ?? ''); continue }
    if (a === '--no-log') { opts.log = false; continue }
    if (a === '--harness-owner') { opts.harnessOwner = String(argv[++i] ?? ''); continue }
    console.error(`[dsh-web-run] 未知参数：${a}\n\n${HELP}`)
    process.exit(2)
  }
  return { opts, cmd: [] }
}

const { opts, cmd } = parseArgv(process.argv.slice(2))
const port = Number.isInteger(opts.port) && opts.port > 0 && opts.port <= 65535
  ? opts.port
  : Number(process.env.DSH_PORT || process.env.QQ_DSH_PORT || 3081)
const dataRoot = opts.dataRoot || process.env.QQ_DATA_ROOT || process.cwd()
const stateFile = join(dataRoot, 'state', 'dsh-web-url.txt')
const logFile = join(dataRoot, 'logs', 'dsh-web.log')
const command = cmd.length > 0 ? cmd : ['dsh', 'web', '--no-open', '--port', String(port)]

// [托管权] 宿主优先（SPEC §3 L1）：起 dsh 之前先在共享名册里占位，避免同机容器 harness
// 在这个启动窗口里把 home 抢走；dsh 里的插件会接续写自己的心跳，本进程退出时移除这一条。
const OWNER_INSTANCE = `host-launcher-${process.pid}`
const ownerCli = (() => {
  const candidates = [opts.harnessOwner, process.env.QQ_HARNESS_OWNER_CLI, process.env.QQ_BRIDGE_DIR ? join(process.env.QQ_BRIDGE_DIR, 'control', 'bin', 'qq-harness-owner.mjs') : '', join(process.env.HOME || '', 'qqbot', 'src', 'dsh-qq-onebot-bridge', 'control', 'bin', 'qq-harness-owner.mjs')]
  return candidates.map((item) => String(item ?? '')).find((item) => item !== '' && existsSync(item)) ?? ''
})()
function ownerAction(action) {
  if (ownerCli === '') return
  // [fix 2026-10-12] 容器里不写"宿主"心跳：本进程可能是 supervisor 的子进程（QQ_HARNESS_OWNED_BY），
  // 或者本身就是容器（QQ_HARNESS_KIND=container）—— 这时再登记一条 kind=host 的心跳，
  // 会被容器里的 supervisor 当成"宿主回来了"，满 T2 后把自己的 harness drain 掉（自杀循环）。
  // 宿主场景（install.sh 直接起）两个变量都为空，照旧登记。
  if (String(process.env.QQ_HARNESS_KIND ?? '').trim() === 'container') return
  if (String(process.env.QQ_HARNESS_OWNED_BY ?? '').trim() !== '') return
  try {
    const result = spawnSync(process.execPath, [ownerCli, '--kind', 'host', `--${action}`, '--instance', OWNER_INSTANCE, '--port', String(port)], { encoding: 'utf8', timeout: 10_000 })
    const line = String(result.stdout ?? '').trim().split('\n').pop() ?? ''
    if (line !== '') console.log(`[dsh-web-run] 托管权${action === 'claim' ? '登记' : '释放'}：${line}`)
  } catch (error) {
    console.error(`[dsh-web-run] 托管权${action} 失败（不影响启动）：${error.message}`)
  }
}
ownerAction('claim')

const LOG_MAX = 8 * 1024 * 1024 // 超过就轮转一份 .1，避免长跑把盘写满

function ensureDirs() {
  try {
    mkdirSync(join(dataRoot, 'state'), { recursive: true })
    if (opts.log) mkdirSync(join(dataRoot, 'logs'), { recursive: true })
    return true
  } catch (err) {
    console.error(`[dsh-web-run] ⚠ 建不了 ${dataRoot}/state|logs（${err.message}）：地址登记跳过，dsh 照常起`)
    return false
  }
}
const writable = ensureDirs()

/** 原子登记：先写 .tmp 再 rename，控制台读不到半截内容。 */
function registerUrl(url) {
  if (!writable) return
  try {
    const tmp = `${stateFile}.tmp`
    writeFileSync(tmp, `${url}\n`, { mode: 0o600 })
    renameSync(tmp, stateFile)
    chmodSync(stateFile, 0o600)
  } catch (err) {
    console.error(`[dsh-web-run] ⚠ 登记地址失败（${err.message}）`)
  }
}

function rotateLog() {
  if (!writable || !opts.log) return
  try {
    if (statSync(logFile).size > LOG_MAX) renameSync(logFile, `${logFile}.1`)
  } catch { /* 文件不存在就算了 */ }
}

function appendLog(chunk) {
  if (!writable || !opts.log) return
  try {
    appendFileSync(logFile, chunk, { mode: 0o600 })
  } catch { /* 磁盘满/权限变了都不该拖垮 dsh */ }
}

// 先登记"端口已知、token 未知"的预告地址：控制台立刻就能探到这个端口
registerUrl(`http://127.0.0.1:${port}/`)
rotateLog()

const child = spawn(command[0], command.slice(1), { stdio: ['inherit', 'pipe', 'pipe'], env: process.env })

let seenUrl = ''
let tail = ''
function handleChunk(chunk, out) {
  out.write(chunk)          // 原样转发（docker logs / journald 照旧）
  appendLog(chunk)          // 同时留一份给控制台（logs/dsh-web.log）
  tail = (tail + chunk.toString('utf8')).slice(-4096)
  const match = URL_RE.exec(tail)
  if (match && match[0] !== seenUrl) {
    seenUrl = match[0]
    registerUrl(seenUrl)
    console.error(`[dsh-web-run] 已登记宿主地址：${seenUrl} → ${stateFile}`)
  }
}
child.stdout.on('data', (c) => handleChunk(c, process.stdout))
child.stderr.on('data', (c) => handleChunk(c, process.stderr))

child.on('error', (err) => {
  console.error(`[dsh-web-run] ✗ 起不来（${command.join(' ')}）：${err.message}`)
  process.exit(err.code === 'ENOENT' ? 127 : 126)
})

const SIGNALS = { SIGTERM: 15, SIGINT: 2, SIGHUP: 1 }
let stopping = false
for (const sig of Object.keys(SIGNALS)) {
  process.on(sig, () => {
    if (stopping) return
    stopping = true
    child.kill(sig)
    // 兜底：3 秒还没退出就强杀，别让 docker stop / systemctl stop 卡到超时
    setTimeout(() => { try { child.kill('SIGKILL') } catch { /* 已经退了 */ } }, 3000).unref()
  })
}
process.on('exit', () => {
  ownerAction('release')
  if (!stopping) { try { child.kill('SIGTERM') } catch { /* 已经退了 */ } }
})

child.on('exit', (code, signal) => {
  stopping = true
  process.exit(code ?? (signal ? 128 + (SIGNALS[signal] ?? 0) : 0))
})
