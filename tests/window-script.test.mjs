/**
 * assets/balance-window.ps1 的静态检查：文件确实存在、带 UTF-8 BOM（否则 5.1 会把
 * 中文读成乱码），并且能被 PowerShell 自己的解析器编译通过。
 *
 * 这里不启动窗口：窗口的行为由 tests/live.test.mjs（默认跳过）和人工验证覆盖。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { resolveBalanceConfig, resolvePowerShell } from '../lib/config.js'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const scriptPath = join(root, 'assets', 'balance-window.ps1')
const BOM = Buffer.from([0xef, 0xbb, 0xbf])

test('小窗脚本存在且以 UTF-8 BOM 开头', () => {
  assert.ok(existsSync(scriptPath), `缺少小窗脚本：${scriptPath}`)
  const bytes = readFileSync(scriptPath)
  assert.ok(
    bytes.subarray(0, 3).equals(BOM),
    '缺少 UTF-8 BOM：Windows PowerShell 5.1 会按 ANSI 解码，中文会乱码。跑 `npm run prepare` 可修复',
  )
})

test('脚本包含看门狗、单实例互斥与诊断模式三件套', () => {
  const source = readFileSync(scriptPath, 'utf8')
  const required = [
    [/ParentPid/, '父进程看门狗'],
    [/System\.Threading\.Mutex/, '命名互斥量保证单实例'],
    [/if \(\$Probe\)/, 'Probe 诊断分支'],
    [/TopMost\s*=\s*\$true/, '窗口置顶'],
    [/-Path \$StatePath/, '位置记忆文件'],
    [/DrawString/, '自绘内容'],
  ]
  for (const [pattern, label] of required) {
    assert.ok(pattern.test(source), `小窗脚本缺少${label}（未匹配 ${pattern}）`)
  }
})

test('PowerShell 解析器能编译这个小窗脚本', { skip: process.platform !== 'win32' }, () => {
  const cfg = resolveBalanceConfig(undefined, { env: {}, scriptPath })
  const command = [
    '$errors = $null',
    `[void][System.Management.Automation.Language.Parser]::ParseFile('${scriptPath.replace(/'/g, "''")}', [ref]$null, [ref]$errors)`,
    'if ($errors -and $errors.Count -gt 0) {',
    '  $errors | ForEach-Object { Write-Output ($_.Message + " @line " + $_.Extent.StartLineNumber) }',
    '  exit 1',
    '}',
    'exit 0',
  ].join('\n')

  const result = spawnSync(resolvePowerShell(cfg), ['-NoProfile', '-NonInteractive', '-Command', command], {
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, `脚本存在语法错误：\n${result.stdout}${result.stderr}`)
})
