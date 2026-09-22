<#
.SYNOPSIS
  dsh-api-balance 的桌面小窗：一个无边框、置顶的迷你窗口，显示 DeepSeek API 账户余额。

.DESCRIPTION
  由 dsh-api-balance 宿主插件在 DSH 启动时拉起。本脚本自己读取 API Key（进程环境变量
  或 $DSH_HOME/.credentials.yaml），周期调用 GET {BaseUrl}/user/balance，并把结果画在
  小窗上；不经过 DSH 的 IPC，密钥也不出现在命令行里。

  小窗有三页，点一下金额所在的区域就往后翻一页（到最后一页绕回第一页；不做滑动手势：
  卡片本身要靠拖动移动位置，两者会抢同一个手势）：
    - 第 1 页：余额，以及今日累计消耗的 token（跨多次开关机累加）；
    - 第 2 页：今日消费的金额；
    - 第 3 页：现在是高峰时段还是优惠时段，以及还有多久切换。
  数据来源彼此独立：
    - 余额：本脚本自己调 DeepSeek 接口取；
    - 今日累计消耗的 token：宿主插件写进 UsagePath 的那份 JSON，本脚本每 2 秒读一次；
    - 今日消费：把每次取到的余额与上一次相减累计出来，写进 SpendPath。这里的「一天」默认
      从早 8 点算起、到次日 8 点结束（-DayStartHour 可改），不是自然日。它是估算值：只能
      统计小窗运行期间观察到的减少量，接口不提供账单明细，因此与官网的当日消费不相等。
  三个文件归属分明：StatePath 与 SpendPath 只由本脚本写，UsagePath 只由插件写。

  窗口行为：
    - 左键拖动移动窗口，位置写回 StatePath，下次启动回到原处；
    - × 不是退出，而是收进托盘；托盘图标双击可重新显示，右键菜单可刷新或真正退出；
    - 双击或右键菜单可立即刷新；右键菜单还能改刷新间隔、取消置顶、关闭；
    - 看门狗每隔几秒检查 ParentPid，DSH 一退出（含被强杀）窗口连同托盘图标一起消失；
    - 命名互斥量保证同一时刻只有一个余额小窗。

  诊断模式：
    - -Probe 只抓一次余额并打印 JSON，不创建任何窗口；
    - -LogicTest 只跑纯函数（今日消费的累计口径、计费时段判定与金额格式化），不联网、不建窗口；
    - -NowOverride '2026-09-14 02:00' 把「现在」钉住，用来在任意时刻看高峰/优惠两种渲染；
    - -StartPage 2 直接开在第 3 页，方便截图与逐页验证（省得靠连点，那有时序）。
    - -SelfTest 把窗口跑起来、模拟点一次 ×、断言「只是隐藏、进程与托盘还在」，然后退出。

.NOTES
  本文件必须以 UTF-8 with BOM 保存：Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI
  解码，中文会变成乱码。tests/window-script.test.mjs 会断言 BOM 存在。
#>
[CmdletBinding()]
param(
    [string] $BaseUrl        = 'https://api.deepseek.com',
    [string] $CredentialEnv  = 'DEEPSEEK_API_KEY',
    [string] $CredentialFile = '',
    [int]    $RefreshSeconds = 60,
    [int]    $DayStartHour   = 8,
    [string] $NowOverride    = '',
    [int]    $StartPage      = 0,
    [string] $Currency       = '',
    [string] $Corner         = 'top-right',
    [int]    $ParentPid      = 0,
    [string] $StatePath      = '',
    [string] $UsagePath      = '',
    [string] $SpendPath      = '',
    [string] $BackgroundDir  = '',
    [string] $Theme          = 'navy',
    [string] $Scrim          = 'medium',
    [string] $InstanceName   = 'DshApiBalanceWindow',
    [switch] $Probe,
    [switch] $SelfTest,
    [switch] $LogicTest
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # 老系统上枚举不存在时忽略：Invoke-RestMethod 会用系统默认协议。
}

# ---------------------------------------------------------------------------
# DPI 感知
#
# powershell.exe 默认是「DPI 不感知」的（GetProcessDpiAwareness 返回 0）。在 125% 缩放下
# Windows 会把整个窗口的位图拉伸 1.25 倍，字就是这么糊掉的。必须在创建任何窗口**之前**
# 声明感知，之后窗口就按物理像素渲染，边缘是原生清晰的。
#
# 代价：写死的像素坐标不再被系统代劳，得自己乘以缩放系数（见 Px）。字体用 point 为单位，
# GDI+ 会自己按 DPI 换算，所以字号不用动——这也是为什么缩放后字形比例仍然正确。
# ---------------------------------------------------------------------------

$script:DpiScale = 1.0

try {
    Add-Type -Namespace DshNative -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern int GetDpiForSystem();
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
[DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);
[DllImport("user32.dll")] public static extern bool ReleaseDC(IntPtr hWnd, IntPtr hDC);
'@
    [void][DshNative.Dpi]::SetProcessDPIAware()

    $systemDpi = 0
    try { $systemDpi = [DshNative.Dpi]::GetDpiForSystem() } catch { $systemDpi = 0 }
    if ($systemDpi -le 0) {
        # Win10 1607 之前没有 GetDpiForSystem，退回 GDI 的 LOGPIXELSX。
        $dc = [DshNative.Dpi]::GetDC([IntPtr]::Zero)
        $systemDpi = [DshNative.Dpi]::GetDeviceCaps($dc, 88)
        [void][DshNative.Dpi]::ReleaseDC([IntPtr]::Zero, $dc)
    }
    if ($systemDpi -gt 0) { $script:DpiScale = $systemDpi / 96.0 }
} catch {
    # 声明失败就按 100% 算：退化成「系统拉伸」的老样子（糊，但能用）。
    $script:DpiScale = 1.0
}

# 逻辑像素 → 物理像素。布局里所有写死的坐标都要过这里。
function Px {
    param([double] $Value)
    return [int] [Math]::Round($Value * $script:DpiScale)
}

# ---------------------------------------------------------------------------
# 取余额：纯逻辑部分，window 与 probe 两种模式共用
# ---------------------------------------------------------------------------

function ConvertTo-Decimal {
    param([object] $Value)
    if ($null -eq $Value) { return [decimal] 0 }
    $text = [string] $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return [decimal] 0 }
    $parsed = [decimal] 0
    $styles = [System.Globalization.NumberStyles]::Any
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ([decimal]::TryParse($text, $styles, $culture, [ref] $parsed)) { return $parsed }
    return [decimal] 0
}

function Get-ApiKey {
    param([string] $EnvName, [string] $File)

    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv.Trim() }

    if ([string]::IsNullOrWhiteSpace($File)) { return $null }
    if (-not (Test-Path -LiteralPath $File)) { return $null }

    foreach ($line in [System.IO.File]::ReadAllLines($File)) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $colon = $trimmed.IndexOf(':')
        if ($colon -lt 1) { continue }
        $name = $trimmed.Substring(0, $colon).Trim()
        if ($name -ne $EnvName) { continue }
        $raw = $trimmed.Substring($colon + 1).Trim()
        $raw = $raw.Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw }
    }
    return $null
}

function Get-BalanceSnapshot {
    param([string] $Key, [string] $Base, [string] $Preferred)

    $uri = $Base.TrimEnd('/') + '/user/balance'
    $headers = @{ Authorization = "Bearer $Key"; Accept = 'application/json' }
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 12

    $infos = @()
    if ($null -ne $response.balance_infos) { $infos = @($response.balance_infos) }
    if ($infos.Count -eq 0) { throw '接口未返回 balance_infos' }

    $picked = $infos[0]
    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        foreach ($info in $infos) {
            if ([string] $info.currency -eq $Preferred) { $picked = $info; break }
        }
    }

    return [pscustomobject] @{
        Ok          = $true
        Available   = [bool] $response.is_available
        Currency    = [string] $picked.currency
        Total       = ConvertTo-Decimal $picked.total_balance
        Granted     = ConvertTo-Decimal $picked.granted_balance
        ToppedUp    = ConvertTo-Decimal $picked.topped_up_balance
        FetchedAt   = (Get-Date)
    }
}

function Get-CurrencySymbol {
    param([string] $Code)
    switch ($Code) {
        'CNY' { return '¥' }
        'USD' { return '$' }
        default { return '' }
    }
}

function Format-Money {
    param([decimal] $Amount, [string] $Code)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    return (Get-CurrencySymbol $Code) + $Amount.ToString('N2', $culture)
}

# ---------------------------------------------------------------------------
# 今日消费
#
# DeepSeek 的余额接口只返回「还剩多少钱」，没有任何账单明细，所以今日消费只能用余额的
# 减少量倒推：每取到一次余额就和上一次比，少了多少就记多少。
#
# 口径上有两点必须说清楚（README 里也写了）：
#   - 充值（余额变多）不计入、也不抵扣，只把基准线抬高；
#   - 换天时计数归零、但基准线保留（「天」的边界默认早 8 点，见 Get-SpendingDayKey），
#     所以 DSH 关着那段时间的减少量会记到它第一次被观察到的那一天；
#   - 只有小窗看着的时候才数得到：它没运行那段时间的消费无从得知，接口不提供任何历史。
# 也就是说这是个估算值，页面上因此标注了「按余额减少量估算 · 充值不计入」。
#
# 金额一律以不变文化的字符串存盘（[decimal] + InvariantCulture）：换台机器、换个区域
# 设置，小数点就不会变成逗号而读不回来。
# ---------------------------------------------------------------------------

# 「一天」从几点开始由用户定（默认早 8 点），所以「今天」不是自然日，而是最近一次
# 「8:00」到次日「8:00」之间的那 24 小时——8:00 之前算作前一天。
#
# 返回值既当「这一天的标记」又当「起算时刻」：它一变就说明跨天了，累计从零重开；
# 页面上也把它显示出来（「08:00 起算」），免得用户把它当成自然日。
function Get-SpendingDayKey {
    param([datetime] $Now, [int] $StartHour)
    $start = $Now.Date.AddHours($StartHour)
    if ($Now -lt $start) { $start = $start.AddDays(-1) }
    return $start.ToString('yyyy-MM-ddTHH:mm')
}

function New-SpendingState {
    param([decimal] $Balance, [string] $Currency, [string] $DayKey)
    return [pscustomobject] @{
        dayKey      = $DayKey
        currency    = $Currency
        spent       = [decimal] 0
        lastBalance = $Balance
    }
}

