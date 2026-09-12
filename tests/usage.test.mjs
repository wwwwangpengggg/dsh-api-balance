/**
 * lib/usage.js 的离线单测：折叠语义（同一步替换、跨步累加）、异常输入、以及 token 数
 * 的压缩显示。折叠语义必须和 DSH token-meter 一致，否则「本次开机消耗」会翻倍或漏计。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  createUsageTracker,
  foldUsage,
  formatTokenCount,
  usagePayload,
  usageSampleOf,
  usageSnapshot,
} from '../lib/usage.js'

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

test('落盘载荷同时带原始数字与排好版的文本', () => {
  const state = foldAll([messageEvent(1, 1, { inputTokens: 138_220, outputTokens: 3412 })])
  const payload = usagePayload(state, new Date('2026-01-02T03:04:05.000Z'))
  assert.equal(payload.total, 141_632)
  assert.equal(payload.totalText, '141.6K')
  assert.equal(payload.updatedAt, '2026-01-02T03:04:05.000Z')
  assert.equal(payload.input, 138_220, '分桶随总数一起落盘，便于排查重复计数')
  assert.equal(payload.output, 3412)
  assert.deepEqual(JSON.parse(JSON.stringify(payload)), payload, '载荷必须可无损 JSON 序列化')
})
