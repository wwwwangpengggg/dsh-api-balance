/**
 * dsh-api-balance —— 宿主侧插件。
 *
 * 职责边界刻意很窄，只有两件事：
 *
 *   1. 在 DSH 启动时拉起桌面余额小窗，并在插件卸载时关掉它；
 *   2. 把「今天累计消耗的 token」写进 usage.json，供小窗轮询显示。
 *
 * 抓余额、画界面、看门狗全在 assets/balance-window.ps1 里，因此：
 *
 *   - 密钥不经过 DSH 的 IPC，也不出现在任何命令行里；
 *   - 小窗不依赖主窗口，主窗口最小化/切换会话都不影响它；
 *   - 抓取失败只影响小窗自己的显示，不会让 DSH 启动变慢或报错。
 *
 * token 用量的口径：监听 `session/event`（每条提交的会话事件都会经过这里）里携带
 * provider 用量的两种事件。因为监听是在 apply 时挂上的，只看得见本次开机之后追加的
 * 事件；而用户一天里会反复开关 DSH，所以在落盘时把本次开机的量并进文件里已有的分条
 * 记录（按「哪一次开机」分条），跨开机累加成**当天合计**——日界与「今日消费」共用
 * 同一个 `dayStartHour`。子代理的用量同样会被计进来。折叠与合并语义见 lib/usage.js。
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
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildWindowArgs, resolveBalanceConfig, resolvePowerShell } from './config.js'
import { createUsageTracker, foldUsage, usageDayKey, usageDayPayload, usageSnapshot } from './usage.js'
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
 * 读回上次落盘的 usage.json。
 *
 * 读不到、坏掉、格式不对一律当「没有历史」——绝不能让一个缓存文件把插件装配搞失败。
 * @param path - usage.json 的路径。
 * @returns 解析后的载荷，或 null。
 */
