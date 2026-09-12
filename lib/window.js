/**
 * dsh-api-balance —— 小窗进程的生命周期管理。
 *
 * 只做一件事：把 balance-window.ps1 作为子进程拉起，并在插件被卸载（DSH 退出、
 * 插件热重载）时把它连同整个进程树收干净。窗口自带看门狗，即使 DSH 被强杀也不会
 * 留下孤儿窗口——两条清理路径互为兜底。
 *
 * @module dsh-api-balance/window
 */
import { spawn, spawnSync } from 'node:child_process'

/** 强杀兜底的等待时间：先礼后兵。 */
const FORCE_KILL_DELAY_MS = 2000

/**
 * 启动余额小窗。
 * @param options - command/args/cwd、日志器与退出回调。
 * @returns 句柄 { pid, stop }；启动层面失败时返回 null。
 */
export function startBalanceWindow(options) {
  const { command, args, cwd, log, onExit } = options
  const spawnImpl = options.spawnImpl ?? spawn

  let child
  try {
    child = spawnImpl(command, args, {
      cwd,
      windowsHide: true,
      detached: false,
      stdio: ['ignore', 'pipe', 'pipe'],
    })
  } catch (error) {
    log.warn(`无法启动余额小窗：${error instanceof Error ? error.message : String(error)}`)
    return null
  }

  let settled = false
  let stopping = false
  let forceTimer = null
  let notified = false

  // 进程无论以哪种方式结束（托盘里退出、DSH 退出、启动失败）都只通知一次。
  // 上层据此清掉句柄：不清的话「已关闭」的状态会一直错着，下次想再打开会被
  // 当成「还开着」而直接拒绝。
  const notifyExit = () => {
    if (notified) return
    notified = true
    onExit?.()
  }

  const onOutput = (chunk) => {
    const text = String(chunk).trim()
    if (text !== '') log.info(`余额小窗输出：${text}`)
  }
  child.stdout?.on('data', onOutput)
  child.stderr?.on('data', onOutput)

  child.on('error', (error) => {
    settled = true
    log.warn(`余额小窗进程异常：${error instanceof Error ? error.message : String(error)}`)
    notifyExit()
  })

  child.on('exit', (code) => {
    settled = true
    if (forceTimer !== null) {
      clearTimeout(forceTimer)
      forceTimer = null
    }
    // 用户点 × 是收进托盘，从托盘退出才算真关闭，两种都是正常路径，不当错误报。
    log.info(`余额小窗已关闭（退出码 ${code ?? '未知'}）`)
    notifyExit()
  })

  return {
    pid: child.pid ?? 0,
    /**
     * 结束小窗进程。幂等，可在 dispose 与重复调用中安全使用。
     */
    stop() {
      if (settled || stopping) return
      stopping = true
      try {
        child.kill()
      } catch {
        // 已经退出：忽略。
      }
      forceTimer = setTimeout(() => {
        if (settled) return
        try {
          spawnSync('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true })
        } catch {
          // 兜底失败不再处理：看门狗仍会关闭窗口。
        }
      }, FORCE_KILL_DELAY_MS)
      forceTimer.unref?.()
    },
  }
}
