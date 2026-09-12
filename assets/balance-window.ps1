<#
.SYNOPSIS
  dsh-api-balance 的桌面小窗：一个无边框、置顶的迷你窗口，显示 DeepSeek API 账户余额。

.DESCRIPTION
  由 dsh-api-balance 宿主插件在 DSH 启动时拉起。本脚本自己读取 API Key（进程环境变量
  或 $DSH_HOME/.credentials.yaml），周期调用 GET {BaseUrl}/user/balance，并把结果画在
  小窗上；不经过 DSH 的 IPC，密钥也不出现在命令行里。

  小窗显示两行数据，来源彼此独立：
    - 余额：本脚本自己调 DeepSeek 接口取；
    - 本次开机消耗的 token：宿主插件写进 UsagePath 的那份 JSON，本脚本每 2 秒读一次。
  两个文件归属分明：StatePath 只由本脚本写（窗口位置），UsagePath 只由插件写。

  窗口行为：
    - 左键拖动移动窗口，位置写回 StatePath，下次启动回到原处；
    - × 不是退出，而是收进托盘；托盘图标双击可重新显示，右键菜单可刷新或真正退出；
    - 双击或右键菜单可立即刷新；右键菜单还能改刷新间隔、取消置顶、关闭；
    - 看门狗每隔几秒检查 ParentPid，DSH 一退出（含被强杀）窗口连同托盘图标一起消失；
    - 命名互斥量保证同一时刻只有一个余额小窗。

  诊断模式：
    - -Probe 只抓一次余额并打印 JSON，不创建任何窗口；
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
    [string] $Currency       = '',
    [string] $Corner         = 'top-right',
    [int]    $ParentPid      = 0,
    [string] $StatePath      = '',
    [string] $UsagePath      = '',
    [string] $BackgroundDir  = '',
    [string] $Theme          = 'navy',
    [string] $Scrim          = 'medium',
    [string] $InstanceName   = 'DshApiBalanceWindow',
    [switch] $Probe,
    [switch] $SelfTest
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
if (-not $hasHandle) { exit 0 }

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
    Usage  = '本次开机 统计中…'
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
# 两条数据各自独立刷新。
function Update-UsageView {
    $usage = Read-UsageFile -Path $UsagePath
    if ($null -eq $usage) {
        $next = '本次开机 暂无数据'
    } else {
        $text = $usage.TotalText
        if ([string]::IsNullOrWhiteSpace($text)) { $text = ('{0:N0}' -f $usage.Total) }
        $next = '本次开机 {0} tokens' -f $text
    }
    # 这一行每 2 秒被读一次，但数字多数时候没变；没变就一个字都不画。
    if ($script:View.Usage -eq $next) { return }
    $script:View.Usage = $next
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
    $accent = $script:Brushes[$view['Accent']]
    if ($null -ne $accent) { $g.FillEllipse($accent, (Px 16), (Px 16), (Px 7), (Px 7)) }
    $g.DrawString($view['Title'], $script:Fonts['Title'], $script:Brushes.Title, (Px 30), (Px 11))

    $script:RefreshRect = New-Object System.Drawing.Rectangle(($w - (Px 62)), (Px 7), (Px 32), (Px 22))
    $script:CloseRect = New-Object System.Drawing.Rectangle(($w - (Px 29)), (Px 7), (Px 22), (Px 22))
    $g.DrawString('刷新', $script:Fonts.Button, $script:Brushes.Muted, ($w - (Px 60)), (Px 12))
    $g.DrawString('×', $script:Fonts.Close, $script:Brushes.Muted, ($w - (Px 26)), (Px 7))

    $g.DrawString($view['Value'], $script:Fonts['Value'], $script:Brushes.Value, (Px 14), (Px 28))

    # token 行：数字已在宿主侧压成「141.6K」这种短文本，这里只负责拼句子。
    if ($view['Usage'] -ne '') {
        $g.DrawString($view['Usage'], $script:Fonts['Usage'], $script:Brushes.Sub, (Px 17), (Px 66))
    }
    if (-not [string]::IsNullOrWhiteSpace($view['Footer'])) {
        $footer = Get-FittedText -Graphics $g -Text $view['Footer'] -Font $script:Fonts['Footer'] -MaxWidth ($w - (Px 34))
        $g.DrawString($footer, $script:Fonts['Footer'], $script:Brushes.Muted, (Px 17), (Px 88))
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
    if ([Math]::Abs($dx) -gt 3 -or [Math]::Abs($dy) -gt 3) { $script:DragMoved = $true }
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
    } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        $script:Menu.Show($form, $e.Location)
    }
})

$canvas.Add_MouseDoubleClick({
    param($sender, $e)
    Update-Balance
})

# --- 右键菜单 ---------------------------------------------------------------

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemRefresh = $script:Menu.Items.Add('立即刷新')
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
})
& $syncIntervalChecks

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
$usageTimer.Add_Tick({ Update-UsageView })
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

            if ($problems.Count -eq 0) {
                Write-SelfTest 'SELFTEST PASS: × 收进托盘 / 托盘菜单叫回来 / 换主题 / 换背景图 / 调蒙版并记住'
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