# 纯函数：喂进「上一份记录 + 这次取到的余额」，吐出新的记录。
# 单独拆出来是为了能被 -LogicTest 直接跑——IO 与判定分开，判定才测得动。
function Add-BalanceSample {
    param($State, [decimal] $Balance, [string] $Currency, [string] $DayKey)

    if ($null -eq $State) { return (New-SpendingState -Balance $Balance -Currency $Currency -DayKey $DayKey) }

    # 换币种：不同币种的金额不可比，整份重开（基准线也跟着换）。
    if ([string] $State.currency -ne $Currency) {
        return (New-SpendingState -Balance $Balance -Currency $Currency -DayKey $DayKey)
    }

    $spent = [decimal] $State.spent
    # 换天：计数归零，但**基准线要留着**。
    #
    # 小窗不是 7x24 开着的，DSH 关着的那段时间余额照样在掉。如果连基准线一起清掉，那段
    # 花费就被永久丢掉了——用户明明花掉二十多块，卡上只有几毛（真发生过）。保留基准线意味着
    # 这段减少量会记在「它第一次被观察到的那一天」；在只有余额接口、没有账单明细的前提下，
    # 这是唯一不丢数的做法。
    if ([string] $State.dayKey -ne $DayKey) { $spent = [decimal] 0 }

    $last = [decimal] $State.lastBalance
    if ($Balance -lt $last) { $spent = $spent + ($last - $Balance) }

    return [pscustomobject] @{
        dayKey      = $DayKey
        currency    = $Currency
        spent       = $spent
        lastBalance = $Balance
    }
}

# 读失败一律当「没有历史」：文件被写坏不该让小窗起不来，重开一份就是了。
function Read-Spending {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        if ($null -eq $obj.lastBalance) { return $null }
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $spent = [decimal] 0
        if ($null -ne $obj.spent) { $spent = [decimal]::Parse([string] $obj.spent, $culture) }
        # 老版本写的是自然日（date 字段）：读不到 dayKey 就是空串，与任何新键都不等，
        # 于是自动从零重开一次，不会把旧口径的数字接着算下去。
        $key = ''
        if ($null -ne $obj.dayKey) { $key = [string] $obj.dayKey }
        $currency = ''
        if ($null -ne $obj.currency) { $currency = [string] $obj.currency }
        return [pscustomobject] @{
            dayKey      = $key
            currency    = $currency
            spent       = $spent
            lastBalance = [decimal]::Parse([string] $obj.lastBalance, $culture)
        }
    } catch {
        return $null
    }
}

function Save-Spending {
    param([string] $Path, $State)
    if ([string]::IsNullOrWhiteSpace($Path) -or $null -eq $State) { return }
    try {
        $dir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $spent = [decimal] $State.spent
        $last = [decimal] $State.lastBalance
        $payload = @{
            dayKey      = [string] $State.dayKey
            currency    = [string] $State.currency
            spent       = $spent.ToString($culture)
            lastBalance = $last.ToString($culture)
            updatedAt   = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($Path, $payload)
    } catch {
        # 记账失败不影响余额本身。
    }
}

# ---------------------------------------------------------------------------
# 计费时段（高峰 / 优惠）
#
# 官方定价页（api-docs.deepseek.com/quick_start/pricing）的口径：**优惠时段是高峰时段的
# 一半价钱**，而高峰是「工作日 01:00-04:00 与 06:00-10:00（UTC）」——其余时间一律优惠，
# 包括午休那两小时和整个周末。这是 2026-09-10 起生效的新口径；旧的「每天 00:30-08:30
# 错峰优惠」已经作废，别再按那个算。
#
# 判定一律换算到 UTC 再做，而不是写死「北京时间 9 点到 12 点」：换台机器、换个时区都不会错。
# ---------------------------------------------------------------------------

$script:PeakUtcBlocks = @(
    @{ Start = 60;  End = 240 },    # 01:00 - 04:00 UTC
    @{ Start = 360; End = 600 }     # 06:00 - 10:00 UTC
)

# 诊断用：-NowOverride 把「现在」钉住，好在任意时刻验证高峰与优惠两种渲染（截图靠它）。
#
# 注意：结果**不能**写回同名的 $script:NowOverride。参数是 [string] 类型，而 PowerShell 的
# 类型约束会把赋进去的 $null 变成空字符串，于是「用户到底有没有指定」就永远判成「有」，
# Get-Now 只会返回空串、Get-PricingWindow 绑参数时炸掉。这个坑只会在窗口模式里暴露，
# 逻辑自检完全不碰它（所以当时全绿）。这里另起一个没有类型约束的变量，再用 -is 兜一层。
$script:FixedNow = $null
if (-not [string]::IsNullOrWhiteSpace($NowOverride)) {
    try { $script:FixedNow = [datetime]::Parse($NowOverride) } catch { $script:FixedNow = $null }
}

function Get-Now {
    if ($script:FixedNow -is [datetime]) { return $script:FixedNow }
    return (Get-Date)
}

# 当前是高峰还是优惠，外加「本段什么时候结束」/「下次高峰什么时候开始」。
# 两个时刻都按 UTC 返回，显示时再 ToLocalTime——判定与显示分开，换时区不会算错。
function Get-PricingWindow {
    param([datetime] $Now)

    $utc = $Now.ToUniversalTime()
    $minutes = ($utc.Hour * 60) + $utc.Minute
    $weekday = $utc.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $utc.DayOfWeek -ne [System.DayOfWeek]::Sunday

    if ($weekday) {
        foreach ($block in $script:PeakUtcBlocks) {
            if ($minutes -ge $block.Start -and $minutes -lt $block.End) {
                return [pscustomobject] @{ Peak = $true; EndsAt = $utc.Date.AddMinutes($block.End); NextPeak = $null }
            }
        }
    }

    # 优惠时段：找下一次高峰开始，周末整段跳过（最多往后找一个礼拜）。
    for ($i = 0; $i -lt 8; $i++) {
        $day = $utc.Date.AddDays($i)
        if ($day.DayOfWeek -eq [System.DayOfWeek]::Saturday -or $day.DayOfWeek -eq [System.DayOfWeek]::Sunday) { continue }
        foreach ($block in $script:PeakUtcBlocks) {
            $candidate = $day.AddMinutes($block.Start)
            if ($candidate -gt $utc) {
                return [pscustomobject] @{ Peak = $false; EndsAt = $null; NextPeak = $candidate }
            }
        }
    }
    return [pscustomobject] @{ Peak = $false; EndsAt = $null; NextPeak = $null }
}

# 「3 小时 12 分」这种给人看的时长。
function Format-Duration {
    param([timespan] $Span)
    if ($Span.TotalMinutes -lt 1) { return '不到 1 分' }
    $hours = [int] [Math]::Floor($Span.TotalHours)
    if ($hours -le 0) { return ('{0} 分' -f $Span.Minutes) }
    return ('{0} 小时 {1} 分' -f $hours, $Span.Minutes)
}

# ---------------------------------------------------------------------------
# 凭据位置：-Probe 与窗口模式共用，所以必须在诊断分支之前定好，否则 `npm run probe`
# 会在「明明配置了密钥」的情况下报「未找到凭据」。
# ---------------------------------------------------------------------------

$fallbackCredentialFile = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'
if ([string]::IsNullOrWhiteSpace($CredentialFile)) {
    $home_ = $env:DSH_HOME
    if ([string]::IsNullOrWhiteSpace($home_)) { $home_ = Join-Path $env:USERPROFILE '.dsh' }
    $CredentialFile = Join-Path $home_ '.credentials.yaml'
}
if (-not (Test-Path -LiteralPath $CredentialFile) -and (Test-Path -LiteralPath $fallbackCredentialFile)) {
    $CredentialFile = $fallbackCredentialFile
}

# -SpendPath 没传时，从 StatePath 同目录推出来。漏传一个开关不该让「今日消费」整页失效——
# 它只会静默显示「等待取数」，从现象上完全看不出是参数没传（真发生过一次）。
if ([string]::IsNullOrWhiteSpace($SpendPath) -and -not [string]::IsNullOrWhiteSpace($StatePath)) {
    $SpendPath = Join-Path (Split-Path -Parent $StatePath) 'spending.json'
}

# ---------------------------------------------------------------------------
# 诊断模式：只抓一次余额并打印 JSON，不创建窗口
# ---------------------------------------------------------------------------

if ($Probe) {
    try {
        $key = Get-ApiKey -EnvName $CredentialEnv -File $CredentialFile
        if ([string]::IsNullOrWhiteSpace($key)) {
            Write-Output (@{ ok = $false; error = "未找到凭据 $CredentialEnv" } | ConvertTo-Json -Compress)
            exit 1
        }
        $snapshot = Get-BalanceSnapshot -Key $key -Base $BaseUrl -Preferred $Currency
        $payload = @{
            ok        = $true
            available = $snapshot.Available
            currency  = $snapshot.Currency
            total     = [string] $snapshot.Total
            granted   = [string] $snapshot.Granted
            toppedUp  = [string] $snapshot.ToppedUp
            display   = Format-Money -Amount $snapshot.Total -Code $snapshot.Currency
        }
        Write-Output ($payload | ConvertTo-Json -Compress)
        exit 0
    } catch {
        Write-Output (@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress)
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 逻辑自检：只跑纯函数，不开窗口、不联网
#
# 「余额下降才算消费、充值不计入、跨天与换币种重开」这套口径写在 PowerShell 里，从 Node
# 侧调不动，于是留这个开关：把判定打到 stdout，由 tests/window-script.test.mjs 断言。
# 它替代的是「盯着小窗上的数字猜对不对」——那种验证既慢又不可靠。
# ---------------------------------------------------------------------------

if ($LogicTest) {
    $script:LogicFailures = @()

    function Test-Equal {
        param([string] $Label, $Actual, $Expected)
        if ("$Actual" -ne "$Expected") {
            $script:LogicFailures += ('{0}：期望 {1}，实际 {2}' -f $Label, $Expected, $Actual)
        }
    }

    # 「一天」的边界：默认早 8 点起算、24 小时后换天。8:00 之前算前一天，8:00 整翻页。
    Test-Equal '07:59 仍算前一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-12 07:59:00') -StartHour 8) '2026-09-11T08:00'
    Test-Equal '08:00 整开始新的一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-12 08:00:00') -StartHour 8) '2026-09-12T08:00'
    Test-Equal '当天中午仍是同一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-12 12:00:00') -StartHour 8) '2026-09-12T08:00'
    Test-Equal '次日 02:00 仍算前一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-13 02:00:00') -StartHour 8) '2026-09-12T08:00'
    Test-Equal '次日 08:00 才换天' (Get-SpendingDayKey -Now ([datetime] '2026-09-13 08:00:00') -StartHour 8) '2026-09-13T08:00'
    Test-Equal '起点 0 点即自然日' (Get-SpendingDayKey -Now ([datetime] '2026-09-12 00:00:00') -StartHour 0) '2026-09-12T00:00'
    Test-Equal '起点 0 点：23:59 同一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-12 23:59:00') -StartHour 0) '2026-09-12T00:00'
    Test-Equal '起点 20 点：次日 19:00 同一天' (Get-SpendingDayKey -Now ([datetime] '2026-09-13 19:00:00') -StartHour 20) '2026-09-12T20:00'

    # 计费时段：高峰 = 工作日 UTC 01:00-04:00 与 06:00-10:00，其余（含午休与整个周末）优惠。
    # 时间一律用 SpecifyKind 明确按 UTC 构造，否则测试结果会跟着跑测试那台机器的时区变。
    $at = { param([string] $s) [datetime]::SpecifyKind([datetime] $s, [System.DateTimeKind]::Utc) }
    Test-Equal '周一 00:59 优惠' (Get-PricingWindow -Now (& $at '2026-09-14 00:59:00')).Peak 'False'
    Test-Equal '周一 01:00 进入高峰' (Get-PricingWindow -Now (& $at '2026-09-14 01:00:00')).Peak 'True'
    Test-Equal '周一 03:59 仍高峰' (Get-PricingWindow -Now (& $at '2026-09-14 03:59:00')).Peak 'True'
    Test-Equal '周一 04:00 午休转优惠' (Get-PricingWindow -Now (& $at '2026-09-14 04:00:00')).Peak 'False'
    Test-Equal '周一 06:00 再进高峰' (Get-PricingWindow -Now (& $at '2026-09-14 06:00:00')).Peak 'True'
    Test-Equal '周一 09:59 仍高峰' (Get-PricingWindow -Now (& $at '2026-09-14 09:59:00')).Peak 'True'
    Test-Equal '周一 10:00 转优惠' (Get-PricingWindow -Now (& $at '2026-09-14 10:00:00')).Peak 'False'
    Test-Equal '周六全天优惠' (Get-PricingWindow -Now (& $at '2026-09-19 02:00:00')).Peak 'False'
    Test-Equal '周日全天优惠' (Get-PricingWindow -Now (& $at '2026-09-20 08:00:00')).Peak 'False'
    Test-Equal '优惠中：下次高峰是同日的 01:00' (Get-PricingWindow -Now (& $at '2026-09-14 00:30:00')).NextPeak.ToString('MM-dd HH:mm') '09-14 01:00'
    Test-Equal '优惠中：下次高峰是同日的 06:00' (Get-PricingWindow -Now (& $at '2026-09-14 04:30:00')).NextPeak.ToString('MM-dd HH:mm') '09-14 06:00'
    Test-Equal '周一 10:00 之后下次高峰是次日 01:00' (Get-PricingWindow -Now (& $at '2026-09-14 10:00:00')).NextPeak.ToString('MM-dd HH:mm') '09-15 01:00'
    Test-Equal '周五夜里：下次高峰跳过周末到周一' (Get-PricingWindow -Now (& $at '2026-09-18 23:00:00')).NextPeak.ToString('MM-dd HH:mm') '09-21 01:00'
    Test-Equal '周六：下次高峰是周一' (Get-PricingWindow -Now (& $at '2026-09-19 02:00:00')).NextPeak.ToString('MM-dd HH:mm') '09-21 01:00'
    Test-Equal '高峰中：本段 04:00 结束' (Get-PricingWindow -Now (& $at '2026-09-14 01:30:00')).EndsAt.ToString('MM-dd HH:mm') '09-14 04:00'
    Test-Equal '高峰中：本段 10:00 结束' (Get-PricingWindow -Now (& $at '2026-09-14 06:30:00')).EndsAt.ToString('MM-dd HH:mm') '09-14 10:00'
    Test-Equal '时长 3 小时 5 分' (Format-Duration -Span ([timespan]::FromMinutes(185))) '3 小时 5 分'
    Test-Equal '时长 42 分' (Format-Duration -Span ([timespan]::FromMinutes(42))) '42 分'
    Test-Equal '时长不到 1 分' (Format-Duration -Span ([timespan]::FromSeconds(30))) '不到 1 分'
    # 没给 -NowOverride 时 Get-Now 必须返回真正的 DateTime。这里曾经返回空串——参数是
    # [string]，类型约束把 $null 变成了 ''，而判定用的是 -ne $null，于是永远为真。
    Test-Equal 'Get-Now 缺省返回 DateTime' ((Get-Now) -is [datetime]) 'True'

    $day = '2026-01-02T08:00'
    $sample = $null

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 42.00) -Currency 'CNY' -DayKey $day
    Test-Equal '首次取样不产生消费' (Format-Money -Amount $sample.spent -Code 'CNY') '¥0.00'

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 41.50) -Currency 'CNY' -DayKey $day
    Test-Equal '余额少 0.50 记 0.50' (Format-Money -Amount $sample.spent -Code 'CNY') '¥0.50'

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 41.20) -Currency 'CNY' -DayKey $day
    Test-Equal '再少 0.30 累计 0.80' (Format-Money -Amount $sample.spent -Code 'CNY') '¥0.80'

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 61.20) -Currency 'CNY' -DayKey $day
    Test-Equal '充值不计入也不抵扣' (Format-Money -Amount $sample.spent -Code 'CNY') '¥0.80'

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 60.70) -Currency 'CNY' -DayKey $day
    Test-Equal '充值之后继续累计' (Format-Money -Amount $sample.spent -Code 'CNY') '¥1.30'

    $sample = Add-BalanceSample -State $sample -Balance ([decimal] 60.70) -Currency 'CNY' -DayKey $day
    Test-Equal '余额没变不产生消费' (Format-Money -Amount $sample.spent -Code 'CNY') '¥1.30'

    # 跨到「下一个 8 点」之后：计数归零，但基准线必须留着——小窗关着那段时间的减少量要
    # 记到新的一天，否则就会重现「明明花了钱、卡上只有几毛」。注意 0.70 而不是 0.00：
    # 那正是从 60.70 掉到 60.00 的那一段，而昨天累计的 1.30 没有被带过来。
    $nextDay = Add-BalanceSample -State $sample -Balance ([decimal] 60.00) -Currency 'CNY' -DayKey '2026-01-03T08:00'
    Test-Equal '跨天：这段时间的减少量记到新的一天' (Format-Money -Amount $nextDay.spent -Code 'CNY') '¥0.70'
    Test-Equal '跨天后基准线取新值' (Format-Money -Amount $nextDay.lastBalance -Code 'CNY') '¥60.00'

    # 跨天时余额反而变多（关机期间充了值）：既不算消费，也不把充值当抵扣。
    $nextDayTopUp = Add-BalanceSample -State $sample -Balance ([decimal] 70.00) -Currency 'CNY' -DayKey '2026-01-03T08:00'
    Test-Equal '跨天遇充值：归零且不产生消费' (Format-Money -Amount $nextDayTopUp.spent -Code 'CNY') '¥0.00'
    Test-Equal '跨天遇充值：基准线抬到新值' (Format-Money -Amount $nextDayTopUp.lastBalance -Code 'CNY') '¥70.00'

    $otherCurrency = Add-BalanceSample -State $sample -Balance ([decimal] 8.00) -Currency 'USD' -DayKey $day
    Test-Equal '换币种从零重开' (Format-Money -Amount $otherCurrency.spent -Code 'USD') '$0.00'

    $fresh = Add-BalanceSample -State $null -Balance ([decimal] 5.00) -Currency 'CNY' -DayKey $day
    Test-Equal '没有历史时从零开始' (Format-Money -Amount $fresh.spent -Code 'CNY') '¥0.00'

    Test-Equal '人民币两位小数' (Format-Money -Amount ([decimal] 3.4) -Code 'CNY') '¥3.40'
    Test-Equal '美元千分位' (Format-Money -Amount ([decimal] 1234.5) -Code 'USD') '$1,234.50'

    # 落盘再读回来：金额是以不变文化的字符串写出去的，读回来必须一模一样。
    $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-api-balance-logictest-{0}.json' -f $PID)
    Save-Spending -Path $probePath -State $sample
    $restored = Read-Spending -Path $probePath
    if ($null -eq $restored) {
        $script:LogicFailures += '落盘读回：文件没读回来'
    } else {
        Test-Equal '落盘读回金额一致' (Format-Money -Amount $restored.spent -Code $restored.currency) '¥1.30'
        Test-Equal '落盘读回币种一致' $restored.currency 'CNY'
        Test-Equal '落盘读回起算时刻一致' $restored.dayKey '2026-01-02T08:00'
    }
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue

    if ($script:LogicFailures.Count -gt 0) {
        foreach ($failure in $script:LogicFailures) { Write-Output ('  - ' + $failure) }
        Write-Output 'LOGICTEST FAIL'
        exit 1
    }
    Write-Output 'LOGICTEST PASS'
    exit 0
}

