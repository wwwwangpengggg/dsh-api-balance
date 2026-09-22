/**
 * dsh-api-balance —— 「今天消耗了多少 token」的折叠、跨开机累计与呈现（纯函数，便于离线单测）。
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
 * 折叠出来的只是「本次开机」的量：监听是在插件 apply 时挂上的，看不到更早的事件。
 * 而用户一天里会反复开关 DSH，所以对外要的是**当天合计**——由 `usageDayPayload` 把
 * 本次开机的量并进文件里已有的分条记录（`boots`）里，跨开机累加；日界（哪一天、从几点
 * 算起）与「今日消费」完全一致，见 `usageDayKey`。
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
 * 「哪一天」的键：形如 `2026-09-14T08:00`，含义是「这一天从 08:00 开始」。
 *
 * **必须与 PowerShell 侧的 `Get-SpendingDayKey` 完全一致**：「今日 token」与「今日消费」
 * 共用同一个日界（`dayStartHour`，默认早 8 点起算、24 小时后换新的一天）。两边各实现一遍
 * 是不得已（宿主是 JS、小窗是 PowerShell），守卫办法是两边的测试都写死同一批边界期望值
 * ——08:00 整换天、07:59 仍算前一天、起点填 0 就是自然日……改一边就会立刻变红。
 * @param date - 当前时刻（本地时间）。
 * @param startHour - 一天的起点，0-23。
 * @returns 形如 "2026-09-14T08:00" 的键。
 */
export function usageDayKey(date = new Date(), startHour = 8) {
  const hour = Number.isInteger(startHour) && startHour >= 0 && startHour <= 23 ? startHour : 8
  const start = new Date(date.getFullYear(), date.getMonth(), date.getDate(), hour, 0, 0, 0)
  if (date.getTime() < start.getTime()) start.setDate(start.getDate() - 1)
  const pad = (value) => String(value).padStart(2, '0')
  return `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}`
    + `T${pad(start.getHours())}:${pad(start.getMinutes())}`
}

/**
 * 把「本次开机的用量」并进当天合计，得到要落盘的那份载荷。
 *
 * 为什么要分条记（`boots`）而不是简单地把旧 total 加一遍：一天里可能**同时**开着多个实例
 * （桌面版与 `dsh web` 各占一个 profile），而它们都往同一个 usage.json 写。按「哪一次开机」
 * 分条之后，每次开机只更新自己那一条，并发写就不会把别人的数字整体抹掉——最多是某一次
 * 开机的最新数字晚一拍才体现出来。
 *
 * `dayKey` 变了（跨天）或文件不可用，就丢掉整份记录重开，与「今日消费」的日界一致。
 * @param previous - 上次落盘的载荷（读不到就传 null）。
 * @param own - 本次开机的用量快照（`usageSnapshot` 的结果）。
 * @param dayKey - 当前这一天的键（`usageDayKey`）。
 * @param bootKey - 本次开机的标识，同一次开机内必须稳定。
 * @param now - 本次写入时间。
 * @returns 可 JSON 序列化的载荷（`total` / `totalText` 是窗口唯一要读的字段）。
 */
export function usageDayPayload(previous, own, dayKey, bootKey, now = new Date()) {
  const carry = previous !== null && typeof previous === 'object'
    && previous.dayKey === dayKey
    && previous.boots !== null && typeof previous.boots === 'object'
    ? previous.boots
    : {}

  const boots = { ...carry, [bootKey]: { ...own, updatedAt: now.toISOString() } }

  let total = 0
  let input = 0
  let output = 0
  let cacheRead = 0
  let cacheWrite = 0
  for (const entry of Object.values(boots)) {
    if (entry === null || typeof entry !== 'object') continue
    total += toCount(entry.total)
    input += toCount(entry.input)
    output += toCount(entry.output)
    cacheRead += toCount(entry.cacheRead)
    cacheWrite += toCount(entry.cacheWrite)
  }

  return {
    dayKey,
    total,
    input,
    output,
    cacheRead,
    cacheWrite,
    totalText: formatTokenCount(total),
    boots,
    updatedAt: now.toISOString(),
  }
}
