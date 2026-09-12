/**
 * 联网冒烟测试：真正调用一次 DeepSeek 余额接口，验证凭据可用、响应解析正确。
 *
 * 默认跳过——它会消耗真实凭据并依赖网络。手动验证时：
 *   $env:DSH_API_BALANCE_LIVE = '1'; npm test
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { resolveBalanceConfig, resolvePowerShell } from '../lib/config.js'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const scriptPath = join(root, 'assets', 'balance-window.ps1')
const live = process.env.DSH_API_BALANCE_LIVE === '1'

test('用真实凭据抓一次余额（-Probe，不创建窗口）', { skip: !live || process.platform !== 'win32' }, () => {
  const cfg = resolveBalanceConfig(undefined, { env: process.env, scriptPath })
  const result = spawnSync(
    resolvePowerShell(cfg),
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath, '-Probe'],
    { encoding: 'utf8' },
  )

  const line = result.stdout.trim().split(/\r?\n/).filter(Boolean).pop() ?? ''
  const payload = JSON.parse(line)
  assert.equal(payload.ok, true, `抓取失败：${line}`)
  assert.match(payload.currency, /^[A-Z]{3}$/)
  assert.match(payload.total, /^\d+(\.\d+)?$/)
  assert.match(payload.display, /^\D?\d/)
})