# ---------------------------------------------------------------------------
# 窗口模式
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 同一时刻只允许一个余额小窗；DSH 重启时上一扇窗可能还在退出，因此最多等 8 秒。
$mutex = New-Object System.Threading.Mutex($false, ('Local\' + $InstanceName))
$hasHandle = $false
$deadline = (Get-Date).AddSeconds(8)
while (-not $hasHandle -and (Get-Date) -lt $deadline) {
    try {
        $hasHandle = $mutex.WaitOne(200)
    } catch [System.Threading.AbandonedMutexException] {
        $hasHandle = $true
    }
}
if (-not $hasHandle) {
    # 自检模式下这里必须吵一句。静默 exit 0 会让测试只看到「输出里没有 PASS」，完全查不出
    # 原因（真遇到过：上一扇窗还没退干净，这一轮就静默不干活）。
    if ($SelfTest) {
        [Console]::Out.WriteLine("SELFTEST FAIL: 拿不到单实例互斥量（-InstanceName $InstanceName），可能还有上一扇窗没退干净")
        [Console]::Out.Flush()
        exit 1
    }
    exit 0
}

# --- 配色 -------------------------------------------------------------------
#
# 每个主题九个颜色：卡片底色、边框、三种文字层级、以及状态点的三种状态色。
# 想加主题就往这里加一行，右键菜单会自动多出一项（菜单是按这张表生成的）。
$script:Themes = [ordered]@{
    navy     = @{ Label = '深海蓝'; Card = '#1A1E28'; Border = '#3A4152'; Title = '#9EA8BE'; Value = '#F2F5FA'; Sub = '#8C97AC'; Muted = '#747E94'; Ok = '#4ADE80'; Warn = '#FBBF24'; Error = '#F87171' }
    graphite = @{ Label = '石墨黑'; Card = '#17181A'; Border = '#303236'; Title = '#9AA0A6'; Value = '#FFFFFF'; Sub = '#8B9096'; Muted = '#6B7075'; Ok = '#34D399'; Warn = '#FBBF24'; Error = '#F87171' }
    teal     = @{ Label = '墨绿';   Card = '#10241F'; Border = '#1F4A3D'; Title = '#7FB5A4'; Value = '#E8FFF6'; Sub = '#79A797'; Muted = '#5B8578'; Ok = '#5EEAD4'; Warn = '#FCD34D'; Error = '#FB7185' }
    plum     = @{ Label = '紫罗兰'; Card = '#1E1626'; Border = '#453056'; Title = '#B9A3CC'; Value = '#F6EFFF'; Sub = '#9A87AC'; Muted = '#7A6A8C'; Ok = '#6EE7B7'; Warn = '#FCD34D'; Error = '#FB7185' }
    sunset   = @{ Label = '暖棕';   Card = '#251A14'; Border = '#4E382A'; Title = '#C4A48A'; Value = '#FFF3E8'; Sub = '#A98B74'; Muted = '#8A705C'; Ok = '#86EFAC'; Warn = '#FDBA74'; Error = '#FCA5A5' }
    light    = @{ Label = '浅色';   Card = '#FFFFFF'; Border = '#D8DEE9'; Title = '#64748B'; Value = '#0F172A'; Sub = '#475569'; Muted = '#94A3B8'; Ok = '#16A34A'; Warn = '#D97706'; Error = '#DC2626' }
    paper    = @{ Label = '米白纸'; Card = '#FAF7F2'; Border = '#E2D9CC'; Title = '#8A7A66'; Value = '#2B2317'; Sub = '#6B5D4B'; Muted = '#A08F79'; Ok = '#15803D'; Warn = '#B45309'; Error = '#B91C1C' }
}

$script:DefaultTheme = 'navy'
$script:ThemeName = $script:DefaultTheme
$script:Palette = @{}
$script:Brushes = @{}

function ConvertTo-ThemeColor {
    param([string] $Html)
    return [System.Drawing.ColorTranslator]::FromHtml($Html)
}

# --- 自定义背景图片 ---------------------------------------------------------
#
# 用户把图片丢进 $BackgroundDir，右键「外观 → 图片」里就会列出来。
# 只认 GDI+ 能解码的格式（jpg/png/bmp/gif）；webp 之类 System.Drawing 打不开，
# 列出来也只会变成一块空背景，所以干脆不列。

$script:BackgroundExtensions = @('.jpg', '.jpeg', '.png', '.bmp', '.gif')
$script:BackgroundImage = $null
$script:BackgroundName = ''

# 蒙版浓度：图片上盖一层卡片色的半透明，保证数字在任何图上都读得清。
# 这是「图清不清楚」与「字看不看得清」之间的那根旋钮，所以做成菜单可调并记住选择。
# Alpha 0-255：0 = 完全不盖（图最清楚），越大字越清楚、图越淡。
$script:ScrimLevels = [ordered]@{
    none   = @{ Label = '无（图最清楚）';   Alpha = 0 }
    light  = @{ Label = '淡';               Alpha = 51 }
    medium = @{ Label = '中';               Alpha = 128 }
    strong = @{ Label = '浓';               Alpha = 179 }
    heavy  = @{ Label = '很浓（字最清楚）'; Alpha = 217 }
}
$script:DefaultScrim = 'medium'
$script:ScrimName = $script:DefaultScrim
$script:ScrimAlpha = $script:ScrimLevels[$script:DefaultScrim].Alpha

# 换蒙版浓度：只重建那一支画刷，不惊动主题与背景图。
function Set-Scrim {
    param([string] $Name)
    if (-not $script:ScrimLevels.Contains($Name)) { $Name = $script:DefaultScrim }
    $script:ScrimName = $Name
    $script:ScrimAlpha = $script:ScrimLevels[$Name].Alpha
    if ($script:Brushes.ContainsKey('Scrim') -and $null -ne $script:Brushes['Scrim']) {
        $script:Brushes['Scrim'].Dispose()
        $script:Brushes['Scrim'] = New-Object System.Drawing.SolidBrush(
            [System.Drawing.Color]::FromArgb($script:ScrimAlpha, $script:Palette.Card))
    }
    Request-Repaint
}

function Initialize-BackgroundFolder {
    if ([string]::IsNullOrWhiteSpace($BackgroundDir)) { return }
    try {
        if (-not (Test-Path -LiteralPath $BackgroundDir)) {
            New-Item -ItemType Directory -Path $BackgroundDir -Force | Out-Null
            $readme = @(
                '把你想用作余额小窗背景的图片放进这个文件夹。',
                '',
                '支持的格式：.jpg / .jpeg / .png / .bmp / .gif',
                '',
                '放好之后，在小窗上右键 →「外观 → 图片」里选一张即可，选完会记住。',
                '图片会被等比放大到铺满整张卡片（裁掉多余部分，不拉伸变形），',
                '上面再盖一层当前主题色做蒙版，保证文字始终清晰。'
            ) -join "`r`n"
            [System.IO.File]::WriteAllText((Join-Path $BackgroundDir '说明.txt'), $readme, [System.Text.UTF8Encoding]::new($true))
        }
    } catch {
        # 建不了就算了：菜单里会显示「没有可用图片」。
    }
}

# 列出可用图片，按文件名排序。返回 @{ Name; Path } 数组。
function Get-BackgroundFiles {
    $result = @()
    if ([string]::IsNullOrWhiteSpace($BackgroundDir)) { return $result }
    if (-not (Test-Path -LiteralPath $BackgroundDir)) { return $result }
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $BackgroundDir -File -ErrorAction Stop | Sort-Object Name)) {
            if ($script:BackgroundExtensions -contains $file.Extension.ToLowerInvariant()) {
                $result += @{ Name = $file.Name; Path = $file.FullName }
            }
        }
    } catch {
        return @()
    }
    return $result
}

