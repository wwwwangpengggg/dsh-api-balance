/**
 * lib/usage.js 的离线单测：折叠语义（同一步替换、跨步累加）、跨开机的当天累计、日界、
 * 异常输入、以及 token 数的压缩显示。折叠语义必须和 DSH token-meter 一致，否则
 * 「今日消耗」会翻倍或漏计；日界必须和 PowerShell 侧一致，否则两个「今日」对不上。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  createUsageTracker,
  foldUsage,
  formatTokenCount,
  usageDayKey,
  usageDayPayload,
  usageSampleOf,
  usageSnapshot,
} from '../lib/usage.js'

/** 造一份「本次开机」的用量快照。 */
function own(inputTokens, outputTokens) {
  return usageSnapshot(foldAll([messageEvent(1, 1, { inputTokens, outputTokens })]))
}

/** 造一条流式过程中先到的用量样本。 */
function chunkEvent(turn, step, usage) {
  return { type: 'assistant/chunk', data: { turn, step, chunk: { type: 'usage', usage } } }
}

/** 造一条同一步的最终用量样本。 */
function messageEvent(turn, step, usage) {
  return { type: 'assistant/message', data: { turn, step, usage } }
}

/** 连续折叠一串事件。 */
function foldAll(events) {
  let state = createUsageTracker()
  for (const event of events) state = foldUsage(state, event)
  return state
}

test('流式样本与最终样本报同一份用量时只计一次', () => {
  const usage = { inputTokens: 1200, outputTokens: 300 }
  const state = foldAll([chunkEvent(1, 1, usage), messageEvent(1, 1, usage)])
  assert.deepEqual(usageSnapshot(state), { total: 1500, input: 1200, output: 300, cacheRead: 0, cacheWrite: 0 })
})

test('同一步的最终样本替换流式样本，而不是叠加', () => {
  const state = foldAll([
    chunkEvent(1, 1, { inputTokens: 1000, outputTokens: 100 }),
    messageEvent(1, 1, { inputTokens: 1200, outputTokens: 350 }),
  ])
  assert.deepEqual(usageSnapshot(state), { total: 1550, input: 1200, output: 350, cacheRead: 0, cacheWrite: 0 })
})

test('步与步之间是累加关系', () => {
  const state = foldAll([
    messageEvent(1, 1, { inputTokens: 1000, outputTokens: 100 }),
    messageEvent(1, 2, { inputTokens: 2000, outputTokens: 200 }),
    messageEvent(2, 1, { inputTokens: 3000, outputTokens: 300 }),
  ])
  assert.deepEqual(usageSnapshot(state), { total: 6600, input: 6000, output: 600, cacheRead: 0, cacheWrite: 0 })
})

test('缓存读写计入总量，且与输入分开统计', () => {
  const state = foldAll([
    messageEvent(1, 1, { inputTokens: 500, outputTokens: 100, cacheReadTokens: 4000, cacheWriteTokens: 800 }),
  ])
  assert.deepEqual(usageSnapshot(state), { total: 5400, input: 500, output: 100, cacheRead: 4000, cacheWrite: 800 })
})

test('无关事件返回同一个引用，方便调用方跳过落盘', () => {
  const state = createUsageTracker()
  const irrelevant = [
    { type: 'step/start', data: { turn: 1, step: 1 } },
    { type: 'assistant/chunk', data: { turn: 1, step: 1, chunk: { type: 'text-delta', text: 'hi' } } },
    { type: 'assistant/message', data: { turn: 1, step: 1 } },
    { type: 'tool/call', data: { callId: 'x' } },
    null,
    undefined,
    { type: 'assistant/message' },
    { type: 'assistant/chunk', data: {} },
  ]
  for (const event of irrelevant) {
    assert.equal(foldUsage(state, event), state, `事件不应改变累计：${JSON.stringify(event)}`)
  }
})

test('同一步重复上报相同值不产生新状态', () => {
  const usage = { inputTokens: 10, outputTokens: 5 }
  const first = foldAll([messageEvent(1, 1, usage)])
  assert.equal(foldUsage(first, messageEvent(1, 1, usage)), first)
})

test('缺失的缓存字段按 0 计，非法值不会污染累计', () => {
  const state = foldAll([
    messageEvent(1, 1, { inputTokens: Number.NaN, outputTokens: -5, cacheReadTokens: 'many', cacheWriteTokens: undefined }),
    messageEvent(1, 2, { inputTokens: 12.7, outputTokens: 3.2 }),
  ])
  assert.deepEqual(usageSnapshot(state), { total: 15, input: 12, output: 3, cacheRead: 0, cacheWrite: 0 })
})

test('usageSampleOf 只认这两种携带用量的事件', () => {
  assert.deepEqual(usageSampleOf(chunkEvent(2, 3, { inputTokens: 1 })), { turn: 2, step: 3, usage: { inputTokens: 1 } })
  assert.deepEqual(usageSampleOf(messageEvent(2, 3, { inputTokens: 1 })), { turn: 2, step: 3, usage: { inputTokens: 1 } })
  assert.equal(usageSampleOf({ type: 'request/context', data: {} }), undefined)
  assert.equal(usageSampleOf(null), undefined)
})

test('token 数压缩成小窗放得下的短文本', () => {
  assert.equal(formatTokenCount(0), '0')
  assert.equal(formatTokenCount(999), '999')
  assert.equal(formatTokenCount(1000), '1.0K')
  assert.equal(formatTokenCount(141632), '141.6K')
  assert.equal(formatTokenCount(999_949), '999.9K')
  assert.equal(formatTokenCount(1_000_000), '1.00M')
  assert.equal(formatTokenCount(1_250_000), '1.25M')
  assert.equal(formatTokenCount(Number.NaN), '0')
  assert.equal(formatTokenCount(-5), '0')
})

