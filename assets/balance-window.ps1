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
    - 双击或右键菜单可立即刷新；右键菜单还能改刷新间隔、取消置顶、关闭；
    - 看门狗每隔几秒检查 ParentPid，DSH 一退出（含被强杀）窗口自行关闭，不留孤儿进程；
    - 命名互斥量保证同一时刻只有一个余额小窗。

  诊断模式：-Probe 只抓一次余额并打印 JSON，不创建任何窗口，供自动化测试使用。

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
    [string] $InstanceName   = 'DshApiBalanceWindow',
    [switch] $Probe
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # 老系统上枚举不存在时忽略：Invoke-RestMethod 会用系统默认协议。
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

$script:Palette = @{
    Card   = [System.Drawing.Color]::FromArgb(255, 26, 30, 40)
    Border = [System.Drawing.Color]::FromArgb(255, 58, 65, 82)
    Title  = [System.Drawing.Color]::FromArgb(255, 158, 168, 190)
    Value  = [System.Drawing.Color]::FromArgb(255, 242, 245, 250)
    Sub    = [System.Drawing.Color]::FromArgb(255, 140, 151, 172)
    Muted  = [System.Drawing.Color]::FromArgb(255, 116, 126, 148)
    Ok     = [System.Drawing.Color]::FromArgb(255, 74, 222, 128)
    Warn   = [System.Drawing.Color]::FromArgb(255, 251, 191, 36)
    Error  = [System.Drawing.Color]::FromArgb(255, 248, 113, 113)
}

$script:Fonts = @{
    Title  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 9.0, [System.Drawing.FontStyle]::Regular)
    Value  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 23.0, [System.Drawing.FontStyle]::Bold)
    Usage  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 9.0, [System.Drawing.FontStyle]::Regular)
    Footer = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 8.0, [System.Drawing.FontStyle]::Regular)
    Button = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 8.5, [System.Drawing.FontStyle]::Regular)
    Close  = [System.Drawing.Font]::new('Microsoft YaHei UI', [single] 12.0, [System.Drawing.FontStyle]::Regular)
}

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
}

$script:View = @{
    Title  = 'DeepSeek 余额'
    Value  = '正在获取…'
    Usage  = '本次开机 统计中…'
    Footer = ''
    Accent = $script:Brushes.Muted
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

function Set-View {
    param([string] $Value, [string] $Footer, $Accent)
    $script:View.Value = $Value
    $script:View.Footer = $Footer
    if ($null -ne $Accent) { $script:View.Accent = $Accent }
    if ($null -ne $script:Canvas -and -not $script:Canvas.IsDisposed) { $script:Canvas.Invalidate() }
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
        $script:View.Usage = '本次开机 暂无数据'
    } else {
        $text = $usage.TotalText
        if ([string]::IsNullOrWhiteSpace($text)) { $text = ('{0:N0}' -f $usage.Total) }
        $script:View.Usage = '本次开机 {0} tokens' -f $text
    }
    if ($null -ne $script:Canvas -and -not $script:Canvas.IsDisposed) { $script:Canvas.Invalidate() }
}

function Read-SavedPosition {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $obj = ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
        if ($null -eq $obj.x -or $null -eq $obj.y) { return $null }
        return @{ X = [int] $obj.x; Y = [int] $obj.y }
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
        $payload = @{ x = $X; y = $Y; savedAt = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($Path, $payload)
    } catch {
        # 位置记忆失败不影响主功能。
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

$width = 276
$height = 118
$radius = 14

$form = New-Object System.Windows.Forms.Form
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
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$margin = 18
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

$canvas = New-Object System.Windows.Forms.Panel
$canvas.Dock = [System.Windows.Forms.DockStyle]::Fill
$canvas.BackColor = $script:Palette.Card
$script:Canvas = $canvas
$form.Controls.Add($canvas)

$canvas.Add_Paint({
    param($sender, $e)

    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

    $w = $sender.Width
    $h = $sender.Height

    $borderPath = New-RoundedPath -Width $w -Height $h -Radius 14
    $g.DrawPath($script:Brushes.Border, $borderPath)

    $view = $script:View
    $g.FillEllipse($view['Accent'], 16, 16, 7, 7)
    $g.DrawString($view['Title'], $script:Fonts['Title'], $script:Brushes.Title, 30, 11)

    $script:RefreshRect = New-Object System.Drawing.Rectangle(($w - 62), 7, 32, 22)
    $script:CloseRect = New-Object System.Drawing.Rectangle(($w - 29), 7, 22, 22)
    $g.DrawString('刷新', $script:Fonts.Button, $script:Brushes.Muted, ($w - 60), 12)
    $g.DrawString('×', $script:Fonts.Close, $script:Brushes.Muted, ($w - 26), 7)

    $g.DrawString($view['Value'], $script:Fonts['Value'], $script:Brushes.Value, 14, 28)

    # token 行：数字已在宿主侧压成「141.6K」这种短文本，这里只负责拼句子。
    if ($view['Usage'] -ne '') {
        $g.DrawString($view['Usage'], $script:Fonts['Usage'], $script:Brushes.Sub, 17, 66)
    }
    if (-not [string]::IsNullOrWhiteSpace($view['Footer'])) {
        $footer = Get-FittedText -Graphics $g -Text $view['Footer'] -Font $script:Fonts['Footer'] -MaxWidth ($w - 34)
        $g.DrawString($footer, $script:Fonts['Footer'], $script:Brushes.Muted, 17, 88)
    }

    $borderPath.Dispose()
})

function Update-Balance {
    if ($script:Fetching) { return }
    $script:Fetching = $true
    Set-View -Value '正在获取…' -Footer '正在读取账户余额' -Accent $script:Brushes.Muted
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $key = Get-ApiKey -EnvName $CredentialEnv -File $CredentialFile
        if ([string]::IsNullOrWhiteSpace($key)) {
            Set-View -Value '未配置密钥' -Footer ("未找到凭据 {0} · 请在 DSH 中配置 API Key" -f $CredentialEnv) -Accent $script:Brushes.Warn
            return
        }

        $snapshot = Get-BalanceSnapshot -Key $key -Base $BaseUrl -Preferred $Currency
        $script:LastSnapshot = $snapshot
        $stamp = $snapshot.FetchedAt.ToString('HH:mm:ss')
        $amount = Format-Money -Amount $snapshot.Total -Code $snapshot.Currency
        if ($snapshot.Available) {
            Set-View -Value $amount -Footer ('{0} 已更新 · 每 {1}s 自动刷新' -f $stamp, $script:RefreshSeconds) -Accent $script:Brushes.Ok
        } else {
            Set-View -Value $amount -Footer ('{0} 已更新 · 余额不足，API 可能被拒' -f $stamp) -Accent $script:Brushes.Warn
        }
    } catch {
        $message = $_.Exception.Message
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $keep = '获取失败'
        if ($null -ne $script:LastSnapshot) {
            $keep = Format-Money -Amount $script:LastSnapshot.Total -Code $script:LastSnapshot.Currency
        }
        Set-View -Value $keep -Footer ('{0} 更新失败 · {1}' -f $stamp, $message) -Accent $script:Brushes.Error
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
$script:Menu.Add_Opening({ & $syncIntervalChecks })
& $syncIntervalChecks

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
})

try {
    [void] $form.ShowDialog()
} finally {
    $form.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