# 载入一张背景图。先读进内存再复制一份，避免 Image 一直占着文件句柄——
# 否则用户想在运行期间换图/删图会被「文件正在使用」挡住。
function Set-Background {
    param([string] $Path)

    if ($null -ne $script:BackgroundImage) {
        $script:BackgroundImage.Dispose()
        $script:BackgroundImage = $null
    }
    $script:BackgroundName = ''

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Request-Repaint
        return $true
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $stream = New-Object System.IO.MemoryStream($bytes, $false)
        $decoded = [System.Drawing.Image]::FromStream($stream)

        # 卡片只有 345x148 物理像素，没必要把 4K 壁纸整张常驻内存（3840x2586 的图
        # 要 38MB），更没必要每次重绘都现缩一遍。载入时等比缩到「卡片尺寸的 2 倍」
        # ——2 倍是给 DPI 与裁切留的余量，之后重绘只是小图缩放。
        # 用 cover 口径（取两个方向缩放比的较大者），保证缩完仍然铺得满卡片。
        $maxW = (Px 276) * 2
        $maxH = (Px 118) * 2
        $fit = [Math]::Min(1.0, [Math]::Max($maxW / $decoded.Width, $maxH / $decoded.Height))
        $targetW = [int] [Math]::Max(1, [Math]::Round($decoded.Width * $fit))
        $targetH = [int] [Math]::Max(1, [Math]::Round($decoded.Height * $fit))

        $copy = New-Object System.Drawing.Bitmap($targetW, $targetH)
        $cg = [System.Drawing.Graphics]::FromImage($copy)
        $cg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $cg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $cg.DrawImage($decoded, 0, 0, $targetW, $targetH)
        $cg.Dispose()

        $decoded.Dispose()
        $stream.Dispose()
        $script:BackgroundImage = $copy
        $script:BackgroundName = [System.IO.Path]::GetFileName($Path)
        Request-Repaint
        return $true
    } catch {
        Request-Repaint
        return $false
    }
}

# 按主题名重建调色板与画刷。切主题必须重建画刷对象本身——画的时候用的是
# $script:Brushes 里的对象，光改 Color 不会影响已经建好的画刷。
function Set-Theme {
    param([string] $Name)

    if (-not $script:Themes.Contains($Name)) { $Name = $script:DefaultTheme }
    $t = $script:Themes[$Name]
    $script:ThemeName = $Name

    $script:Palette = @{
        Card   = ConvertTo-ThemeColor $t.Card
        Border = ConvertTo-ThemeColor $t.Border
        Title  = ConvertTo-ThemeColor $t.Title
        Value  = ConvertTo-ThemeColor $t.Value
        Sub    = ConvertTo-ThemeColor $t.Sub
        Muted  = ConvertTo-ThemeColor $t.Muted
        Ok     = ConvertTo-ThemeColor $t.Ok
        Warn   = ConvertTo-ThemeColor $t.Warn
        Error  = ConvertTo-ThemeColor $t.Error
    }

    foreach ($old in $script:Brushes.Values) { $old.Dispose() }
    $script:Brushes = @{
        Card   = New-Object System.Drawing.SolidBrush($script:Palette.Card)
        Border = New-Object System.Drawing.Pen($script:Palette.Border, 1)
        Title  = New-Object System.Drawing.SolidBrush($script:Palette.Title)
        Value  = New-Object System.Drawing.SolidBrush($script:Palette.Value)
        Sub    = New-Object System.Drawing.SolidBrush($script:Palette.Sub)
        Muted  = New-Object System.Drawing.SolidBrush($script:Palette.Muted)
        Ok     = New-Object System.Drawing.SolidBrush($script:Palette.Ok)
        Warn   = New-Object System.Drawing.SolidBrush($script:Palette.Warn)
        Error  = New-Object System.Drawing.SolidBrush($script:Palette.Error)
        # 盖在背景图上的蒙版，颜色跟着主题走：深色主题压暗、浅色主题提亮。
        Scrim  = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($script:ScrimAlpha, $script:Palette.Card))
    }

    # 窗体与画布要跟着换底色；这两样在启动早期还不存在，所以要判空。
    if ($null -ne $script:WinForm) { $script:WinForm.BackColor = $script:Palette.Card }
    if ($null -ne $script:Canvas) { $script:Canvas.BackColor = $script:Palette.Card }
    if ($null -ne $script:Tray) { $script:Tray.Icon = New-TrayIcon }
    if ($null -ne $script:Canvas -and -not $script:Canvas.IsDisposed) { $script:Canvas.Invalidate() }
}

Set-Theme -Name $script:DefaultTheme

$script:Fonts = @{
    Title  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 9.0, [System.Drawing.FontStyle]::Regular)
    Value  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 23.0, [System.Drawing.FontStyle]::Bold)
    Usage  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 9.0, [System.Drawing.FontStyle]::Regular)
    Footer = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 8.0, [System.Drawing.FontStyle]::Regular)
    Button = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 8.5, [System.Drawing.FontStyle]::Regular)
    Close  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 12.0, [System.Drawing.FontStyle]::Regular)
}

$script:View = @{
    Title  = 'DeepSeek 余额'
    Value  = '正在获取…'
    Usage  = '今日 统计中…'
    Footer = ''
    # 状态点用「桶名」而不是画刷对象：换主题会重建所有画刷，存对象就会指向
    # 已经被 Dispose 的旧画刷，画的时候直接出错。
    Accent = 'Muted'
}

$script:RefreshSeconds = [Math]::Max(10, $RefreshSeconds)
$script:Fetching = $false
$script:LastSnapshot = $null
$script:CloseRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
$script:RefreshRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)

# 三页：0 = 余额，1 = 今日消费，2 = 计费时段（高峰 / 优惠）。
#
# 换页做成「点金额那块区域」而不是左右滑动：这张卡片本身要靠拖动来移动位置，横向滑动会
# 和拖拽抢同一个手势——同一个手指动作既可能被当成翻页、也可能被当成挪窗，怎么调都会有一
# 边不跟手。点一下没有歧义，也更容易发现；三页之后就是「往后翻一页，到头绕回第一页」。
$script:PageCount = 3
$script:PageTitles = @('余额', '今日消费', '计费时段')
# 诊断用：-StartPage 直接开在指定页，验证与截图就不必靠连点（点在真窗口里带系统级时序）。
$script:Page = 0
if ($StartPage -gt 0 -and $StartPage -lt $script:PageCount) { $script:Page = $StartPage }
$script:FlipRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
$script:PageSync = $null         # 菜单勾选同步器，菜单建好之后才回填；Set-Page 可能先被调到
# 第 3 页的文字由 2 秒一次的 tick 算好放在这里（倒计时要走字），Paint 只负责画。
$script:PricingView = @{ Peak = $false; Value = '计费时段'; Sub = ''; Footer = '' }
# 「一天」的起点默认早 8 点：记账的一天是 8:00 到次日 8:00 这 24 小时。越界值退回 8。
$script:DayStartHour = $DayStartHour
if ($script:DayStartHour -lt 0 -or $script:DayStartHour -gt 23) { $script:DayStartHour = 8 }
$script:Spending = Read-Spending -Path $SpendPath

