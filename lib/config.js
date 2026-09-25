/**
 * dsh-api-balance —— 配置解析（纯函数，便于离线单测）。
 *
 * 插件行在 cordis.patch.yml 里给 config；这里把它规范化成一份完整、已夹紧取值的
 * 配置对象，并把「脚本路径 / 凭据文件 / 状态文件」三个路径解析出来。
 * 所有环境相关的输入都通过参数注入（env、scriptPath），因此测试不需要真实环境。
 *
 * @module dsh-api-balance/config
 */
import { join, resolve } from 'node:path'

/** 允许的窗口停靠角落。 */
export const CORNERS = ['top-right', 'top-left', 'bottom-right', 'bottom-left']

/** 小窗自带的配色主题。用户在右键「外观」里选过的会记进 state.json，优先级高于这里的默认值。 */
export const THEMES = ['navy', 'graphite', 'teal', 'plum', 'sunset', 'light', 'paper']

/**
 * 背景图蒙版的浓度档位（同样可被右键菜单的选择覆盖）。
 * 这是「图片清不清楚」与「数字看不看得清」之间的旋钮，所以是可调的而不是写死的。
 */
export const SCRIMS = ['none', 'light', 'medium', 'strong', 'heavy']

/** 刷新间隔的上下界（秒）：下界避免把接口刷爆，上界避免用户填出无意义的巨大值。 */
export const MIN_REFRESH_SECONDS = 10
export const MAX_REFRESH_SECONDS = 3600

/** 默认配置：与 cordis.patch.yml 中示例保持一致。 */
export const DEFAULTS = {
  enabled: true,
  refreshSeconds: 60,
  /** 「今日消费」的一天从几点开始（本地时间，0-23）：默认早 8 点，到次日 8 点算新的一天。 */
  dayStartHour: 8,
  /** 额外的法定节假日（逗号分隔的 yyyy-MM-dd，按北京时间）。脚本内置了已收录年份的表。 */
  holidays: '',
  corner: 'top-right',
  theme: 'navy',
  scrim: 'medium',
  currency: '',
  baseUrl: 'https://api.deepseek.com',
  credentialEnv: 'DEEPSEEK_API_KEY',
  credentialFile: '',
  stateDir: '',
  instanceName: 'DshApiBalanceWindow',
}

/**
 * 解析 DSH 主目录。
 * @param env - 环境变量表（通常是 process.env）。
 * @returns DSH 主目录的绝对路径。
 */
export function resolveDshHome(env = process.env) {
  const fromEnv = env.DSH_HOME
  if (typeof fromEnv === 'string' && fromEnv.trim() !== '') return resolve(fromEnv.trim())
  const home = env.USERPROFILE ?? env.HOME
  if (typeof home !== 'string' || home.trim() === '') return resolve('.dsh')
  return join(resolve(home.trim()), '.dsh')
}

/**
 * 取整并夹紧一个数值配置项。
 * @param value - 原始值。
 * @param fallback - 非法时的兜底值。
 * @param min - 下界。
 * @param max - 上界。
 * @returns 夹紧后的整数。
 */
function clampInt(value, fallback, min, max) {
  const parsed = typeof value === 'number' ? value : Number.parseInt(String(value ?? ''), 10)
  if (!Number.isFinite(parsed)) return fallback
  return Math.min(max, Math.max(min, Math.trunc(parsed)))
}

/**
 * 取一个非空字符串配置项。
 * @param value - 原始值。
 * @param fallback - 空白时的兜底值。
 * @returns 去空白后的字符串。
 */
function pickString(value, fallback) {
  if (typeof value !== 'string') return fallback
  const trimmed = value.trim()
  return trimmed === '' ? fallback : trimmed
}

/**
 * 取节假日补丁：既接受 `'2027-01-01,2027-01-02'`，也接受 YAML 列表写法。
 * 非字符串又非数组时回落到空（此时脚本只用内置表）。
 * @param value - 原始值。
 * @returns 逗号分隔的日期串，或空串。
 */
function pickHolidays(value) {
  if (Array.isArray(value)) {
    return value.map((item) => String(item).trim()).filter((item) => item !== '').join(',')
  }
  return pickString(value, '')
}

/**
 * 规范化插件配置。
 * @param raw - cordis.patch.yml 里写下的 config（可能为 undefined）。
 * @param options - 依赖注入：env、脚本路径。
 * @returns 一份完整配置，含 scriptPath / credentialFile / statePath / parentPid。
 */
