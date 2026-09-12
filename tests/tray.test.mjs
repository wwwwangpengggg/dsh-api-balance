/**
 * 托盘往返的真实自检：把窗口跑起来，走一遍「点 × → 收进托盘 → 从托盘菜单叫回来」。
 *
 * 这是唯一能覆盖真实 Windows 消息与 FormClosing 管线的测试——单测证明不了它。
 * 默认跳过（它会在屏幕上闪一个真窗口），用下面这条打开：
 *   $env:DSH_API_BALANCE_WINDOW = '1'; npm test
 *
 * 它抓到过的真问题：ShowDialog 的模态循环在窗体不可见时就结束，于是「× 收进托盘」
 * 会顺手把进程一起结束掉。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'

import { resolveBalanceConfig, resolvePowerShell } from '../lib/config.js'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const scriptPath = join(root, 'assets', 'balance-window.ps1')
const enabled = process.env.DSH_API_BALANCE_WINDOW === '1'

test('点 × 收进托盘，托盘菜单能把窗口叫回来', { skip: !enabled || process.platform !== 'win32' }, () => {
  const cfg = resolveBalanceConfig(undefined, { env: process.env, scriptPath })
  const scratch = mkdtempSync(join(tmpdir(), 'dsh-api-balance-tray-'))

  try {
    const result = spawnSync(resolvePowerShell(cfg), [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-SelfTest',
      '-ParentPid', '0',
      // 独立互斥量：别和用户桌面上正在跑的那个小窗打架。
      '-InstanceName', 'DshApiBalanceTrayTest',
      '-CredentialFile', cfg.credentialFile,
      '-StatePath', join(scratch, 'state.json'),
      '-UsagePath', join(scratch, 'usage.json'),
    ], { encoding: 'utf8', timeout: 60_000 })

    const output = `${result.stdout}${result.stderr}`
    assert.match(output, /SELFTEST PASS/, `窗口自检没有通过：\n${output}`)
    assert.equal(result.status, 0, `自检退出码应为 0：\n${output}`)
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
})
