/**
 * dsh-api-balance —— 「本次开机消耗了多少 token」的折叠与呈现（纯函数，便于离线单测）。
 *
 * 数据来自宿主事件 `session/event`：每条提交的会话事件都会经过它，其中两种携带
 * provider 上报的用量：
 *
 *   - `assistant/chunk`（chunk.type === 'usage'）：流式过程中先到的样本；
 *   - `assistant/message`（带 usage）：同一步的最终样本。
 *
 * 一步会同时产生这两个样本，直接相加就会重复计数，所以这里照搬 DSH token-meter 的
 * 折叠语义（见 @deepseek-ai/dsh-token-meter 的 usage-projection）：同 turn/step 的
 * 新样本**替换**旧样本，只有 turn/step 推进时才累加。
 *
 * 因为监听是在插件 apply 时挂上的，只会看到本次开机之后追加的事件——「本次开机」
 * 这个口径是订阅时机自带的，不需要额外记录基线。
 *
 * @module dsh-api-balance/usage
 */

/** 四个互不重叠的用量桶（与 DSH token-meter 的语义一致：inputTokens 是不含缓存的输入）。 */
const ZERO_BUCKETS = Object.freeze({
  uncachedInputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
})

/**
 * 把一条事件里的 provider 用量换算成四个桶。
 * @param usage - provider 上报的用量记录。
 * @returns 规范化后的桶。
 */
function bucketsFrom(usage) {
  return {
    uncachedInputTokens: toCount(usage.inputTokens),
    outputTokens: toCount(usage.outputTokens),
    cacheReadTokens: toCount(usage.cacheReadTokens),
    cacheWriteTokens: toCount(usage.cacheWriteTokens),
  }
}

/**
 * 取一个非负整数计数：字段缺失或非法都当 0，避免把 NaN 带进累计值。
 * @param value - 原始字段。
 * @returns 非负整数。
 */
function toCount(value) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) return 0
  return Math.floor(value)
}

/** 两个桶是否完全一致。 */
function bucketsEqual(left, right) {
  return left.uncachedInputTokens === right.uncachedInputTokens
    && left.outputTokens === right.outputTokens
    && left.cacheReadTokens === right.cacheReadTokens
    && left.cacheWriteTokens === right.cacheWriteTokens
}

/** 先减去被替换样本、再加上新样本。 */
function addReplacing(totals, previous, next) {
  return {
    uncachedInputTokens: totals.uncachedInputTokens - (previous?.uncachedInputTokens ?? 0) + next.uncachedInputTokens,
    outputTokens: totals.outputTokens - (previous?.outputTokens ?? 0) + next.outputTokens,
    cacheReadTokens: totals.cacheReadTokens - (previous?.cacheReadTokens ?? 0) + next.cacheReadTokens,
    cacheWriteTokens: totals.cacheWriteTokens - (previous?.cacheWriteTokens ?? 0) + next.cacheWriteTokens,
  }
}

/**
 * 从一个会话事件里取出「turn/step + 用量」，取不到就返回 undefined。
 *
 * 只读叶子字段：事件是 DSH 的活对象，不复制、不序列化。
 * @param event - session/event 的事件对象。
 * @returns { turn, step, usage } 或 undefined。
 */
export function usageSampleOf(event) {
  if (event === null || typeof event !== 'object') return undefined
  const data = event.data
  if (data === null || typeof data !== 'object') return undefined

  if (event.type === 'assistant/chunk') {
    const chunk = data.chunk
    if (chunk !== null && typeof chunk === 'object' && chunk.type === 'usage' && chunk.usage !== undefined) {
      return { turn: toCount(data.turn), step: toCount(data.step), usage: chunk.usage }
    }
    return undefined
  }
  if (event.type === 'assistant/message' && data.usage !== undefined) {
    return { turn: toCount(data.turn), step: toCount(data.step), usage: data.usage }
  }
  return undefined
}

/**
 * 建一份空的用量累计器。
 * @returns 初始状态。
 */
export function createUsageTracker() {
  return { totals: { ...ZERO_BUCKETS }, last: null }
}

/**
 * 折叠一条会话事件。
 *
 * 事件与本次累计无关时**返回同一个引用**，调用方用 `next === previous` 就能判断
 * 「没有变化」，从而跳过落盘。
 * @param state - 当前累计状态。
 * @param event - session/event 的事件对象。
 * @returns 新状态，或原状态（无变化时）。
 */
export function foldUsage(state, event) {
  const sample = usageSampleOf(event)
  if (sample === undefined) return state

  const buckets = bucketsFrom(sample.usage)
  const previous = state.last !== null && state.last.turn === sample.turn && state.last.step === sample.step
    ? state.last.buckets
    : undefined

  // 同一步重复上报同一个值：事件很多，这里挡住无意义的重复落盘。
  if (previous !== undefined && bucketsEqual(previous, buckets)) return state

  return {
    totals: addReplacing(state.totals, previous, buckets),
    last: { turn: sample.turn, step: sample.step, buckets },
  }
}

/**
 * 把累计状态拍平成一份纯数字快照。
 * @param state - 累计状态。
 * @returns 四个桶与它们的总和。
 */
export function usageSnapshot(state) {
  const t = state.totals
  const input = toCount(t.uncachedInputTokens)
  const output = toCount(t.outputTokens)
  const cacheRead = toCount(t.cacheReadTokens)
  const cacheWrite = toCount(t.cacheWriteTokens)
  return {
    total: input + output + cacheRead + cacheWrite,
    input,
    output,
    cacheRead,
    cacheWrite,
  }
}

/**
 * 把 token 数压成小窗放得下的短文本。
 *
 * 1000 以下给整数；不足一个数量级就用 K；逼近 1000K 时提前切到 M，
 * 免得出现 "1000.0K" 这种读起来别扭的值。
 * @param value - token 数。
 * @returns 形如 "875" / "141.6K" / "1.25M" 的短文本。
 */
export function formatTokenCount(value) {
  const count = Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0
  if (count < 1000) return String(count)
  if (count < 999_950) return `${(count / 1000).toFixed(1)}K`
  return `${(count / 1_000_000).toFixed(2)}M`
}

/**
 * 生成写进 usage.json 的载荷。
 *
 * 除了原始数字，还带上**已经排好版的**总数文本：窗口只管显示，不在 PowerShell 里再
 * 实现一遍数字压缩（那部分逻辑留在可单测的 JS 里）。四个分桶一并落盘，便于排查
 * 「计数是不是重复了」这类问题——小窗只显示总数，分桶是留给排查用的。
 * @param state - 累计状态。
 * @param now - 本次写入时间。
 * @returns 可 JSON 序列化的载荷。
 */
export function usagePayload(state, now = new Date()) {
  const snapshot = usageSnapshot(state)
  return {
    ...snapshot,
    totalText: formatTokenCount(snapshot.total),
    updatedAt: now.toISOString(),
  }
}
