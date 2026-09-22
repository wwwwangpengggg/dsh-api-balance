/**
 * 插件装配层的单测：用假的 cordis ctx 跑「session/event → 折叠 → usage.json」这条链，
 * 不需要窗口、不需要联网，也不依赖 DSH 真的把事件送过来。
 *
 * 事件本身由宿主送出这件事另有人证：`@deepseek-ai/dsh-session-persistence` 与
 * `dsh-token-meter` 都是在 profile 根上下文里 `ctx.on('session/event', ...)` 的，
 * 说明根级监听收得到这条火线。这里验证的是我们自己这一侧的接线。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { writeFileSync } from 'node:fs'

import { applyUsageTracking, warnIfScriptLacksBom, writeJsonFile } from '../lib/index.js'
import { resolveBalanceConfig } from '../lib/config.js'

test('脚本缺 UTF-8 BOM 时给出明确警告，有 BOM 时闭嘴', () => {
  // 这个坑实际发生过：edit 工具会去掉 BOM，PS 5.1 于是把中文字符串读成乱码、
  // 直接把脚本解析坏掉，症状是「窗口完全不出现但日志没错误」。
  const dir = mkdtempSync(join(tmpdir(), 'dsh-api-balance-bom-'))
  try {
    const bom = Buffer.from([0xef, 0xbb, 0xbf])
    const okPath = join(dir, 'ok.ps1')
    const badPath = join(dir, 'bad.ps1')
    writeFileSync(okPath, Buffer.concat([bom, Buffer.from('$x = "本次开机"', 'utf8')]))
    writeFileSync(badPath, Buffer.from('$x = "本次开机"', 'utf8'))

    const logs = []
    const log = { warn: (message) => logs.push(message) }

    warnIfScriptLacksBom(okPath, log)
    assert.equal(logs.length, 0, '有 BOM 不该报警')

    warnIfScriptLacksBom(badPath, log)
    assert.equal(logs.length, 1, '缺 BOM 必须报警')
    assert.match(logs[0], /BOM/)

    // 文件不存在时不该抛，交给后面的启动逻辑报错
    warnIfScriptLacksBom(join(dir, 'missing.ps1'), log)
    assert.equal(logs.length, 1)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

/** 造一个只实现 on/effect 的假 ctx，并暴露手动触发与卸载的入口。 */
function fakeContext() {
  const listeners = new Map()
  const disposers = []
  return {
    ctx: {
      on(name, listener) {
        listeners.set(name, listener)
        return () => listeners.delete(name)
      },
      effect(callback) {
        disposers.push(callback())
        return () => {}
      },
    },
    emit(name, ...args) {
      const listener = listeners.get(name)
      assert.ok(listener, `插件没有监听 ${name}`)
      listener(...args)
    },
    dispose() {
      while (disposers.length > 0) disposers.pop()()
    },
    listens(name) {
      return listeners.has(name)
    },
  }
}

/** 造一份指向临时目录的配置。 */
function temporaryConfig() {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-api-balance-test-'))
  const cfg = resolveBalanceConfig(undefined, { env: { DSH_HOME: dir }, scriptPath: 'unused.ps1' })
  return { dir, cfg }
}

const silentLog = { info: () => {}, warn: () => {} }

/** 造一条携带用量的事件。 */
function usageEvent(inputTokens, outputTokens) {
  return { type: 'assistant/message', data: { turn: 1, step: 1, usage: { inputTokens, outputTokens } } }
}