function readUsageFile(path) {
  try {
    if (!existsSync(path)) return null
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    return parsed !== null && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

/**
 * 装配「今天累计 token 用量」的统计与落盘。
 *
 * 与平台无关：即使不开窗口（非 Windows），用量照样统计并落盘。拆成独立函数是为了
 * 能在不拉起窗口的前提下单测「事件 → 折叠 → 文件」这条链。
 *
 * 落盘时把「本次开机」的量并进文件里当天已有的分条记录，于是**跨多次开机**累加成当天
 * 合计——用户一天里反复开关 DSH 是常态，只报「本次开机」会严重低估。日界由
 * `cfg.dayStartHour` 决定，与「今日消费」是同一个窗口。
 * @param ctx - 宿主 cordis 上下文。
 * @param cfg - 已规范化的配置。
 * @param log - 日志器。
 * @param deps - 依赖注入：`now` 用来在测试里把时钟钉住（跨天行为靠它才测得动）。
 */
export function applyUsageTracking(ctx, cfg, log, deps = {}) {
  const now = deps.now ?? (() => new Date())
  // 本次开机的标识。同一次开机内保持不变，这样每次落盘都只更新自己那一条记录，
  // 不会覆盖别的实例（同时开着的桌面版 / web profile）留下的数字。
  const bootKey = `${process.pid}@${now().toISOString()}`
  let tracker = createUsageTracker()
  let timer = null
  let lastWriteAt = 0

  const flush = () => {
    timer = null
    lastWriteAt = Date.now()
    try {
      const at = now()
      // 每次都重读：另一个实例可能刚更新过它那一条，重读才不会把它的数字抹掉。
      const previous = readUsageFile(cfg.usagePath)
      writeJsonFile(cfg.usagePath, usageDayPayload(previous, usageSnapshot(tracker), usageDayKey(at, cfg.dayStartHour), bootKey, at))
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
/**
 * 检查小窗脚本有没有 UTF-8 BOM，没有就大声警告。
 *
 * Windows PowerShell 5.1 对无 BOM 的 .ps1 按本地 ANSI 代码页解码，脚本里的中文会变成
 * 乱码——而且乱码会出现在**字符串字面量**里，直接把脚本解析坏掉。症状是「窗口完全不出现、
 * 日志里又没有明显错误」，非常难查（这个坑实际发生过）。这里提前把它喊出来。
 * @param scriptPath - 小窗脚本路径。
 * @param log - 日志器。
 */
export function warnIfScriptLacksBom(scriptPath, log) {
  try {
    const head = readFileSync(scriptPath).subarray(0, 3)
    if (!(head[0] === 0xef && head[1] === 0xbb && head[2] === 0xbf)) {
      log.warn(
        `小窗脚本缺少 UTF-8 BOM（${scriptPath}）：PowerShell 5.1 会把中文按 ANSI 解码，`
        + '脚本会解析失败、窗口不会出现。在项目目录跑 `npm run prepare` 可修复。',
      )
    }
  } catch {
    // 读不了就交给后面的启动逻辑去报错，这里不额外制造噪音。
  }
}

/**
 * 造一个可以反复开关的小窗控制器。
 *
 * 「开」有两种触发：插件挂载时自动开一次，以及用户后来用 `/balance` 再开。
 * 「关」有三种触发：用户从托盘里退出、DSH 退出时的插件卸载、以及 `/balance` 再按一次。
 *
 * 句柄按「代」区分（record）：关掉再开之后，上一代进程的异步 exit 回调不能把新一代的
 * 句柄清掉，否则刚打开就会被记成「已关闭」。
 * @param cfg - 已规范化的配置。
 * @param log - 日志器。
 * @param options - 可选注入点（spawnImpl），供单测替换真实进程。
 * @returns { open, close, toggle, isOpen } 控制器。
 */
export function createWindowController(cfg, log, options = {}) {
  let current = null

  const controller = {
    /**
     * 打开小窗；已经在开则不动。
     * @returns 'opened' | 'already-open' | 'failed'
     */
    open() {
      if (current !== null) return 'already-open'
      const record = {}
      const handle = startBalanceWindow({
        command: resolvePowerShell(cfg),
        args: buildWindowArgs(cfg),
        cwd: packageRoot,
        log,
        spawnImpl: options.spawnImpl,
        onExit: () => {
          if (current === record) current = null
        },
      })
      if (handle === null) return 'failed'
      record.handle = handle
      current = record
      log.info(`余额小窗已启动（pid ${handle.pid}，每 ${cfg.refreshSeconds}s 刷新）`)
      return 'opened'
    },
    /**
     * 关闭小窗；本来就没开则不动。
     * @returns 'closed' | 'already-closed'
     */
    close() {
      if (current === null) return 'already-closed'
      const record = current
      current = null
      record.handle.stop()
      return 'closed'
    },
    /**
     * 开则关、关则开。
     * @returns 一次开关的结果。
     */
    toggle() {
      return current === null ? controller.open() : controller.close()
    },
    /**
     * 小窗是否正被本插件持有。
     * @returns 布尔值。
     */
    isOpen() {
      return current !== null
    },
  }

  return controller
}

/**
 * 注册 `/balance` 命令，让用户在小窗被彻底关掉之后还能把它叫回来。
 *
 * 整段都包在保护里：命令注册表是可选能力，注册失败只该少一条命令，
 * 绝不该把「显示余额小窗」这个主功能一起拖下水。
 * @param ctx - 宿主 cordis 上下文。
 * @param controller - 小窗控制器。
 * @param log - 日志器。
 */
export function registerBalanceCommand(ctx, controller, log) {
  let commands
  try {
    commands = typeof ctx.get === 'function' ? ctx.get('commands') : undefined
  } catch (error) {
    log.warn(`读取命令注册表失败：${error instanceof Error ? error.message : String(error)}`)
    return
  }
  if (commands === undefined || typeof commands.register !== 'function') {
    log.info('当前组合里没有命令注册表，跳过 /balance')
    return
  }

  const describe = (outcome) => {
    switch (outcome) {
      case 'opened': return '余额小窗已打开。'
      case 'already-open': return '余额小窗已经是打开状态。'
      case 'closed': return '余额小窗已关闭。'
      case 'already-closed': return '余额小窗本来就是关闭的。'
      default: return '余额小窗没能启动，请查看 DSH 日志里 [dsh-api-balance] 的输出。'
    }
  }

  try {
    ctx.effect(() => {
      const dispose = commands.register({
        name: 'balance',
        description: '打开或关闭桌面余额小窗',
        handler: () => ({ kind: 'success', text: describe(controller.toggle()) }),
      })
      return () => dispose()
    }, 'dsh-api-balance: /balance 命令')
  } catch (error) {
    log.warn(`注册 /balance 失败：${error instanceof Error ? error.message : String(error)}`)
  }
}

/**
 * 拉起桌面小窗，并装上 `/balance` 命令。
 * @param ctx - 宿主 cordis 上下文。
 * @param cfg - 已规范化的配置。
 * @param log - 日志器。
 * @returns 小窗控制器；平台不支持或脚本缺失时为 null。
 */
export function applyWindow(ctx, cfg, log) {
  if (process.platform !== 'win32') {
    log.warn(`桌面小窗依赖 Windows 窗体，当前平台 ${process.platform} 不支持，已跳过`)
    return null
  }
  if (!existsSync(cfg.scriptPath)) {
    log.warn(`找不到小窗脚本：${cfg.scriptPath}`)
    return null
  }
  warnIfScriptLacksBom(cfg.scriptPath, log)

  const controller = createWindowController(cfg, log)
  ctx.effect(() => {
    controller.open()
    return () => controller.close()
  }, 'dsh-api-balance: 桌面余额小窗')
  registerBalanceCommand(ctx, controller, log)
  return controller
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
