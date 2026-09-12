/**
 * lib/config.js 的离线单测：默认值、夹紧、路径解析，以及「插件传给脚本的参数」
 * 与「脚本真正声明的参数」一致性（参数名写错就会在这里挂掉，而不是等到窗口起不来）。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  CORNERS,
  DEFAULTS,
  MAX_REFRESH_SECONDS,
  MIN_REFRESH_SECONDS,
  THEMES,
  buildWindowArgs,
  resolveBalanceConfig,
  resolveDshHome,
  resolvePowerShell,
} from '../lib/config.js'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const scriptPath = join(root, 'assets', 'balance-window.ps1')

/** 构造一份「测试态」配置，把环境与脚本路径固定住。 */
function config(raw, env = { DSH_HOME: 'C:\\dsh-home' }) {
  return resolveBalanceConfig(raw, { env, scriptPath, parentPid: 4242 })
}

test('未给 config 时回落到默认值，并把三个路径解析到 DSH 主目录下', () => {
  const cfg = config(undefined)
  assert.equal(cfg.enabled, true)
  assert.equal(cfg.refreshSeconds, DEFAULTS.refreshSeconds)
  assert.equal(cfg.corner, 'top-right')
  assert.equal(cfg.currency, '')
  assert.equal(cfg.baseUrl, 'https://api.deepseek.com')
  assert.equal(cfg.credentialEnv, 'DEEPSEEK_API_KEY')
  assert.equal(cfg.credentialFile, join('C:\\dsh-home', '.credentials.yaml'))
  assert.equal(cfg.statePath, join('C:\\dsh-home', 'plugins', 'dsh-api-balance', 'state.json'))
  assert.equal(cfg.usagePath, join('C:\\dsh-home', 'plugins', 'dsh-api-balance', 'usage.json'))
  assert.equal(cfg.backgroundsDir, join('C:\\dsh-home', 'plugins', 'dsh-api-balance', 'backgrounds'))
  assert.equal(cfg.scriptPath, resolve(scriptPath))
  assert.equal(cfg.parentPid, 4242)
})

test('enabled: false 只在显式写 false 时生效', () => {
  assert.equal(config({ enabled: false }).enabled, false)
  assert.equal(config({ enabled: true }).enabled, true)
  assert.equal(config({ enabled: 'no' }).enabled, true)
})

test('刷新间隔被夹紧到允许区间，非法值回落默认', () => {
  assert.equal(config({ refreshSeconds: 15 }).refreshSeconds, 15)
  assert.equal(config({ refreshSeconds: 3 }).refreshSeconds, MIN_REFRESH_SECONDS)
  assert.equal(config({ refreshSeconds: 999999 }).refreshSeconds, MAX_REFRESH_SECONDS)
  assert.equal(config({ refreshSeconds: '90' }).refreshSeconds, 90)
  assert.equal(config({ refreshSeconds: 'abc' }).refreshSeconds, DEFAULTS.refreshSeconds)
  assert.equal(config({ refreshSeconds: null }).refreshSeconds, DEFAULTS.refreshSeconds)
})

test('未知角落回落默认，四个合法值都保留', () => {
  for (const corner of CORNERS) {
    assert.equal(config({ corner }).corner, corner)
  }
  assert.equal(config({ corner: 'middle' }).corner, DEFAULTS.corner)
  assert.equal(config({ corner: '  bottom-left  ' }).corner, 'bottom-left')
})

test('主题：默认 navy，七个合法值都保留，未知值回落', () => {
  assert.equal(config(undefined).theme, DEFAULTS.theme)
  for (const theme of THEMES) {
    assert.equal(config({ theme }).theme, theme)
  }
  assert.equal(config({ theme: 'neon' }).theme, DEFAULTS.theme)
  assert.equal(config({ theme: '  light  ' }).theme, 'light')
})

test('主题表与脚本里的主题表必须一一对应', () => {
  // 两处各有一份主题清单：JS 侧负责校验配置，PS 侧负责画。漏同步就会出现
  // 「配置通过了但窗口不认识这个名字」——静默回落成默认色，很难查。
  const source = readFileSync(scriptPath, 'utf8')
  const block = /\$script:Themes = \[ordered\]@\{([\s\S]*?)\r?\n\}/.exec(source)
  assert.ok(block, '脚本里应当有 $script:Themes 定义')
  const declared = [...block[1].matchAll(/^\s{4}([a-z]+)\s*=/gm)].map((m) => m[1])
  assert.deepEqual(declared.sort(), [...THEMES].sort(), `脚本与 lib/config.js 的主题清单不一致：脚本有 ${declared.join(',')}`)
})

