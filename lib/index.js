/**
 * dsh-api-balance —— 宿主侧插件。
 *
 * 职责边界刻意很窄，只有两件事：
 *
 *   1. 在 DSH 启动时拉起桌面余额小窗，并在插件卸载时关掉它；
 *   2. 把「本次开机以来消耗的 token」写进 usage.json，供小窗轮询显示。
 *
 * 抓余额、画界面、看门狗全在 assets/balance-window.ps1 里，因此：
 *
 *   - 密钥不经过 DSH 的 IPC，也不出现在任何命令行里；
 *   - 小窗不依赖主窗口，主窗口最小化/切换会话都不影响它；
 *   - 抓取失败只影响小窗自己的显示，不会让 DSH 启动变慢或报错。
 *
 * token 用量的口径：监听 `session/event`（每条提交的会话事件都会经过这里）里携带
 * provider 用量的两种事件。因为监听是在 apply 时挂上的，只会看到本次开机之后追加的
 * 事件，所以「本次开机」是订阅时机自带的，不需要记录基线；子代理的用量同样会被
 * 计进来。折叠语义见 lib/usage.js。
 *
 * 用法（profile 的 cordis.patch.yml，或本包自带的 cordis.patch.yml）：
 *   - id: api-balance
 *     name: dsh-api-balance
 *     config:
 *       refreshSeconds: 60
 *       corner: top-right
 *
 * @module dsh-api-balance
 */
import { existsSync, mkdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildWindowArgs, resolveBalanceConfig, resolvePowerShell } from './config.js'
import { createUsageTracker, foldUsage, usagePayload } from './usage.js'
import { startBalanceWindow } from './window.js'

/** Cordis 插件名。 */
export const name = 'dsh-api-balance'

/** 不依赖任何服务：这是一条只做桌面副作用的行。 */
export const inject = []

/** lib/index.js → 包根目录。 */
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)))

/** usage.json 的最小写入间隔：一轮对话会产生大量事件，没必要逐个落盘。 */
const MIN_WRITE_INTERVAL_MS = 1000

/**
 * 原子写一个小 JSON 文件。
 *
 * 先写同目录的临时文件再改名：窗口可能正在读这个文件，半截内容会解析失败。
 * @param path - 目标文件。
 * @param payload - 可 JSON 序列化的载荷。
 */
export function writeJsonFile(path, payload) {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp`
  writeFileSync(temporary, JSON.stringify(payload), 'utf8')
  renameSync(temporary, path)
}

/**
 * 装配「本次开机 token 用量」的统计与落盘。
 *
 * 与平台无关：即使不开窗口（非 Windows），用量照样统计并落盘。拆成独立函数是为了
 * 能在不拉起窗口的前提下单测「事件 → 折叠 → 文件」这条链。
 * @param ctx - 宿主 cordis 上下文。
 * @param cfg - 已规范化的配置。
 * @param log - 日志器。
 */
export function applyUsageTracking(ctx, cfg, log) {
  let tracker = createUsageTracker()
  let timer = null
  let lastWriteAt = 0

  const flush = () => {
    timer = null
    lastWriteAt = Date.now()
    try {
      writeJsonFile(cfg.usagePath, usagePayload(tracker))
    } catch (error) {
      log.warn(`写入 token 用量失败：${error instanceof Error ? error.message : String(error)}`)
    }
  }
  const scheduleFlush = () => {
    if (timer !== null) return
    const wait = Math.max(0, MIN_WRITE_INTERVAL_MS - (Date.now() - lastWriteAt))
    timer = setTimeout(flush, wait)
  }

  ctx.on('session/event', (_session, event) => {
    const next = foldUsage(tracker, event)
    // 折叠器在「与本次累计无关」时返回同一个引用，据此跳过绝大多数事件。
    if (next === tracker) return
    tracker = next
    scheduleFlush()
  })

  ctx.effect(() => {
    // 先落一份 0 值：窗口一启动就有文件可读，不会显示成「暂无数据」。
    flush()
    return () => {
      if (timer !== null) {
        clearTimeout(timer)
        timer = null
      }
      flush()
    }
  }, 'dsh-api-balance: token 用量落盘')
}

/**
 * 拉起桌面小窗。
 * @param ctx - 宿主 cordis 上下文。
 * @param cfg - 已规范化的配置。
 * @param log - 日志器。
 */
export function applyWindow(ctx, cfg, log) {
  if (process.platform !== 'win32') {
    log.warn(`桌面小窗依赖 Windows 窗体，当前平台 ${process.platform} 不支持，已跳过`)
    return
  }
  if (!existsSync(cfg.scriptPath)) {
    log.warn(`找不到小窗脚本：${cfg.scriptPath}`)
    return
  }

  ctx.effect(() => {
    const command = resolvePowerShell(cfg)
    const handle = startBalanceWindow({
      command,
      args: buildWindowArgs(cfg),
      cwd: packageRoot,
      log,
    })
    if (handle === null) return () => {}
    log.info(`余额小窗已启动（pid ${handle.pid}，每 ${cfg.refreshSeconds}s 刷新）`)
    return () => handle.stop()
  }, 'dsh-api-balance: 桌面余额小窗')
}

/**
 * 装配余额小窗与 token 用量统计。
 * @param ctx - 宿主 cordis 上下文。
 * @param config - cordis.patch.yml 里该行的 config。
 */
export function apply(ctx, config) {
  const log = {
    info: (message) => console.log(`[dsh-api-balance] ${message}`),
    warn: (message) => console.warn(`[dsh-api-balance] ${message}`),
  }

  const cfg = resolveBalanceConfig(config, {
    scriptPath: join(packageRoot, 'assets', 'balance-window.ps1'),
    parentPid: process.pid,
  })

  if (!cfg.enabled) {
    log.info('已在配置中禁用（enabled: false），不显示余额小窗')
    return
  }

  applyUsageTracking(ctx, cfg, log)
  applyWindow(ctx, cfg, log)
}