test('落盘载荷带原始数字、排好版的文本与当天分条记录', () => {
  const state = foldAll([messageEvent(1, 1, { inputTokens: 138_220, outputTokens: 3412 })])
  const payload = usageDayPayload(null, usageSnapshot(state), '2026-01-02T08:00', 'boot-1', new Date('2026-01-02T03:04:05.000Z'))
  assert.equal(payload.total, 141_632)
  assert.equal(payload.totalText, '141.6K')
  assert.equal(payload.updatedAt, '2026-01-02T03:04:05.000Z')
  assert.equal(payload.dayKey, '2026-01-02T08:00')
  assert.equal(payload.input, 138_220, '分桶随总数一起落盘，便于排查重复计数')
  assert.equal(payload.output, 3412)
  assert.deepEqual(JSON.parse(JSON.stringify(payload)), payload, '载荷必须可无损 JSON 序列化')
})

test('「哪一天」的键必须与 PowerShell 侧的 Get-SpendingDayKey 一致', () => {
  // 下面这批期望值和 assets/balance-window.ps1 里 -LogicTest 的同名用例一一对应。
  // 「今日 token」和「今日消费」共用同一个日界，而日界在 JS 与 PowerShell 各实现一遍，
  // 只有两边都写死同一批值才守得住。
  assert.equal(usageDayKey(new Date(2026, 8, 14, 7, 59), 8), '2026-09-13T08:00', '07:59 仍算前一天')
  assert.equal(usageDayKey(new Date(2026, 8, 14, 8, 0), 8), '2026-09-14T08:00', '08:00 整开始新的一天')
  assert.equal(usageDayKey(new Date(2026, 8, 14, 12, 0), 8), '2026-09-14T08:00', '当天中午仍是同一天')
  assert.equal(usageDayKey(new Date(2026, 8, 15, 2, 0), 8), '2026-09-14T08:00', '次日 02:00 仍算前一天')
  assert.equal(usageDayKey(new Date(2026, 8, 15, 8, 0), 8), '2026-09-15T08:00', '次日 08:00 才换天')
  assert.equal(usageDayKey(new Date(2026, 8, 14, 0, 0), 0), '2026-09-14T00:00', '起点填 0 就是自然日')
  assert.equal(usageDayKey(new Date(2026, 8, 14, 23, 59), 0), '2026-09-14T00:00', '起点 0 点时 23:59 同一天')
  assert.equal(usageDayKey(new Date(2026, 8, 14, 19, 0), 20), '2026-09-13T20:00', '起点 20 点时次日 19:00 同一天')
})

test('跨多次开机累加：后一次开机把前面几次的合计带上', () => {
  const dayKey = '2026-09-14T08:00'
  const at = new Date('2026-09-14T09:00:00.000Z')
  const boot1 = usageDayPayload(null, own(1000, 500), dayKey, 'boot-1', at)
  assert.equal(boot1.total, 1500)

  // 关机再开机：这一次只看得到自己的 300，但当天合计要把上一次带上。
  const boot2 = usageDayPayload(boot1, own(300, 0), dayKey, 'boot-2', at)
  assert.equal(boot2.total, 1800, '今天累计 = 上次开机 + 本次开机')
  assert.equal(boot2.totalText, '1.8K')
  assert.deepEqual(Object.keys(boot2.boots).sort(), ['boot-1', 'boot-2'])
})

test('同一次开机反复落盘是覆盖，不是重复叠加', () => {
  const dayKey = '2026-09-14T08:00'
  const at = new Date('2026-09-14T09:00:00.000Z')
  const first = usageDayPayload(null, own(1000, 0), dayKey, 'boot-1', at)
  const again = usageDayPayload(first, own(1500, 0), dayKey, 'boot-1', at)
  assert.equal(again.total, 1500, '同一个 bootKey 只更新自己那一条')
})

test('跨天丢掉整份记录重开，与「今日消费」的日界一致', () => {
  const at = new Date('2026-09-15T09:00:00.000Z')
  const yesterday = usageDayPayload(null, own(9000, 0), '2026-09-14T08:00', 'boot-1', at)
  assert.equal(yesterday.total, 9000)
  const today = usageDayPayload(yesterday, own(200, 0), '2026-09-15T08:00', 'boot-2', at)
  assert.equal(today.total, 200, '新的一天从零开始，不带昨天那 9000')
  assert.deepEqual(Object.keys(today.boots), ['boot-2'])
})

test('同时开着的另一个实例的数字不会被抹掉', () => {
  const dayKey = '2026-09-14T08:00'
  const at = new Date('2026-09-14T09:00:00.000Z')
  const desktop = usageDayPayload(null, own(1000, 0), dayKey, 'desktop', at)
  // web profile 那边读到的文件里已经有 desktop 那一条，它只更新自己那条。
  const both = usageDayPayload(desktop, own(400, 0), dayKey, 'web', at)
  assert.equal(both.total, 1400)
  // desktop 再落一次盘：它更新自己的 1000→1200，web 的 400 必须留着。
  const after = usageDayPayload(both, own(1200, 0), dayKey, 'desktop', at)
  assert.equal(after.total, 1600)
})

test('文件坏掉或格式不对时当「没有历史」，而不是抛异常', () => {
  const at = new Date('2026-09-14T09:00:00.000Z')
  const broken = [null, 'nope', 42, { dayKey: '2026-09-14T08:00' }, { dayKey: '2026-09-14T08:00', boots: 3 }]
  for (const previous of broken) {
    const payload = usageDayPayload(previous, own(70, 0), '2026-09-14T08:00', 'boot-1', at)
    assert.equal(payload.total, 70, `${JSON.stringify(previous)} 应当被当成没有历史`)
  }
})