test('挂载时先落一份 0 值，窗口不会读到「没有文件」', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    const harness = fakeContext()
    applyUsageTracking(harness.ctx, cfg, silentLog)

    assert.ok(harness.listens('session/event'), '应当监听 session/event')
    assert.ok(existsSync(cfg.usagePath), '挂载后就该有 usage.json')
    const payload = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(payload.total, 0)
    assert.equal(payload.totalText, '0')
    harness.dispose()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('卸载时补一次最终落盘：事件已折叠进文件', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    const harness = fakeContext()
    applyUsageTracking(harness.ctx, cfg, silentLog)

    harness.emit('session/event', null, usageEvent(1200, 350))
    harness.emit('session/event', null, usageEvent(1200, 350)) // 同一步重复上报，不应翻倍
    harness.emit('session/event', null, { type: 'step/start', data: {} }) // 无关事件

    harness.dispose()

    const payload = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(payload.total, 1550)
    assert.equal(payload.input, 1200)
    assert.equal(payload.output, 350)
    assert.equal(payload.totalText, '1.6K')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('长会话期间会按节流周期自行落盘，不必等到卸载', async () => {
  const { dir, cfg } = temporaryConfig()
  try {
    const harness = fakeContext()
    applyUsageTracking(harness.ctx, cfg, silentLog)

    harness.emit('session/event', null, usageEvent(5000, 500))
    // 节流窗口是 1 秒：等它过去，文件应当自己更新到 5.5K（窗口靠轮询这个文件刷新）。
    await new Promise((resolve) => setTimeout(resolve, 1500))

    const payload = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(payload.total, 5500, '节流后的自动落盘没有发生')
    assert.equal(payload.totalText, '5.5K')
    harness.dispose()
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('第二次开机把第一次的当天合计带过来，而不是从零开始', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    const first = fakeContext()
    applyUsageTracking(first.ctx, cfg, silentLog, { now: () => new Date(2026, 8, 14, 10, 0, 0) })
    first.emit('session/event', null, usageEvent(2000, 0))
    first.dispose()

    const afterFirst = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(afterFirst.total, 2000)
    assert.equal(afterFirst.dayKey, '2026-09-14T08:00')

    // 关机再开：这次的监听只看得到 500，但「今天」应当接着上面那个 2000 累计。
    const second = fakeContext()
    applyUsageTracking(second.ctx, cfg, silentLog, { now: () => new Date(2026, 8, 14, 14, 0, 0) })
    second.emit('session/event', null, usageEvent(500, 0))
    second.dispose()

    const afterSecond = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(afterSecond.total, 2500, '今天累计 = 第一次 + 第二次')
    assert.equal(afterSecond.totalText, '2.5K')
    assert.equal(Object.keys(afterSecond.boots).length, 2, '一天里的两次开机各占一条')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('跨过起算时刻后重新从零计，不把昨天带过来', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    const yesterday = fakeContext()
    applyUsageTracking(yesterday.ctx, cfg, silentLog, { now: () => new Date(2026, 8, 14, 22, 0, 0) })
    yesterday.emit('session/event', null, usageEvent(7000, 0))
    yesterday.dispose()
    assert.equal(JSON.parse(readFileSync(cfg.usagePath, 'utf8')).total, 7000)

    // 次日 09:00 已是新的一天（日界 08:00）。
    const today = fakeContext()
    applyUsageTracking(today.ctx, cfg, silentLog, { now: () => new Date(2026, 8, 15, 9, 0, 0) })
    today.emit('session/event', null, usageEvent(120, 0))
    today.dispose()

    const payload = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(payload.total, 120, '新的一天从零开始')
    assert.equal(payload.dayKey, '2026-09-15T08:00')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('升级路径：旧结构文件里今天的数字会被接上，而不是显示成 0', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    // 旧版本留下的文件：没有 dayKey，只有「本次开机」，最后写入时间在「今天」之内。
    writeJsonFile(cfg.usagePath, {
      total: 5000, input: 5000, output: 0, cacheRead: 0, cacheWrite: 0, totalText: '5.0K',
      updatedAt: new Date(2026, 8, 14, 10, 0, 0).toISOString(),
    })

    const harness = fakeContext()
    applyUsageTracking(harness.ctx, cfg, silentLog, { now: () => new Date(2026, 8, 14, 13, 0, 0) })
    harness.emit('session/event', null, usageEvent(200, 0))
    harness.dispose()

    const payload = JSON.parse(readFileSync(cfg.usagePath, 'utf8'))
    assert.equal(payload.dayKey, '2026-09-14T08:00')
    assert.equal(payload.total, 5200, '旧文件里属于今天的 5000 要接上本次的 200')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('writeJsonFile 覆盖已有文件而不是追加，且不留临时文件', () => {
  const { dir, cfg } = temporaryConfig()
  try {
    writeJsonFile(cfg.usagePath, { total: 1 })
    writeJsonFile(cfg.usagePath, { total: 2 })
    assert.deepEqual(JSON.parse(readFileSync(cfg.usagePath, 'utf8')), { total: 2 })
    assert.equal(existsSync(`${cfg.usagePath}.tmp`), false, '原子写的临时文件应当已被改名消费掉')
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
