/**
 * 真实挂载测试：像 DSH 启动时那样调用 apply()，确认小窗进程真的被拉起、dispose 时
 * 真的被收掉。默认跳过——它会在屏幕上显示一个真实窗口。
 *
 * 手动验证：
 *   $env:DSH_API_BALANCE_WINDOW = '1'; npm test
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { apply } from '../lib/index.js'

const enabled = process.env.DSH_API_BALANCE_WINDOW === '1'

/** 进程是否还活着。 */
function isAlive(pid) {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

/** 等到进程消失，超时返回 false。 */
async function waitGone(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (!isAlive(pid)) return true
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
  return false
}

test('apply 拉起小窗，dispose 收掉它', { skip: !enabled || process.platform !== 'win32' }, async () => {
  const logs = []
  const original = console.log
  console.log = (...parts) => logs.push(parts.join(' '))

  let dispose = null
  const ctx = {
    effect(callback) {
      dispose = callback()
      return () => dispose?.()
    },
  }

  try {
    apply(ctx, {
      instanceName: 'DshApiBalanceMountTest',
      stateDir: join(tmpdir(), 'dsh-api-balance-mount-test'),
      refreshSeconds: 30,
    })
  } finally {
    console.log = original
  }

  const line = logs.find((entry) => entry.includes('余额小窗已启动'))
  assert.ok(line, `apply 应当报告小窗已启动，实际日志：${logs.join(' | ')}`)
  const pid = Number(/pid (\d+)/.exec(line)?.[1])
  assert.ok(Number.isInteger(pid) && pid > 0, `未能从日志里取出 pid：${line}`)
  assert.ok(isAlive(pid), `小窗进程 ${pid} 应当处于运行中`)

  // 停 4 秒：PowerShell + WinForms 启动约 1 秒，脚本若有语法/加载错误会在这段时间内退出。
  // 只有熬过这一段，才算「窗口真的起来了」，而不是「进程起来又立刻崩了」。
  await new Promise((resolve) => setTimeout(resolve, 4000))
  assert.ok(isAlive(pid), `小窗进程 ${pid} 在启动后 4 秒内退出了，说明脚本启动失败`)

  assert.equal(typeof dispose, 'function', 'apply 应当通过 ctx.effect 注册清理器')
  dispose()

  assert.ok(await waitGone(pid, 10000), `dispose 之后小窗进程 ${pid} 应当退出`)
})