export function resolveBalanceConfig(raw, options = {}) {
  const source = raw !== null && typeof raw === 'object' ? raw : {}
  const env = options.env ?? process.env
  const scriptPath = options.scriptPath ?? join(resolve('.dsh-api-balance'), 'assets', 'balance-window.ps1')
  const parentPid = options.parentPid ?? process.pid
  const dshHome = resolveDshHome(env)

  const stateDir = pickString(source.stateDir, join(dshHome, 'plugins', 'dsh-api-balance'))
  const defaultCredentialFile = join(dshHome, '.credentials.yaml')
  // 用户自己放背景图片的文件夹：挨着状态文件，方便一起备份/搬迁。
  const backgroundsDir = pickString(source.backgroundsDir, join(stateDir, 'backgrounds'))

  const corner = pickString(source.corner, DEFAULTS.corner)
  const theme = pickString(source.theme, DEFAULTS.theme)
  const scrim = pickString(source.scrim, DEFAULTS.scrim)

  return {
    enabled: source.enabled !== false,
    refreshSeconds: clampInt(source.refreshSeconds, DEFAULTS.refreshSeconds, MIN_REFRESH_SECONDS, MAX_REFRESH_SECONDS),
    dayStartHour: clampInt(source.dayStartHour, DEFAULTS.dayStartHour, 0, 23),
    holidays: pickHolidays(source.holidays),
    corner: CORNERS.includes(corner) ? corner : DEFAULTS.corner,
    theme: THEMES.includes(theme) ? theme : DEFAULTS.theme,
    scrim: SCRIMS.includes(scrim) ? scrim : DEFAULTS.scrim,
    currency: pickString(source.currency, DEFAULTS.currency),
    baseUrl: pickString(source.baseUrl, DEFAULTS.baseUrl),
    credentialEnv: pickString(source.credentialEnv, DEFAULTS.credentialEnv),
    credentialFile: pickString(source.credentialFile, defaultCredentialFile),
    statePath: join(resolve(stateDir), 'state.json'),
    usagePath: join(resolve(stateDir), 'usage.json'),
    spendPath: join(resolve(stateDir), 'spending.json'),
    backgroundsDir: resolve(backgroundsDir),
    instanceName: pickString(source.instanceName, DEFAULTS.instanceName),
    powershell: pickString(source.powershell, ''),
    parentPid,
    scriptPath: resolve(scriptPath),
  }
}

/**
 * 解析要调用的 Windows PowerShell。
 *
 * 固定用系统自带的 5.1：WinForms 在 5.1 下默认 STA 且不依赖额外安装，而 PowerShell 7
 * 默认 MTA，WinForms 窗口会不稳定。
 * @param cfg - 已规范化的配置。
 * @param env - 环境变量表。
 * @returns powershell.exe 的路径（找不到系统自带的则退回 PATH 上的名字）。
 */
export function resolvePowerShell(cfg, env = process.env) {
  if (cfg.powershell !== '') return cfg.powershell
  const sysRoot = pickString(env.SystemRoot, 'C:\\Windows')
  return join(sysRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
}

/**
 * 构造传给 balance-window.ps1 的参数表。
 *
 * 顺序参数一律「开关 + 取值」成对出现；-Currency 为空时整体省略，让脚本用接口返回的
 * 第一种货币。API Key 绝不进入命令行，脚本自己去读环境变量或凭据文件。
 *
 * StatePath、SpendPath 与 UsagePath 的归属是分开的：窗口只写 state.json（窗口位置）与
 * spending.json（今日消费的记账），宿主插件只写 usage.json（开机以来的 token 用量），
 * 两个进程不碰同一个文件。
 * @param cfg - 已规范化的配置。
 * @returns powershell.exe 的参数数组。
 */
export function buildWindowArgs(cfg) {
  const args = [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', cfg.scriptPath,
    '-BaseUrl', cfg.baseUrl,
    '-CredentialEnv', cfg.credentialEnv,
    '-CredentialFile', cfg.credentialFile,
    '-RefreshSeconds', String(cfg.refreshSeconds),
    '-Corner', cfg.corner,
    '-Theme', cfg.theme,
    '-Scrim', cfg.scrim,
    '-StatePath', cfg.statePath,
    '-UsagePath', cfg.usagePath,
    '-SpendPath', cfg.spendPath,
    '-DayStartHour', String(cfg.dayStartHour),
    '-BackgroundDir', cfg.backgroundsDir,
    '-InstanceName', cfg.instanceName,
    '-ParentPid', String(cfg.parentPid),
  ]
  if (cfg.currency !== '') args.push('-Currency', cfg.currency)
  // 节假日补丁同上：没配就整体省略，脚本用内置的法定节假日表。
  if (cfg.holidays !== '') args.push('-Holidays', cfg.holidays)
  return args
}
