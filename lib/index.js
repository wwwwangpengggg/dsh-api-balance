/**
 * dsh-api-balance —— 宿主侧插件。
 *
 * 职责边界刻意很窄：插件行只负责在 DSH 启动时拉起桌面余额小窗，并在插件卸载时
 * 关掉它。抓余额、画界面、看门狗全在 assets/balance-window.ps1 里，因此：
 *
 *   - 密钥不经过 DSH 的 IPC，也不出现在任何命令行里；
 *   - 小窗不依赖主窗口，主窗口最小化/切换会话都不影响它；
 *   - 抓取失败只影响小窗自己的显示，不会让 DSH 启动变慢或报错。
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
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildWindowArgs, resolveBalanceConfig, resolvePowerShell } from './config.js'
import { startBalanceWindow } from './window.js'

/** Cordis 插件名。 */
export const name = 'dsh-api-balance'

/** 不依赖任何服务：这是一条只做桌面副作用的行。 */
export const inject = []

/** lib/index.js → 包根目录。 */
const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)))

/**
 * 装配余额小窗。
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