test('DSH_HOME 优先于用户目录，USERPROFILE 作为兜底', () => {
  assert.equal(resolveDshHome({ DSH_HOME: 'D:\\harness' }), resolve('D:\\harness'))
  assert.equal(resolveDshHome({ DSH_HOME: '  ' , USERPROFILE: 'C:\\Users\\me' }), join(resolve('C:\\Users\\me'), '.dsh'))
  assert.equal(resolveDshHome({ HOME: '/home/me' }), join(resolve('/home/me'), '.dsh'))
})

test('自定义 stateDir / credentialFile 覆盖默认位置', () => {
  const cfg = config({ stateDir: 'D:\\state', credentialFile: 'D:\\keys.yaml' })
  assert.equal(cfg.statePath, join(resolve('D:\\state'), 'state.json'))
  assert.equal(cfg.credentialFile, 'D:\\keys.yaml')
})

test('powershell 路径默认取系统自带 5.1，可被配置覆盖', () => {
  const cfg = config(undefined)
  assert.equal(
    resolvePowerShell(cfg, { SystemRoot: 'C:\\Windows' }),
    join('C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
  )
  assert.equal(resolvePowerShell(config({ powershell: 'D:\\pwsh.exe' }), {}), 'D:\\pwsh.exe')
})

test('buildWindowArgs 用「开关 + 取值」成对给出，且不含任何密钥', () => {
  const cfg = config({ refreshSeconds: 30 })
  const args = buildWindowArgs(cfg)

  assert.deepEqual(args.slice(0, 5), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File'])
  assert.equal(args[5], cfg.scriptPath)

  const pairs = new Map()
  for (let i = 6; i < args.length; i += 2) {
    assert.match(args[i], /^-/, `第 ${i} 项应当是开关：${args[i]}`)
    pairs.set(args[i], args[i + 1])
  }
  assert.equal(pairs.get('-RefreshSeconds'), '30')
  assert.equal(pairs.get('-ParentPid'), '4242')
  assert.equal(pairs.get('-Theme'), DEFAULTS.theme)
  assert.equal(pairs.get('-StatePath'), cfg.statePath)
  assert.equal(pairs.get('-UsagePath'), cfg.usagePath)
  assert.equal(pairs.get('-BackgroundDir'), cfg.backgroundsDir, '背景图文件夹要传给窗口')
  assert.notEqual(cfg.usagePath, cfg.statePath, '窗口位置与 token 用量必须分属两个文件，避免两个进程互相覆盖')
  assert.equal(pairs.get('-CredentialEnv'), 'DEEPSEEK_API_KEY')
  assert.equal(pairs.get('-Corner'), 'top-right')
  assert.equal(pairs.has('-Currency'), false, '未指定币种时不应传 -Currency')

  const serialized = args.join(' ')
  assert.doesNotMatch(serialized, /sk-/, 'API Key 绝不能出现在命令行里')
})

test('指定币种时补上 -Currency', () => {
  const args = buildWindowArgs(config({ currency: 'USD' }))
  assert.equal(args[args.indexOf('-Currency') + 1], 'USD')
})

test('插件传的每个开关都在脚本的 param 块里声明过', () => {
  const source = readFileSync(scriptPath, 'utf8')
  const block = /^param\(([\s\S]*?)^\)/m.exec(source)
  assert.ok(block, '脚本里应当有 param(...) 块')

  const declared = new Set()
  for (const match of block[1].matchAll(/\[[A-Za-z0-9_.]+\]\s*\$([A-Za-z0-9_]+)/g)) {
    declared.add(match[1])
  }
  assert.ok(declared.has('Probe'), '脚本应当保留诊断用的 -Probe')

  const args = buildWindowArgs(config({ currency: 'CNY' }))
  for (let i = 6; i < args.length; i += 2) {
    const name = args[i].slice(1)
    assert.ok(declared.has(name), `脚本未声明参数 -${name}（插件却在传）`)
  }
})