function New-RoundedPath {
    param([int] $Width, [int] $Height, [int] $Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($Width - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($Width - $d - 1, $Height - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $Height - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

# 打开控件的双缓冲。
#
# 面板默认是单缓冲的：每次重绘都先把底色擦到屏幕上、再画内容，中间那一帧就是肉眼看到的
# 「闪」。DoubleBuffered / SetStyle 都是 protected，PowerShell 里只能靠反射打开。
# 失败也不致命（退回单缓冲，只是还会闪），所以这里只记一笔、不抛异常。
function Enable-DoubleBuffering {
    param($Control)
    try {
        $flags = [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
                 [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
                 [System.Windows.Forms.ControlStyles]::UserPaint
        $method = [System.Windows.Forms.Control].GetMethod(
            'SetStyle',
            [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        $method.Invoke($Control, @($flags, $true))
        $script:DoubleBuffered = $true
    } catch {
        $script:DoubleBuffered = $false
    }
}

# 有变化才重绘。窗口每 2 秒醒一次读 token 用量，但数字多数时候没变——照旧无条件
# Invalidate 的话，就是每 2 秒白闪一次。
function Request-Repaint {
    if ($null -ne $script:Canvas -and -not $script:Canvas.IsDisposed) { $script:Canvas.Invalidate() }
}

function Set-View {
    param([string] $Value, [string] $Footer, [string] $Accent)
    $changed = $script:View.Value -ne $Value -or $script:View.Footer -ne $Footer
    if (-not [string]::IsNullOrEmpty($Accent) -and $script:View.Accent -ne $Accent) {
        $script:View.Accent = $Accent
        $changed = $true
    }
    if (-not $changed) { return }
    $script:View.Value = $Value
    $script:View.Footer = $Footer
    Request-Repaint
}

# 菜单里「页面」子菜单的勾选跟着当前页走，用户不用记「现在停在哪一页」。
function Update-PageChecks {
    if ($null -eq $script:PageSync) { return }
    & $script:PageSync
}

function Set-Page {
    param([int] $Index)
   if ($Index -lt 0 -or $Index -ge $script:PageCount) { $Index = 0 }
    if ($script:Page -eq $Index) { return }
    $script:Page = $Index
    Update-PageChecks
    # 第 3 页的内容由 tick 维护；切过去时先算一次，免得先看到上一分钟的旧字。
    if ($script:Page -eq 2) { Update-PricingView }
    Request-Repaint
}

# 点一下往后翻一页，到最后一页绕回第一页。
function Flip-Page {
    Set-Page -Index (($script:Page + 1) % $script:PageCount)
}

# 把一段文本裁到给定宽度以内（超出部分换成省略号），用于「可能很长的错误信息」。
function Get-FittedText {
    param($Graphics, [string] $Text, $Font, [single] $MaxWidth)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Graphics.MeasureString($Text, $Font).Width -le $MaxWidth) { return $Text }
    $low = 0
    $high = $Text.Length
    while ($low -lt $high) {
        $mid = [int] [Math]::Floor(($low + $high + 1) / 2)
        $probe = $Text.Substring(0, $mid) + '…'
        if ($Graphics.MeasureString($probe, $Font).Width -le $MaxWidth) { $low = $mid } else { $high = $mid - 1 }
    }
    if ($low -le 0) { return '' }
    return $Text.Substring(0, $low) + '…'
}

# 读宿主插件写的 token 用量。文件可能正在被原子替换，任何读失败都当「没有数据」。
function Read-UsageFile {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        if ($null -eq $obj.total) { return $null }
        return @{
            Total     = [double] $obj.total
            TotalText = [string] $obj.totalText
        }
    } catch {
        return $null
    }
}

# 只更新 token 那一行。余额刷新走 Set-View，动的是 Value/Footer/Accent，不碰这个字段，
# 两条数据各自独立刷新。这里显示的是**当天累计**（跨多次开关机），不是本次开机。
function Update-UsageView {
    $usage = Read-UsageFile -Path $UsagePath
    if ($null -eq $usage) {
        $next = '今日 暂无数据'
    } else {
        $text = $usage.TotalText
        if ([string]::IsNullOrWhiteSpace($text)) { $text = ('{0:N0}' -f $usage.Total) }
        # 口径由宿主决定：它把一天里每次开机的用量累加成当天合计（日界与「今日消费」同一个）。
        # 小窗只管显示，不自己算日期——省得两边各有一套日界。
        $next = '今日 {0} tokens' -f $text
    }
    # 这一行每 2 秒被读一次，但数字多数时候没变；没变就一个字都不画。
    if ($script:View.Usage -eq $next) { return }
    $script:View.Usage = $next
    Request-Repaint
}

# 第 3 页要显示的东西：现在贵不贵、还有多久变。2 秒算一次（倒计时要走字），但**只有文字
# 真的变了才重绘**——否则就违反了「无条件 Invalidate 就是白闪」那条硬约束。
function Update-PricingView {
    $now = Get-Now
    $window = Get-PricingWindow -Now $now
    if ($window.Peak) {
        $value = '高峰时段'
        $endsAt = $window.EndsAt.ToLocalTime()
        $sub = '至 {0} 结束 · 还剩 {1}' -f $endsAt.ToString('HH:mm'), (Format-Duration -Span ($endsAt - $now))
    } else {
        $value = '优惠时段'
        if ($null -ne $window.NextPeak) {
            $sub = '半价 · 下次高峰 {0}' -f $window.NextPeak.ToLocalTime().ToString('MM-dd HH:mm')
        } else {
            $sub = '半价'
        }
    }
    $footer = '高峰按 2× 计价 · 其余时间半价'
    if ($script:PricingView.Peak -eq $window.Peak -and $script:PricingView.Value -eq $value -and $script:PricingView.Sub -eq $sub) { return }
    $script:PricingView = @{ Peak = $window.Peak; Value = $value; Sub = $sub; Footer = $footer }
    Request-Repaint
}

# 窗口位置与外观都记在 state.json 里，由小窗独占写（宿主插件只写 usage.json）。
function Read-SavedPosition {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        if ($null -eq $obj.x -or $null -eq $obj.y) { return $null }
        $theme = ''
        if ($null -ne $obj.theme) { $theme = [string] $obj.theme }
        $background = ''
        if ($null -ne $obj.background) { $background = [string] $obj.background }
        $scrim = ''
        if ($null -ne $obj.scrim) { $scrim = [string] $obj.scrim }
        $scale = 0.0
        if ($null -ne $obj.dpiScale) { $scale = [double] $obj.dpiScale }
        return @{ X = [int] $obj.x; Y = [int] $obj.y; Theme = $theme; Background = $background; Scrim = $scrim; DpiScale = $scale }
    } catch {
        return $null
    }
}

function Save-Position {
    param([string] $Path, [int] $X, [int] $Y)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $dir = Split-Path -Parent $Path
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # 位置、主题、背景图、以及写这份坐标时的 DPI 缩放一起写：几者都可能被单独
        # 改动，合并写才不会互相覆盖；dpiScale 用于下次启动时把老坐标换算到当前坐标系。
        $payload = @{
            x          = $X
            y          = $Y
            theme      = $script:ThemeName
            background = $script:BackgroundName
            scrim      = $script:ScrimName
            dpiScale   = $script:DpiScale
            savedAt    = (Get-Date).ToString('o')
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($Path, $payload)
    } catch {
        # 记忆失败不影响主功能。
    }
}

# 只改主题、不动位置：记在内存里，等下次拖动（或此处直接读回旧坐标）时一并落盘。
function Save-ThemeChoice {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { return }
    $saved = Read-SavedPosition -Path $StatePath
    if ($null -ne $saved) {
        Save-Position -Path $StatePath -X $saved.X -Y $saved.Y
    } else {
        Save-Position -Path $StatePath -X $script:WinForm.Location.X -Y $script:WinForm.Location.Y
    }
}

function Test-PositionVisible {
    param([int] $X, [int] $Y, [int] $Width, [int] $Height)
    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        $area = $screen.WorkingArea
        $intersect = [System.Drawing.Rectangle]::Intersect(
            (New-Object System.Drawing.Rectangle($X, $Y, $Width, $Height)), $area)
        if ($intersect.Width -ge 60 -and $intersect.Height -ge 30) { return $true }
    }
    return $false
}

# 卡片尺寸按 DPI 缩放：这些数字是 100% 缩放下的设计值，物理尺寸随 DPI 走。
$width = Px 276
$height = Px 118
$radius = Px 14

$form = New-Object System.Windows.Forms.Form
$script:WinForm = $form   # 换主题时要改它的底色
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Text = 'DeepSeek 余额'
$form.ClientSize = New-Object System.Drawing.Size($width, $height)
$form.BackColor = $script:Palette.Card
$form.Opacity = 0.95
$form.MinimizeBox = $false
$form.MaximizeBox = $false
$formPath = New-RoundedPath -Width $width -Height $height -Radius $radius
$form.Region = New-Object System.Drawing.Region -ArgumentList $formPath
$formPath.Dispose()

$saved = Read-SavedPosition -Path $StatePath

# 外观优先级：用户在右键菜单里选过的（记在 state.json）> 插件配置传来的 -Theme。
# 这样菜单里换一次就长期有效，不会被下次启动的默认值覆盖回去。
$initialTheme = $Theme
$initialScrim = $Scrim
if ($null -ne $saved) {
    if (-not [string]::IsNullOrWhiteSpace($saved.Theme)) { $initialTheme = $saved.Theme }
    if (-not [string]::IsNullOrWhiteSpace($saved.Scrim)) { $initialScrim = $saved.Scrim }
}
# 先定蒙版浓度再建主题：Set-Theme 会按当前 alpha 建蒙版画刷。
Set-Scrim -Name $initialScrim
Set-Theme -Name $initialTheme

# 背景图同样以 state.json 里记的为准：放在文件夹里的图被删掉就静默回退到纯色。
Initialize-BackgroundFolder
if ($null -ne $saved -and -not [string]::IsNullOrWhiteSpace($saved.Background) -and -not [string]::IsNullOrWhiteSpace($BackgroundDir)) {
    $savedBackground = Join-Path $BackgroundDir $saved.Background
    if (Test-Path -LiteralPath $savedBackground) { [void] (Set-Background -Path $savedBackground) }
}

$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$margin = Px 18

# 老 state.json 是「DPI 不感知」的进程写的，坐标属于被系统拉伸过的虚拟坐标系
# （125% 下 276 逻辑像素被显示成 345 物理像素）。现在本进程按物理像素工作，
# 必须把那份坐标换算过来，否则窗口会整体偏移到左上角去。
if ($null -ne $saved) {
    if ($saved.DpiScale -le 0) {
        $saved.X = [int] [Math]::Round($saved.X * $script:DpiScale)
        $saved.Y = [int] [Math]::Round($saved.Y * $script:DpiScale)
    } elseif ([Math]::Abs($saved.DpiScale - $script:DpiScale) -gt 0.001) {
        $ratio = $script:DpiScale / $saved.DpiScale
        $saved.X = [int] [Math]::Round($saved.X * $ratio)
        $saved.Y = [int] [Math]::Round($saved.Y * $ratio)
    }
}

$location = $null
if ($null -ne $saved -and (Test-PositionVisible -X $saved.X -Y $saved.Y -Width $width -Height $height)) {
    $location = New-Object System.Drawing.Point($saved.X, $saved.Y)
} else {
    switch ($Corner) {
        'top-left' { $location = New-Object System.Drawing.Point(($area.Left + $margin), ($area.Top + $margin)) }
        'bottom-left' { $location = New-Object System.Drawing.Point(($area.Left + $margin), ($area.Bottom - $height - $margin)) }
        'bottom-right' { $location = New-Object System.Drawing.Point(($area.Right - $width - $margin), ($area.Bottom - $height - $margin)) }
        default { $location = New-Object System.Drawing.Point(($area.Right - $width - $margin), ($area.Top + $margin)) }
    }
}
$form.Location = $location

# 消息循环用 ApplicationContext，不用 ShowDialog：ShowDialog 的模态循环在窗体变
# 「不可见」时就结束，于是「× 收进托盘」会顺手把进程也一起结束掉（这条正是自检抓出来的）。
# 不带 MainForm 的 ApplicationContext 只在显式 ExitThread 时结束，隐藏窗口对它毫无影响。
$context = New-Object System.Windows.Forms.ApplicationContext

$canvas = New-Object System.Windows.Forms.Panel
$canvas.Dock = [System.Windows.Forms.DockStyle]::Fill
$canvas.BackColor = $script:Palette.Card
Enable-DoubleBuffering -Control $canvas
$script:Canvas = $canvas
$form.Controls.Add($canvas)

$canvas.Add_Paint({
    param($sender, $e)

    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $w = $sender.Width
    $h = $sender.Height

    # 先把底色铺满，再画内容。这一步是防闪的关键：以前这里只画边框和文字，底色靠
    # WinForms 在 Paint 之前擦到屏幕上——那会出现「先闪过一帧纯底色、再出现文字」，
    # 也就是肉眼看到的闪烁。现在底色与内容一起画进后备缓冲，整帧一次性呈现。
    if ($null -ne $script:BackgroundImage) {
        # 背景图：等比放大到铺满（cover），多出来的部分居中裁掉，不拉伸变形；
        # 再盖一层主题色蒙版，保证数字在任何图上都读得清。
        $img = $script:BackgroundImage
        $scale = [Math]::Max($w / $img.Width, $h / $img.Height)
        $srcW = [int] [Math]::Round($w / $scale)
        $srcH = [int] [Math]::Round($h / $scale)
        $srcX = [int] [Math]::Max(0, [Math]::Round(($img.Width - $srcW) / 2))
        $srcY = [int] [Math]::Max(0, [Math]::Round(($img.Height - $srcH) / 2))
        $destRect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $g.DrawImage($img, $destRect, $srcX, $srcY, $srcW, $srcH, [System.Drawing.GraphicsUnit]::Pixel)
        $g.FillRectangle($script:Brushes.Scrim, $destRect)
    } else {
        $g.Clear($script:Palette.Card)
    }

    $borderPath = New-RoundedPath -Width $w -Height $h -Radius $radius
    $g.DrawPath($script:Brushes.Border, $borderPath)

    $view = $script:View
    $accentName = $view['Accent']

    # 第 2、3 页的内容在这里现算：它们的数据来源不是 $script:View（那是第 1 页的状态）。
    $title = $view['Title']
    $value = $view['Value']
    $sub = $view['Usage']
    $footer = $view['Footer']
    if ($script:Page -eq 1) {
        $title = '今日消费'
        $spending = $script:Spending
        if ($null -eq $spending) {
            $value = '等待取数'
            $sub = '还没有余额记录'
        } else {
            $value = Format-Money -Amount $spending.spent -Code $spending.currency
            if ($null -ne $script:LastSnapshot) {
                $sub = '余额 {0}' -f (Format-Money -Amount $script:LastSnapshot.Total -Code $script:LastSnapshot.Currency)
            } else {
                $sub = ''
            }
            # 起算时刻从记账里读回来，而不是用当前配置：改过配置后也不会把旧账说错。
            $recorded = [string] $spending.dayKey
            if ($recorded.Length -ge 16) {
                $since = $recorded.Substring(11, 5) + ' 起算'
                if ($sub -ne '') { $sub = $sub + ' · ' + $since } else { $sub = $since }
            }
        }
        $footer = '按余额减少量估算 · 充值不计入'
    } elseif ($script:Page -eq 2) {
        # 内容由 2 秒一次的 tick 算好（倒计时在走字），这里只负责画。
        $pricing = $script:PricingView
        $title = '计费时段'
        $value = $pricing.Value
        $sub = $pricing.Sub
        $footer = $pricing.Footer
        # 优惠时段点绿灯、高峰点黄灯：一眼就能看出现在贵不贵。
        if ($pricing.Peak) { $accentName = 'Warn' } else { $accentName = 'Ok' }
    }

    $accent = $script:Brushes[$accentName]
    if ($null -ne $accent) { $g.FillEllipse($accent, (Px 16), (Px 16), (Px 7), (Px 7)) }
    $g.DrawString($title, $script:Fonts['Title'], $script:Brushes.Title, (Px 30), (Px 11))

    $script:RefreshRect = New-Object System.Drawing.Rectangle(($w - (Px 62)), (Px 7), (Px 32), (Px 22))
    $script:CloseRect = New-Object System.Drawing.Rectangle(($w - (Px 29)), (Px 7), (Px 22), (Px 22))
    # 点这一整块换页。右侧留给「刷新」与「×」，下方留给脚注和页码点，都不会误触。
    $script:FlipRect = New-Object System.Drawing.Rectangle((Px 6), (Px 22), ($w - (Px 76)), (Px 62))
    $g.DrawString('刷新', $script:Fonts.Button, $script:Brushes.Muted, ($w - (Px 60)), (Px 12))
    $g.DrawString('×', $script:Fonts.Close, $script:Brushes.Muted, ($w - (Px 26)), (Px 7))

    $g.DrawString($value, $script:Fonts['Value'], $script:Brushes.Value, (Px 14), (Px 28))

    # token 行与脚注：数字已在宿主侧压成「141.6K」这种短文本，这里只负责拼句子。
    if ($sub -ne '') {
        $g.DrawString($sub, $script:Fonts['Usage'], $script:Brushes.Sub, (Px 17), (Px 66))
    }
    if (-not [string]::IsNullOrWhiteSpace($footer)) {
        # 脚注留出右下角那几个页码点的位置（因此比原来窄一点）。
        $footerText = Get-FittedText -Graphics $g -Text $footer -Font $script:Fonts['Footer'] -MaxWidth ($w - (Px 46))
        $g.DrawString($footerText, $script:Fonts['Footer'], $script:Brushes.Muted, (Px 17), (Px 88))
    }

    # 右下角每页一个小圆点：当前页亮，其余弱。点由右往左排，页数多了也只占一条。
    $dotBase = $w - (Px (10 * $script:PageCount + 10))
    for ($dot = 0; $dot -lt $script:PageCount; $dot++) {
        $dotBrush = $script:Brushes.Muted
        if ($dot -eq $script:Page) { $dotBrush = $script:Brushes.Value }
        $g.FillEllipse($dotBrush, ($dotBase + ($dot * (Px 10))), ($h - (Px 14)), (Px 5), (Px 5))
    }

    $borderPath.Dispose()
})

function Update-Balance {
    if ($script:Fetching) { return }
    $script:Fetching = $true
    Set-View -Value '正在获取…' -Footer '正在读取账户余额' -Accent 'Muted'
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $key = Get-ApiKey -EnvName $CredentialEnv -File $CredentialFile
        if ([string]::IsNullOrWhiteSpace($key)) {
            Set-View -Value '未配置密钥' -Footer ("未找到凭据 {0} · 请在 DSH 中配置 API Key" -f $CredentialEnv) -Accent 'Warn'
            return
        }

        $snapshot = Get-BalanceSnapshot -Key $key -Base $BaseUrl -Preferred $Currency
        $script:LastSnapshot = $snapshot

        # 记一笔余额取样，供第 2 页算今日消费。只记成功的取数：失败分支里 Set-View 保留的
        # 是上一次的数字，把它当成新样本会把一次真实的消费凭空抹掉。
        if (-not [string]::IsNullOrWhiteSpace($SpendPath)) {
            $dayKey = Get-SpendingDayKey -Now (Get-Date) -StartHour $script:DayStartHour
            $script:Spending = Add-BalanceSample -State $script:Spending -Balance $snapshot.Total -Currency $snapshot.Currency -DayKey $dayKey
            Save-Spending -Path $SpendPath -State $script:Spending
        }

        $stamp = $snapshot.FetchedAt.ToString('HH:mm:ss')
        $amount = Format-Money -Amount $snapshot.Total -Code $snapshot.Currency
        if ($snapshot.Available) {
            Set-View -Value $amount -Footer ('{0} 已更新 · 每 {1}s 自动刷新' -f $stamp, $script:RefreshSeconds) -Accent 'Ok'
        } else {
            Set-View -Value $amount -Footer ('{0} 已更新 · 余额不足，API 可能被拒' -f $stamp) -Accent 'Warn'
        }
    } catch {
        $message = $_.Exception.Message
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $keep = '获取失败'
        if ($null -ne $script:LastSnapshot) {
            $keep = Format-Money -Amount $script:LastSnapshot.Total -Code $script:LastSnapshot.Currency
        }
        Set-View -Value $keep -Footer ('{0} 更新失败 · {1}' -f $stamp, $message) -Accent 'Error'
    } finally {
        $script:Fetching = $false
        if (-not $canvas.IsDisposed) { $canvas.Invalidate() }
    }
}

# --- 拖动与点击 -------------------------------------------------------------

$script:Dragging = $false
$script:DragStart = $null
$script:DragOrigin = $null
$script:DragMoved = $false

$canvas.Add_MouseDown({
    param($sender, $e)
   if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Dragging = $true
        $script:DragMoved = $false
        $script:DragStart = [System.Windows.Forms.Cursor]::Position
        $script:DragOrigin = $form.Location
    }
})

$canvas.Add_MouseMove({
    param($sender, $e)
    if (-not $script:Dragging) { return }
    $now = [System.Windows.Forms.Cursor]::Position
    $dx = $now.X - $script:DragStart.X
    $dy = $now.Y - $script:DragStart.Y
    # 阈值之内什么都不做：以前是先挪窗口、再判断「算不算拖动」，于是手抖 1-3px 也会把窗口
    # 挪一点点而又不算拖动——连点几次窗口就自己走位了（3px/次，实测）。
    # 现在只有真的越过阈值才开始跟着鼠标走，判定与动作一致。
    if (-not $script:DragMoved) {
        if ([Math]::Abs($dx) -le 3 -and [Math]::Abs($dy) -le 3) { return }
        $script:DragMoved = $true
    }
    $form.Location = New-Object System.Drawing.Point(($script:DragOrigin.X + $dx), ($script:DragOrigin.Y + $dy))
})

$canvas.Add_MouseUp({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $wasDrag = $script:Dragging -and $script:DragMoved
        $script:Dragging = $false
        if ($wasDrag) {
            Save-Position -Path $StatePath -X $form.Location.X -Y $form.Location.Y
            return
        }
        $point = New-Object System.Drawing.Point($e.X, $e.Y)
        if ($script:CloseRect.Contains($point)) { $form.Close(); return }
        if ($script:RefreshRect.Contains($point)) { Update-Balance; return }
       if ($script:FlipRect.Contains($point)) { Flip-Page; return }
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $script:Menu.Show($form, $e.Location)
    }
})

$canvas.Add_MouseDoubleClick({
    param($sender, $e)
   # 金额那块的双击不刷新：点两下正好来回翻一次，页面留在原地，不会顺手换到另一页。
    # 其余位置保持原来的「双击立即刷新」。
    if ($script:FlipRect.Contains((New-Object System.Drawing.Point($e.X, $e.Y)))) { return }
    Update-Balance
})

# --- 右键菜单 ---------------------------------------------------------------

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemRefresh = $script:Menu.Items.Add('立即刷新')
# 换页入口也放进菜单：三页之后「下一面是什么」没法用一句话说清，索性把三页都列出来，
# 想跳哪页点哪页；勾选跟着当前页走（见 Update-PageChecks）。
$itemPage = $script:Menu.Items.Add('页面')
# 这里用数组而不是 [ordered] 哈希：OrderedDictionary 的整数索引器是「第几项」而不是「键 2」，
# 于是 $pageItems[2] = ... 会去设置还不存在的第 3 项、当场抛 ArgumentOutOfRange，脚本在
# **建菜单**的时候就死了（窗口完全不出现）。真窗口自检抓到过，别再改回去。
$pageItems = @()
$pageSync = {
    for ($i = 0; $i -lt $pageItems.Count; $i++) { $pageItems[$i].Checked = ($script:Page -eq $i) }
}
$onPageClick = {
    param($sender, $e)
    for ($i = 0; $i -lt $pageItems.Count; $i++) {
        if ($pageItems[$i].Text -ne $sender.Text) { continue }
        Set-Page -Index $i
        return
    }
}
for ($pageIndex = 0; $pageIndex -lt $script:PageCount; $pageIndex++) {
    $entry = $itemPage.DropDownItems.Add($script:PageTitles[$pageIndex])
    $entry.Add_Click($onPageClick)
    $pageItems += $entry
}
$script:PageSync = $pageSync
& $pageSync
$itemTopMost = $script:Menu.Items.Add('始终置顶')
$itemTopMost.Checked = $true
$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$itemFaster = $script:Menu.Items.Add('每 30 秒刷新')
$itemNormal = $script:Menu.Items.Add('每 60 秒刷新')
$itemSlower = $script:Menu.Items.Add('每 5 分钟刷新')
$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# 外观子菜单按 $script:Themes 生成：加一个主题就自动多一项，不用改菜单代码。
# 所有项目共用一个处理器，靠被点中那一项的 Label 反查主题键——比在循环里逐个
# 捕获 $key（PowerShell 里要 GetNewClosure 才成立）稳当得多。
$itemTheme = $script:Menu.Items.Add('外观')
$themeItems = [ordered]@{}
$syncThemeChecks = {
    foreach ($key in $themeItems.Keys) { $themeItems[$key].Checked = ($script:ThemeName -eq $key) }
}
$onThemeClick = {
    param($sender, $e)
    foreach ($key in $script:Themes.Keys) {
        if ($script:Themes[$key].Label -ne $sender.Text) { continue }
        Set-Theme -Name $key
        & $syncThemeChecks
        Save-ThemeChoice
        Request-Repaint
        return
    }
}
foreach ($key in $script:Themes.Keys) {
    $entry = $itemTheme.DropDownItems.Add($script:Themes[$key].Label)
    $entry.Add_Click($onThemeClick)
    $themeItems[$key] = $entry
}
& $syncThemeChecks

# 「外观 → 图片」：内容在每次展开时重建，这样用户往文件夹里丢了新图不用重启。
$itemBackground = $itemTheme.DropDownItems.Add('图片')
$itemTheme.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$itemOpenFolder = $itemTheme.DropDownItems.Add('打开图片文件夹')
$itemRescan = $itemTheme.DropDownItems.Add('重新扫描图片')

$onBackgroundClick = {
    param($sender, $e)
    $wanted = [string] $sender.Text
    if ($wanted -eq '（不使用图片）') {
        [void] (Set-Background -Path '')
    } else {
        $hit = Get-BackgroundFiles | Where-Object { $_.Name -eq $wanted } | Select-Object -First 1
        if ($null -eq $hit) { return }
        [void] (Set-Background -Path $hit.Path)
    }
    Save-ThemeChoice
    Request-Repaint
}

$rebuildBackgroundMenu = {
    $itemBackground.DropDownItems.Clear()
    $none = $itemBackground.DropDownItems.Add('（不使用图片）')
    $none.Checked = [string]::IsNullOrEmpty($script:BackgroundName)
    $none.Add_Click($onBackgroundClick)

    $files = @(Get-BackgroundFiles)
    if ($files.Count -gt 0) {
        $itemBackground.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
        foreach ($file in $files) {
            $entry = $itemBackground.DropDownItems.Add($file.Name)
            $entry.Checked = ($script:BackgroundName -eq $file.Name)
            $entry.Add_Click($onBackgroundClick)
        }
    } else {
        $hint = $itemBackground.DropDownItems.Add('（文件夹里还没有图片）')
        $hint.Enabled = $false
    }
}
$itemBackground.DropDown.Add_Opening({ & $rebuildBackgroundMenu })
& $rebuildBackgroundMenu

$itemOpenFolder.Add_Click({
    if ([string]::IsNullOrWhiteSpace($BackgroundDir)) { return }
    Initialize-BackgroundFolder
    try { Start-Process explorer.exe -ArgumentList "`"$BackgroundDir`"" } catch { }
})
$itemRescan.Add_Click({ & $rebuildBackgroundMenu })

# 「外观 → 蒙版」：调图片上那层蒙版的浓淡。只有选了背景图才有观感差异，
# 但一直可用——先调好再选图也顺。
$itemScrim = $itemTheme.DropDownItems.Add('蒙版浓度')
$scrimItems = [ordered]@{}
$syncScrimChecks = {
    foreach ($key in $scrimItems.Keys) { $scrimItems[$key].Checked = ($script:ScrimName -eq $key) }
}
$onScrimClick = {
    param($sender, $e)
    foreach ($key in $script:ScrimLevels.Keys) {
        if ($script:ScrimLevels[$key].Label -ne $sender.Text) { continue }
        Set-Scrim -Name $key
        & $syncScrimChecks
        Save-ThemeChoice
        return
    }
}
foreach ($key in $script:ScrimLevels.Keys) {
    $entry = $itemScrim.DropDownItems.Add($script:ScrimLevels[$key].Label)
    $entry.Add_Click($onScrimClick)
    $scrimItems[$key] = $entry
}
& $syncScrimChecks

$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$itemTopUp = $script:Menu.Items.Add('打开充值页')
$itemClose = $script:Menu.Items.Add('关闭小窗')

$syncIntervalChecks = {
    $itemFaster.Checked = ($script:RefreshSeconds -eq 30)
    $itemNormal.Checked = ($script:RefreshSeconds -eq 60)
    $itemSlower.Checked = ($script:RefreshSeconds -eq 300)
}
$itemRefresh.Add_Click({ Update-Balance })
$itemPage.Add_Click({ Flip-Page })
$itemTopMost.Add_Click({ $form.TopMost = $itemTopMost.Checked })
$setInterval = {
    param($seconds)
    $script:RefreshSeconds = $seconds
    $script:Timer.Interval = $seconds * 1000
    & $syncIntervalChecks
    Update-Balance
}
$itemFaster.Add_Click({ & $setInterval 30 })
$itemNormal.Add_Click({ & $setInterval 60 })
$itemSlower.Add_Click({ & $setInterval 300 })
$itemTopUp.Add_Click({ Start-Process 'https://platform.deepseek.com/top_up' })
$itemClose.Add_Click({ $form.Close() })
$script:Menu.Add_Opening({
    & $syncIntervalChecks
    & $syncThemeChecks
    Update-PageChecks
})
& $syncIntervalChecks
Update-PageChecks

# --- 托盘 -------------------------------------------------------------------
#
# × 不是「退出」，而是收进托盘：小窗是常驻配件，误关一次不该逼用户重启 DSH。
# 真要结束进程，走托盘右键菜单里的「退出小窗」。托盘图标也可以随时把窗口叫回来。

$script:AllowClose = $false   # 只有真正要退出时才置真，其余一律被 FormClosing 拦成隐藏
$script:BalloonShown = $false

function New-TrayIcon {
    # 画一个和卡片同色系的小图标：深色圆底 + 绿色状态点 + 白色 ¥。
    try {
        $size = 32
        $bmp = New-Object System.Drawing.Bitmap($size, $size)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::Transparent)
        $bg = New-Object System.Drawing.SolidBrush($script:Palette.Card)
        $g.FillEllipse($bg, 0, 0, ($size - 1), ($size - 1))
        $dot = New-Object System.Drawing.SolidBrush($script:Palette.Ok)
        $g.FillEllipse($dot, 20, 20, 10, 10)
        $font = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 15.0, [System.Drawing.FontStyle]::Bold)
        $g.DrawString('¥', $font, [System.Drawing.Brushes]::White, 2, 2)
        $g.Dispose()
        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
        $bmp.Dispose()
        return $icon
    } catch {
        return [System.Drawing.SystemIcons]::Application
    }
}

function Show-BalanceWindow {
    if (-not $form.Visible) { $form.Show() }
    $form.TopMost = $true
    $form.Activate()
    $form.BringToFront()
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray = $tray   # 换主题时要重画托盘图标
$tray.Icon = New-TrayIcon
$tray.Text = 'DeepSeek 余额'
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayShow = $trayMenu.Items.Add('显示余额小窗')
$trayRefresh = $trayMenu.Items.Add('立即刷新')
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$trayExit = $trayMenu.Items.Add('退出小窗')
$trayShow.Add_Click({ Show-BalanceWindow })
$trayRefresh.Add_Click({ Update-Balance })
$trayExit.Add_Click({
    $script:AllowClose = $true
    $script:Running = $false
    $form.Close()
})
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseDoubleClick({ Show-BalanceWindow })

# 隐藏与显示都不该让定时器停摆：窗口收着的时候余额与用量照常刷新，叫回来就是新的。
$form.Add_FormClosing({
    param($sender, $e)
    if ($script:AllowClose) { return }
    $e.Cancel = $true
    $form.Hide()
    if (-not $script:BalloonShown) {
        $script:BalloonShown = $true
        try {
            $tray.ShowBalloonTip(4000, 'DeepSeek 余额', '已收进托盘，双击图标即可重新显示；要彻底关掉请用托盘菜单里的「退出小窗」。', [System.Windows.Forms.ToolTipIcon]::Info)
        } catch {
            # 气泡通知失败不影响收托盘本身。
        }
    }
})

# --- 定时器 -----------------------------------------------------------------

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:RefreshSeconds * 1000
$script:Timer.Add_Tick({ Update-Balance })
$script:Timer.Start()

# token 用量走独立的高频轮询：它由宿主插件写文件驱动，和余额的抓取频率无关。
$usageTimer = New-Object System.Windows.Forms.Timer
$usageTimer.Interval = 2000
$usageTimer.Add_Tick({
    Update-UsageView
    # 第 3 页的倒计时也靠这一跳走字；只有文字真的变了才会重绘。
    Update-PricingView
})
$usageTimer.Start()

$watchdog = New-Object System.Windows.Forms.Timer
$watchdog.Interval = 2000
$watchdog.Add_Tick({
    if ($ParentPid -le 0) { return }
    $alive = $true
    try {
        $null = [System.Diagnostics.Process]::GetProcessById($ParentPid)
    } catch {
        $alive = $false
    }
    if (-not $alive) {
        # DSH 没了就真退出，不能只是收进托盘——否则桌面上会留下一个叫不回来的图标。
        $script:AllowClose = $true
        $script:Running = $false
        $script:Timer.Stop()
        $usageTimer.Stop()
        $watchdog.Stop()
        $form.Close()
    }
})
$watchdog.Start()

$form.Add_Shown({
    Update-UsageView
    Update-PricingView
    Update-Balance
})
$form.Add_FormClosed({
    $script:Timer.Stop()
    $usageTimer.Stop()
    $watchdog.Stop()
    $tray.Visible = $false
    $tray.Dispose()
})

# --- 自检模式 ---------------------------------------------------------------
#
# 「点 × 只是收进托盘」这条逻辑没法用单测覆盖（它走的是真实的 Windows 消息与
# FormClosing 管线），所以留一个开关：把界面跑起来，走一遍「点 × → 收托盘 → 再从托盘
# 叫回来」，把判定打到 stdout 供 tests/tray.test.mjs 断言。
#
# 判定必须走 [Console]::Out：WinForms 事件处理器里 Write-Output 的输出没有任何管道接收，
# 会被静默丢掉（这个坑先让自检「看起来」失败过一次）。
function Write-SelfTest {
    param([string] $Message)
    [Console]::Out.WriteLine($Message)
    [Console]::Out.Flush()
}

if ($SelfTest) {
    $script:SelfTestStage = 0
    $script:SelfTestExit = $null
    $selfTestTimer = New-Object System.Windows.Forms.Timer
    $selfTestTimer.Interval = 1200
    $selfTestTimer.Add_Tick({
        if ($script:SelfTestStage -eq 0) {
            $script:SelfTestStage = 1
            $form.Close()             # 模拟用户点 ×
            return
        }
        if ($script:SelfTestStage -eq 1) {
            $hidden = -not $form.Visible
            $alive = -not $form.IsDisposed
            $trayOk = $tray.Visible
            if (-not ($hidden -and $alive -and $trayOk)) {
                Write-SelfTest ("SELFTEST FAIL: 点 × 没有变成收托盘（hidden={0} alive={1} tray={2}）" -f $hidden, $alive, $trayOk)
                $script:SelfTestExit = 1
                $script:SelfTestStage = 9
                return
            }
            $script:SelfTestStage = 2
            $trayShow.PerformClick()  # 模拟点托盘菜单里的「显示余额小窗」
            return
        }
        if ($script:SelfTestStage -eq 2) {
            if (-not $form.Visible) {
                Write-SelfTest 'SELFTEST FAIL: 托盘菜单没有把窗口叫回来'
                $script:SelfTestExit = 1
                $script:SelfTestStage = 9
                return
            }
            # 顺带验一遍换主题：点菜单项、确认调色板真的换了、并且记进了 state.json。
            $script:SelfTestThemeBefore = $script:ThemeName
            $themeItems['teal'].PerformClick()
            $script:SelfTestStage = 3
            return
        }
        if ($script:SelfTestStage -eq 3) {
            $problems = @()
            if ($script:ThemeName -ne 'teal') { $problems += "点主题菜单后 ThemeName=$($script:ThemeName)" }
            if ($script:Palette.Card -eq (ConvertTo-ThemeColor $script:Themes['navy'].Card) -and $script:SelfTestThemeBefore -ne 'teal') {
                $problems += '调色板没有跟着换'
            }
            $savedState = $null
            if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath)) {
                $savedState = ([System.IO.File]::ReadAllText($StatePath)) | ConvertFrom-Json
            }
            if ($null -eq $savedState -or [string] $savedState.theme -ne 'teal') {
                $problems += "state.json 里记的主题是 '$(if ($null -ne $savedState) { [string] $savedState.theme })'"
            }

            # 再验一遍背景图：文件夹里有图时必须能选中、载入、并记进 state.json。
            $files = @(Get-BackgroundFiles)
            if ($files.Count -eq 0) {
                Write-SelfTest 'SELFTEST SKIP-BACKGROUND: 背景文件夹里没有图片'
            } else {
                & $rebuildBackgroundMenu
                $wanted = $files[0].Name
                $entry = $itemBackground.DropDownItems | Where-Object { $_.Text -eq $wanted } | Select-Object -First 1
                if ($null -eq $entry) {
                    $problems += "背景菜单里没有列出 '$wanted'"
                } else {
                    $entry.PerformClick()
                    if ($script:BackgroundName -ne $wanted) { $problems += "选了 '$wanted' 但 BackgroundName='$($script:BackgroundName)'" }
                    if ($null -eq $script:BackgroundImage) {
                        $problems += '背景图没有被载入'
                    } else {
                        # 大图必须被缩下来：否则 4K 壁纸会整张常驻内存、每次重绘现缩一遍。
                        $capW = (Px 276) * 2 + 1
                        $capH = (Px 118) * 2 + 1
                        if ($script:BackgroundImage.Width -gt $capW -and $script:BackgroundImage.Height -gt $capH) {
                            $problems += "背景图没被缩放：$($script:BackgroundImage.Width)x$($script:BackgroundImage.Height)"
                        }
                    }
                    # 点完会重写 state.json，所以这里要重新读一次。
                    $afterState = $null
                    if (Test-Path -LiteralPath $StatePath) {
                        $afterState = ([System.IO.File]::ReadAllText($StatePath)) | ConvertFrom-Json
                    }
                    if ($null -eq $afterState -or [string] $afterState.background -ne $wanted) {
                        $problems += "state.json 里记的背景是 '$($afterState.background)'"
                    }
                }
            }

            if ($problems.Count -eq 0) {
                # 最后验一遍蒙版浓度：换档要同时改 alpha、重建画刷、并记进 state.json。
                $scrimItems['none'].PerformClick()
                if ($script:ScrimAlpha -ne 0) { $problems += "选「无」后 ScrimAlpha=$($script:ScrimAlpha)" }
                if ($null -ne $script:Brushes['Scrim'] -and $script:Brushes['Scrim'].Color.A -ne 0) {
                    $problems += "蒙版画刷没跟着重建（A=$($script:Brushes['Scrim'].Color.A)）"
                }
                $afterScrim = $null
                if (Test-Path -LiteralPath $StatePath) {
                    $afterScrim = ([System.IO.File]::ReadAllText($StatePath)) | ConvertFrom-Json
                }
                if ($null -eq $afterScrim -or [string] $afterScrim.scrim -ne 'none') {
                    $problems += "state.json 里记的蒙版是 '$($afterScrim.scrim)'"
                }
            }

            # 最后验一遍换页：三页要能一路翻过去再绕回来，菜单能直接跳、勾选跟着走。
            # 「点金额区域换页」走的是真实鼠标消息，自检里不便合成，这里用同一个入口
            # （Flip-Page）验逻辑；鼠标命中区域另行用真窗口点击验证过。
            #
            # 整段包 try/catch：自检最怕的不是失败，而是「卡在某一阶段却什么线索都没有」——
            # 这里真出过一次，现象只有一句「未能完成」。异常一律转成问题条目报出来。
            try {
                if ($script:Page -ne 0) { $problems += "起始不在第 1 页（Page=$($script:Page)）" }
                foreach ($expected in @(1, 2, 0)) {
                    Flip-Page
                    if ($script:Page -ne $expected) { $problems += "翻页后落在 Page=$($script:Page)，期望 $expected" }
                }
                $pageItems[2].PerformClick()
                if ($script:Page -ne 2) { $problems += "点菜单「计费时段」后 Page=$($script:Page)" }
                if (-not $pageItems[2].Checked) { $problems += '菜单勾选没跟着当前页走' }
                if ($pageItems[0].Checked) { $problems += '第 1 项的勾没取消' }
                $pageItems[0].PerformClick()
                if ($script:Page -ne 0) { $problems += "点菜单「余额」后 Page=$($script:Page)" }
                if (-not $pageItems[0].Checked) { $problems += '跳回第 1 页后勾选没更新' }
            } catch {
                $problems += "换页自检抛异常：$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
            }

            if ($problems.Count -eq 0) {
                Write-SelfTest 'SELFTEST PASS: × 收进托盘 / 托盘菜单叫回来 / 换主题 / 换背景图 / 调蒙版并记住 / 三页循环与菜单跳转'
                $script:SelfTestExit = 0
            } else {
                Write-SelfTest ('SELFTEST FAIL: ' + ($problems -join '；'))
                $script:SelfTestExit = 1
            }
            $script:SelfTestStage = 9
            return
        }
        $selfTestTimer.Stop()
        $script:AllowClose = $true
        $script:Running = $false
        $form.Close()
    })
    $selfTestTimer.Start()
}

# 消息循环用「DoEvents + 短睡」手工泵，不用 Application.Run，也不用 ShowDialog：
#   - ShowDialog 的模态循环在窗体变「不可见」时就会结束，于是「× 收进托盘」会顺手把
#     进程一起结束掉（这条是自检抓出来的）；
#   - Application.Run 在这个宿主里会立刻返回（An empty ApplicationContext 也一样），
#     压根泵不起来（实测）。
# 手工泵没有这两个毛病：隐藏窗口不影响循环，WinForms 定时器照常触发。
$script:Running = $true
try {
    $form.Show()
    while ($script:Running) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 15
    }
} catch {
    # 自检模式下把异常打出来：finally 里的 exit 会把异常吞掉，看不到就没法查。
    if ($SelfTest) {
        Write-SelfTest ("SELFTEST EXCEPTION: {0} @ {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
        if ($null -eq $script:SelfTestExit) { $script:SelfTestExit = 1 }
    } else {
        throw
    }
} finally {
    if ($SelfTest) {
        if ($null -eq $script:SelfTestExit) { Write-SelfTest 'SELFTEST FAIL: 自检未能在窗口存活期间完成'; $script:SelfTestExit = 1 }
        exit $script:SelfTestExit
    }
    try {
        $tray.Visible = $false
        $tray.Dispose()
    } catch {
        # FormClosed 已经收过托盘，重复释放失败可以忽略。
    }
    $form.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
