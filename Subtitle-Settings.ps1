$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$SettingsLogDir = Join-Path $Root 'logs'
if (-not (Test-Path -LiteralPath $SettingsLogDir -PathType Container)) { New-Item -ItemType Directory -Path $SettingsLogDir -Force | Out-Null }
$SettingsLog = Join-Path $SettingsLogDir ("subtitle_settings_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
function Write-SubtitleSettingsLog([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { [IO.File]::AppendAllText($SettingsLog, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($true)) } catch {}
}
function Test-ParaformerWorkerReady([ref]$Reason) {
    $Reason.Value = ''
    $missing = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $ParaformerPython -PathType Leaf)) {
        [void]$missing.Add('运行环境：tools\paraformer\runtime\python.exe')
    }
    foreach ($modelName in @('iic--speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch', 'iic--speech_fsmn_vad_zh-cn-16k-common-pytorch', 'iic--punc_ct-transformer_cn-en-common-vocab471067-large')) {
        $modelFile = Join-Path $ParaformerModelCache ("models\$modelName\snapshots\master\model.pt")
        if (-not (Test-Path -LiteralPath $modelFile -PathType Leaf)) {
            [void]$missing.Add("模型：$modelName\snapshots\master\model.pt")
        }
    }
    if ($missing.Count -gt 0) {
        $Reason.Value = $missing -join [Environment]::NewLine
        return $false
    }
    $stdout = Join-Path ([IO.Path]::GetTempPath()) ("paraformer_ready_$PID.out")
    $stderr = Join-Path ([IO.Path]::GetTempPath()) ("paraformer_ready_$PID.err")
    $previousModelScopeCache = $env:MODELSCOPE_CACHE
    try {
        $env:MODELSCOPE_CACHE = $ParaformerModelCache
        $process = Start-Process -FilePath $ParaformerPython -ArgumentList @($ParaformerWorker, '--warmup') -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $stderrText = if (Test-Path -LiteralPath $stderr) { [IO.File]::ReadAllText($stderr, [Text.UTF8Encoding]::new($false)).Trim() } else { '' }
        $script:ParaformerReadyNotice = if ($stderrText -match 'PARAFORMER_DEVICE_FALLBACK=cpu') { '显卡不兼容，已切换 CPU（可正常使用）' } else { '' }
        Write-SubtitleSettingsLog "PARAFORMER_READY_CHECK: exit=$($process.ExitCode); stderr=$stderrText"
        if ($process.ExitCode -eq 0) { return $true }
        $Reason.Value = if ($stderrText) { "退出码：$($process.ExitCode)；$stderrText" } else { "退出码：$($process.ExitCode)" }
        return $false
    } catch {
        $Reason.Value = $_.Exception.Message
        return $false
    } finally {
        if ($null -eq $previousModelScopeCache) { Remove-Item Env:MODELSCOPE_CACHE -ErrorAction SilentlyContinue }
        else { $env:MODELSCOPE_CACHE = $previousModelScopeCache }
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
    }
}
trap {
    Write-SubtitleSettingsLog ("FAILED: " + $_.Exception.Message)
    try { [Windows.Forms.MessageBox]::Show("字幕设置无法启动。请查看：$SettingsLog", '字幕设置错误') | Out-Null } catch {}
    exit 1
}
Write-SubtitleSettingsLog 'START'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SubtitleSettingsWindowHost {
    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static void HideConsole() {
        IntPtr console = GetConsoleWindow();
        if (console != IntPtr.Zero) ShowWindow(console, 0);
    }
}
'@
[SubtitleSettingsWindowHost]::HideConsole()
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class FontGlyphProbe {
    private const uint GGI_MARK_NONEXISTING_GLYPHS = 1;
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetGlyphIndices(IntPtr hdc, string text, int count, ushort[] glyphs, uint flags);
    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr obj);

    public static bool SupportsText(Font font, string text) {
        using (var bitmap = new Bitmap(1, 1))
        using (var graphics = Graphics.FromImage(bitmap)) {
            IntPtr hdc = graphics.GetHdc();
            IntPtr hfont = font.ToHfont();
            IntPtr old = SelectObject(hdc, hfont);
            try {
                var glyphs = new ushort[text.Length];
                uint result = GetGlyphIndices(hdc, text, text.Length, glyphs, GGI_MARK_NONEXISTING_GLYPHS);
                if (result == 0xFFFFFFFF) return false;
                foreach (ushort glyph in glyphs) if (glyph == 0xFFFF) return false;
                return true;
            } finally {
                SelectObject(hdc, old);
                DeleteObject(hfont);
                graphics.ReleaseHdc(hdc);
            }
        }
    }
}
'@

$ConfigPath = Join-Path $Root 'config.ps1'
$FontDir = Join-Path $Root 'fonts'
$ConfigDir = Join-Path $Root 'config'
$WorkDirForPreview = Join-Path ([IO.Path]::GetTempPath()) ("autocut_preview_{0}" -f $PID)
$Ffmpeg = Join-Path $Root 'tools\ffmpeg\bin\ffmpeg.exe'
$PreviewWorker = Join-Path $Root 'Subtitle-Preview-Worker.ps1'
$CoreModule = Join-Path $Root 'Subtitle-Core.psm1'
$AliyunModule = Join-Path $Root 'Subtitle-Aliyun.psm1'
$ParaformerRoot = Join-Path $Root 'tools\paraformer'
$ParaformerSetup = Join-Path $ParaformerRoot 'Setup-Paraformer.ps1'
$ParaformerWorker = Join-Path $ParaformerRoot 'paraformer_worker.py'
$ParaformerPython = Join-Path $ParaformerRoot 'runtime\python.exe'
$ParaformerModelCache = Join-Path $ParaformerRoot 'model_cache'
$ParaformerProgress = Join-Path $SettingsLogDir 'paraformer_setup_progress.json'
$VideoExts = @('.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v')

if ($env:HUNJIAN_LOCAL_PARAFORMER_CHECK -eq '1') {
    $checkReason = ''
    $checkReady = Test-ParaformerWorkerReady ([ref]$checkReason)
    [pscustomobject]@{
        Ready = $checkReady
        Message = if ($checkReady) { '本地模型已就绪，无需下载' + $(if ($script:ParaformerReadyNotice) { '；' + $script:ParaformerReadyNotice } else { '' }) } else { $checkReason }
        SetupStarted = $false
    } | ConvertTo-Json -Compress
    exit $(if ($checkReady) { 0 } else { 2 })
}

Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $AliyunModule -Force -DisableNameChecking

foreach ($dir in @($FontDir, $ConfigDir, $WorkDirForPreview)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

function Read-ConfigValues {
    . $ConfigPath
    return [ordered]@{
        VideoDir = $VideoDir
        WorkDir = if ($WorkDir) { $WorkDir } else { Join-Path $Root 'work' }
        SubtitleFontName = if ($SubtitleFontName) { $SubtitleFontName } else { 'Microsoft YaHei' }
        SubtitleFontFile = if ($SubtitleFontFile) { $SubtitleFontFile } else { '' }
        SubtitleFontSize = if ($SubtitleFontSize) { [int]$SubtitleFontSize } else { 16 }
        SubtitleColor = if ($SubtitleColor) { $SubtitleColor } else { 'FFFFFF' }
        SubtitleOutlineColor = if ($SubtitleOutlineColor) { $SubtitleOutlineColor } else { '000000' }
        SubtitleOutline = if ($null -ne $SubtitleOutline) { [int]$SubtitleOutline } else { 2 }
        SubtitleMaxCharsPerLine = if ($null -ne $SubtitleMaxCharsPerLine) { [int]$SubtitleMaxCharsPerLine } else { 0 }
        SubtitleMinChars = if ($SubtitleMinChars) { [int]$SubtitleMinChars } else { 6 }
        SubtitleSourceMode = if ($SubtitleSourceMode -in @('paraformer_local', 'aliyun_only', 'aliyun_fallback', 'text_preferred')) { $SubtitleSourceMode } else { 'paraformer_local' }
        SubtitleSafeWidthPercent = 94
        SubtitleMarginVPortrait = if ($null -ne $SubtitleMarginVPortrait) { [int]$SubtitleMarginVPortrait } else { 30 }
        SubtitleMarginVLandscape = if ($null -ne $SubtitleMarginVLandscape) { [int]$SubtitleMarginVLandscape } else { 30 }
        AliyunModel = if ($AliyunModel) { $AliyunModel } else { 'paraformer-v2' }
        AliyunEndpoint = if ($AliyunEndpoint) { $AliyunEndpoint } else { 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription' }
    }
}

function ConvertTo-PsLiteral($Value) {
    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return ([string]$Value) }
    return "'{0}'" -f (([string]$Value) -replace "'", "''")
}

function Set-ConfigValue($Text, $Name, $Value) {
    $pattern = '(?m)^\s*\$' + [regex]::Escape($Name) + '\s*=.*$'
    $line = '$' + $Name + ' = ' + (ConvertTo-PsLiteral $Value)
    if ($Text -match $pattern) { return [regex]::Replace($Text, $pattern, $line) }
    return $Text.TrimEnd() + "`r`n$line`r`n"
}

function Save-SubtitleConfig($Values) {
    $backupDir = Join-Path $Root 'banbenbeifen'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDir ("config_before_subtitle_{0}.ps1" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))) -Force
    $text = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8)
    foreach ($entry in $Values.GetEnumerator()) { $text = Set-ConfigValue $text $entry.Key $entry.Value }
    [IO.File]::WriteAllText($ConfigPath, $text, [Text.UTF8Encoding]::new($true))
}

function Parse-HexColor([string]$Hex, [Drawing.Color]$Fallback) {
    $value = $Hex.Trim().TrimStart('#')
    if ($value -notmatch '^[0-9A-Fa-f]{6}$') { return $Fallback }
    return [Drawing.Color]::FromArgb([Convert]::ToInt32($value.Substring(0, 2), 16), [Convert]::ToInt32($value.Substring(2, 2), 16), [Convert]::ToInt32($value.Substring(4, 2), 16))
}

function To-HexColor([Drawing.Color]$Color) { return '{0:X2}{1:X2}{2:X2}' -f $Color.R, $Color.G, $Color.B }

function Make-Label($Text, $X, $Y, $W = 105) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text
    $control.Location = New-Object Drawing.Point($X, $Y)
    $control.Size = New-Object Drawing.Size($W, 24)
    return $control
}

function Make-Number($X, $Y, $Min, $Max, $Width = 90) {
    $control = New-Object Windows.Forms.NumericUpDown
    $control.Location = New-Object Drawing.Point($X, $Y)
    $control.Size = New-Object Drawing.Size($Width, 24)
    $control.Minimum = $Min
    $control.Maximum = $Max
    return $control
}

function Make-Button($Text, $X, $Y, $W = 100) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $Text
    $control.Location = New-Object Drawing.Point($X, $Y)
    $control.Size = New-Object Drawing.Size($W, 30)
    return $control
}

$cfg = Read-ConfigValues
$SubtitleCacheDir = Join-Path $cfg.WorkDir 'subtitle_cache'
$script:PrivateFontCollections = New-Object Collections.ArrayList
$script:AllFontItems = @()
$script:VideoFiles = @()
$script:VideoIndex = 0
$script:IsPortrait = $false
$script:IsDragging = $false
$script:ExactPreviewReady = $false
$script:BaseImage = $null
$script:PreviewProcess = $null
$script:PreviewOutput = ''
$script:PreviewKind = ''
$script:PreviewGeneration = 0
$script:CloudTestJob = $null
$script:ParaformerDownloadConfirmed = $false

$form = New-Object Windows.Forms.Form
$form.Text = '字幕设置与预览'
$form.Size = New-Object Drawing.Size(1280, 850)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$form.MinimumSize = New-Object Drawing.Size(1180, 780)

$left = New-Object Windows.Forms.Panel
$left.Location = New-Object Drawing.Point(10, 10)
$left.Size = New-Object Drawing.Size(385, 785)
$left.BorderStyle = 'FixedSingle'
$form.Controls.Add($left)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(8, 8)
$tabs.Size = New-Object Drawing.Size(367, 720)
$left.Controls.Add($tabs)

$tabStyle = New-Object Windows.Forms.TabPage
$tabStyle.Text = '字幕样式'
$tabStyle.AutoScroll = $true
$tabFonts = New-Object Windows.Forms.TabPage
$tabFonts.Text = '字体管理'
$tabFonts.AutoScroll = $true
$tabCloud = New-Object Windows.Forms.TabPage
$tabCloud.Text = '阿里云接口'
$tabCloud.AutoScroll = $true
$tabs.TabPages.AddRange(@($tabStyle, $tabFonts, $tabCloud))

$btnSave = Make-Button '保存字幕设置' 10 742 170
$btnReset = Make-Button '恢复默认值' 195 742 170
$left.Controls.AddRange(@($btnSave, $btnReset))

$previewHost = New-Object Windows.Forms.Panel
$previewHost.Location = New-Object Drawing.Point(410, 10)
$previewHost.Size = New-Object Drawing.Size(835, 735)
$previewHost.BackColor = [Drawing.Color]::FromArgb(35, 35, 35)
$form.Controls.Add($previewHost)

$preview = New-Object Windows.Forms.PictureBox
$preview.BackColor = [Drawing.Color]::Black
$preview.SizeMode = 'Zoom'
$previewHost.Controls.Add($preview)

$lblPreviewStatus = Make-Label '预览准备中' 410 758 820
$lblPreviewStatus.ForeColor = [Drawing.Color]::DimGray
$form.Controls.Add($lblPreviewStatus)

$numFontSize = Make-Number 130 22 12 60
$tabStyle.Controls.AddRange(@((Make-Label '字体大小' 15 24), $numFontSize))
$btnTextColor = Make-Button '字幕颜色' 130 62 90
$btnOutlineColor = Make-Button '描边颜色' 220 62 105
$tabStyle.Controls.AddRange(@((Make-Label '颜色' 15 66), $btnTextColor, $btnOutlineColor))
$numOutline = Make-Number 130 105 0 6
$tabStyle.Controls.AddRange(@((Make-Label '描边粗细' 15 107), $numOutline))
$numMaxChars = Make-Number 130 145 0 40 80
$numMinChars = Make-Number 275 145 1 12 55
$tabStyle.Controls.AddRange(@((Make-Label '最多字数' 15 147), $numMaxChars, (Make-Label '最少' 235 147 35), $numMinChars))
$numSafeWidth = Make-Number 130 185 60 95
$numSafeWidth.Value = 94
$numSafeWidth.Enabled = $false
$tabStyle.Controls.AddRange(@((Make-Label '安全宽度%（固定）' 15 187), $numSafeWidth))
$tabStyle.Controls.Add((Make-Label '当前字幕来源' 15 535 95))
$cmbSourceMode = New-Object Windows.Forms.ComboBox
$cmbSourceMode.Location = New-Object Drawing.Point(100, 532)
$cmbSourceMode.Size = New-Object Drawing.Size(230, 24)
$cmbSourceMode.DropDownStyle = 'DropDownList'
$cmbSourceMode.DisplayMember = 'Display'
$cmbSourceMode.ValueMember = 'Value'
$sourceModeOptions = @(
    [pscustomobject]@{ Display = '本地 Paraformer-large（首次自动下载）'; Value = 'paraformer_local' }
    [pscustomobject]@{ Display = '仅阿里云'; Value = 'aliyun_only' }
    [pscustomobject]@{ Display = '阿里云优先本地备用'; Value = 'aliyun_fallback' }
    [pscustomobject]@{ Display = '同名文本稿优先'; Value = 'text_preferred' }
)
foreach ($option in $sourceModeOptions) { [void]$cmbSourceMode.Items.Add($option) }
$sourceModeItem = @($sourceModeOptions | Where-Object Value -eq $cfg.SubtitleSourceMode | Select-Object -First 1)
$cmbSourceMode.SelectedItem = if ($sourceModeItem.Count -gt 0) { $sourceModeItem[0] } else { $sourceModeOptions[0] }
$tabStyle.Controls.Add($cmbSourceMode)
$btnDownloadParaformer = Make-Button '检测/下载本地 Paraformer' 15 575 180
$btnOpenSubtitleCache = Make-Button '打开识别缓存' 205 575 125
$tabStyle.Controls.AddRange(@($btnDownloadParaformer, $btnOpenSubtitleCache))
$lblParaformerProgress = Make-Label '未开始下载' 15 610 320
$lblParaformerProgress.AutoSize = $false
$lblParaformerProgress.Size = New-Object Drawing.Size(320, 55)
$lblParaformerProgress.ForeColor = [Drawing.Color]::FromArgb(0, 100, 0)
$tabStyle.Controls.Add($lblParaformerProgress)
$btnLandscape = Make-Button '横屏 1920x1080' 15 230 150
$btnPortrait = Make-Button '竖屏 1080x1920' 180 230 150
$tabStyle.Controls.AddRange(@($btnLandscape, $btnPortrait))
$numMargin = Make-Number 130 275 0 200
$tabStyle.Controls.AddRange(@((Make-Label '字幕位置' 15 277), $numMargin))
$tabStyle.Controls.Add((Make-Label '预览文字' 15 320 80))
$txtSample = New-Object Windows.Forms.TextBox
$txtSample.Location = New-Object Drawing.Point(15, 348)
$txtSample.Size = New-Object Drawing.Size(315, 75)
$txtSample.Multiline = $true
$txtSample.Text = '大考事件收尾即时7天，学校广播在大课间时突然想起。'
$tabStyle.Controls.Add($txtSample)
$btnNextVideo = Make-Button '换一条素材' 15 445 110
$numPreviewTime = Make-Number 235 447 0 36000 95
$numPreviewTime.DecimalPlaces = 1
$numPreviewTime.Increment = 1
$numPreviewTime.Value = 3
$btnRefreshPreview = Make-Button '刷新精确预览' 15 490 150
$tabStyle.Controls.AddRange(@($btnNextVideo, (Make-Label '画面时间(秒)' 135 449 98), $numPreviewTime, $btnRefreshPreview))

$tabFonts.Controls.Add((Make-Label '搜索字体' 15 25 80))
$txtFontSearch = New-Object Windows.Forms.TextBox
$txtFontSearch.Location = New-Object Drawing.Point(100, 22)
$txtFontSearch.Size = New-Object Drawing.Size(230, 24)
$tabFonts.Controls.Add($txtFontSearch)
$tabFonts.Controls.Add((Make-Label '字体分类' 15 67 80))
$cmbFontCategory = New-Object Windows.Forms.ComboBox
$cmbFontCategory.Location = New-Object Drawing.Point(100, 64)
$cmbFontCategory.Size = New-Object Drawing.Size(230, 24)
$cmbFontCategory.DropDownStyle = 'DropDownList'
[void]$cmbFontCategory.Items.Add('支持中文')
[void]$cmbFontCategory.Items.Add('仿手写字体')
[void]$cmbFontCategory.Items.Add('全部字体')
$cmbFontCategory.SelectedIndex = 0
$tabFonts.Controls.Add($cmbFontCategory)
$tabFonts.Controls.Add((Make-Label '选择字体' 15 107 80))
$cmbFont = New-Object Windows.Forms.ComboBox
$cmbFont.Location = New-Object Drawing.Point(100, 104)
$cmbFont.Size = New-Object Drawing.Size(230, 28)
$cmbFont.DropDownStyle = 'DropDownList'
$cmbFont.DisplayMember = 'Display'
$cmbFont.DrawMode = 'OwnerDrawFixed'
$cmbFont.ItemHeight = 28
$tabFonts.Controls.Add($cmbFont)
$btnImportFont = Make-Button '批量导入字体' 15 152 140
$btnOpenFonts = Make-Button '打开字体目录' 175 152 140
$btnReloadFonts = Make-Button '重新扫描字体' 15 195 140
$tabFonts.Controls.AddRange(@($btnImportFont, $btnOpenFonts, $btnReloadFonts))
$lblFontCount = Make-Label '正在扫描字体...' 15 245 315
$tabFonts.Controls.Add($lblFontCount)
$lblFontWarning = Make-Label '' 15 280 315
$lblFontWarning.ForeColor = [Drawing.Color]::Firebrick
$tabFonts.Controls.Add($lblFontWarning)
$fontHelp = Make-Label '默认只显示真正包含中文字形的字体，避免自动回退后看起来都一样。手写字体已随程序保存，复制到其他电脑仍可使用。' 15 320 315
$fontHelp.AutoSize = $false
$fontHelp.Size = New-Object Drawing.Size(315, 90)
$tabFonts.Controls.Add($fontHelp)

$tabCloud.Controls.Add((Make-Label 'API Key' 15 28 80))
$txtApiKey = New-Object Windows.Forms.TextBox
$txtApiKey.Location = New-Object Drawing.Point(15, 55)
$txtApiKey.Size = New-Object Drawing.Size(315, 24)
$txtApiKey.UseSystemPasswordChar = $true
$tabCloud.Controls.Add($txtApiKey)
$chkShowKey = New-Object Windows.Forms.CheckBox
$chkShowKey.Text = '显示密钥'
$chkShowKey.Location = New-Object Drawing.Point(15, 88)
$chkShowKey.Size = New-Object Drawing.Size(100, 24)
$tabCloud.Controls.Add($chkShowKey)
$btnSaveKey = Make-Button '保存密钥' 15 125 95
$btnReplaceKey = Make-Button '替换密钥' 120 125 95
$btnDeleteKey = Make-Button '删除密钥' 225 125 95
$tabCloud.Controls.AddRange(@($btnSaveKey, $btnReplaceKey, $btnDeleteKey))
$lblKeyState = Make-Label '检测配置中...' 15 170 315
$tabCloud.Controls.Add($lblKeyState)
$tabCloud.Controls.Add((Make-Label '识别模型' 15 215 80))
$txtAliyunModel = New-Object Windows.Forms.TextBox
$txtAliyunModel.Location = New-Object Drawing.Point(100, 212)
$txtAliyunModel.Size = New-Object Drawing.Size(220, 24)
$txtAliyunModel.Text = $cfg.AliyunModel
$tabCloud.Controls.Add($txtAliyunModel)
$tabCloud.Controls.Add((Make-Label '接口地址' 15 258 80))
$txtAliyunEndpoint = New-Object Windows.Forms.TextBox
$txtAliyunEndpoint.Location = New-Object Drawing.Point(15, 285)
$txtAliyunEndpoint.Size = New-Object Drawing.Size(305, 48)
$txtAliyunEndpoint.Multiline = $true
$txtAliyunEndpoint.Text = $cfg.AliyunEndpoint
$tabCloud.Controls.Add($txtAliyunEndpoint)
$btnSaveCloud = Make-Button '保存接口设置' 15 350 140
$btnTestKey = Make-Button '测试连接' 175 350 140
$tabCloud.Controls.AddRange(@($btnSaveCloud, $btnTestKey))
$cloudHelp = Make-Label '接口地址可粘贴 https://host/api/v1 基础地址，保存时自动补全转写路径。密钥使用 Windows 当前用户加密保存，复制到另一台电脑后需重新输入。' 15 405 315
$cloudHelp.AutoSize = $false
$cloudHelp.Size = New-Object Drawing.Size(315, 80)
$tabCloud.Controls.Add($cloudHelp)

$script:TextColor = Parse-HexColor $cfg.SubtitleColor ([Drawing.Color]::White)
$script:OutlineColor = Parse-HexColor $cfg.SubtitleOutlineColor ([Drawing.Color]::Black)
$numFontSize.Value = $cfg.SubtitleFontSize
$numOutline.Value = $cfg.SubtitleOutline
$numMaxChars.Value = $cfg.SubtitleMaxCharsPerLine
$numMinChars.Value = $cfg.SubtitleMinChars
$numSafeWidth.Value = 94
$numMargin.Value = $cfg.SubtitleMarginVLandscape

function Update-ColorButtons {
    $btnTextColor.BackColor = $script:TextColor
    $btnTextColor.ForeColor = if ($script:TextColor.GetBrightness() -lt 0.45) { [Drawing.Color]::White } else { [Drawing.Color]::Black }
    $btnOutlineColor.BackColor = $script:OutlineColor
    $btnOutlineColor.ForeColor = if ($script:OutlineColor.GetBrightness() -lt 0.45) { [Drawing.Color]::White } else { [Drawing.Color]::Black }
}
Update-ColorButtons

function Load-FontItems {
    foreach ($collection in $script:PrivateFontCollections) { try { $collection.Dispose() } catch {} }
    $script:PrivateFontCollections = New-Object Collections.ArrayList
    $items = New-Object Collections.ArrayList
    $installed = New-Object Drawing.Text.InstalledFontCollection
    foreach ($family in ($installed.Families | Sort-Object Name)) {
        $hasChinese = (Test-FontSupportsChinese $family)
        [void]$items.Add([pscustomobject]@{ Display = $(if ($hasChinese) { $family.Name } else { "$($family.Name)（不支持中文）" }); Name = $family.Name; File = ''; Family = $family; Source = '系统'; HasChinese = $hasChinese; Category = $(if ($hasChinese) { '支持中文' } else { '其他字体' }) })
    }
    Get-ChildItem -LiteralPath $FontDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLowerInvariant() -in @('.ttf', '.otf', '.ttc') } |
        ForEach-Object {
            try {
                $collection = New-Object Drawing.Text.PrivateFontCollection
                $collection.AddFontFile($_.FullName)
                [void]$script:PrivateFontCollections.Add($collection)
                foreach ($family in $collection.Families) {
                    $hasChinese = (Test-FontSupportsChinese $family)
                    $isHandwriting = $_.Directory.Name -eq 'Handwriting'
                    if ($isHandwriting) {
                        [void]$items.Add([pscustomobject]@{ Display = "$($family.Name)（手写）"; Name = $family.Name; File = $_.FullName; Family = $family; Source = '便携'; HasChinese = $hasChinese; Category = '仿手写字体' })
                    } else {
                        [void]$items.Add([pscustomobject]@{ Display = "$($family.Name)（便携）"; Name = $family.Name; File = $_.FullName; Family = $family; Source = '便携'; HasChinese = $hasChinese; Category = $(if ($hasChinese) { '支持中文' } else { '其他字体' }) })
                    }
                }
            } catch {}
        }
    $script:AllFontItems = @($items | Sort-Object Category, Source, Name -Unique)
    $portableCount = @($script:AllFontItems | Where-Object Source -eq '便携').Count
    $chineseCount = @($script:AllFontItems | Where-Object HasChinese).Count
    $handwritingCount = @($script:AllFontItems | Where-Object Category -eq '仿手写字体').Count
    $lblFontCount.Text = "中文：$chineseCount 个；手写：$handwritingCount 个；便携：$portableCount 个"
}

function Test-FontSupportsChinese($Family) {
    try {
        $font = New-Object Drawing.Font($Family, 16, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
        try { return [FontGlyphProbe]::SupportsText($font, '字幕中文测试') } finally { $font.Dispose() }
    } catch { return $false }
}

function Refresh-FontCombo([string]$PreferredName, [string]$PreferredFile) {
    $filter = $txtFontSearch.Text.Trim()
    $category = [string]$cmbFontCategory.SelectedItem
    $cmbFont.BeginUpdate()
    try {
        $cmbFont.Items.Clear()
        foreach ($item in $script:AllFontItems) {
            if ($category -eq '支持中文' -and -not $item.HasChinese) { continue }
            if ($category -eq '仿手写字体' -and $item.Category -ne '仿手写字体') { continue }
            if ([string]::IsNullOrWhiteSpace($filter) -or $item.Display.IndexOf($filter, [StringComparison]::CurrentCultureIgnoreCase) -ge 0) { [void]$cmbFont.Items.Add($item) }
        }
        $match = $null
        foreach ($item in $cmbFont.Items) {
            if ($PreferredFile -and $item.File -and $item.File.EndsWith($PreferredFile, [StringComparison]::OrdinalIgnoreCase)) { $match = $item; break }
            if (-not $match -and $item.Name -eq $PreferredName) { $match = $item }
        }
        if ($match) { $cmbFont.SelectedItem = $match } elseif ($cmbFont.Items.Count -gt 0) { $cmbFont.SelectedIndex = 0 }
    } finally { $cmbFont.EndUpdate() }
}

function Get-SelectedFontItem { return $cmbFont.SelectedItem }

function Update-FontWarning {
    $item = Get-SelectedFontItem
    if ($item -and -not $item.HasChinese) { $lblFontWarning.Text = '该字体不包含中文，成品会自动回退。建议选择“支持中文”或“仿手写字体”。'; $lblFontWarning.ForeColor = [Drawing.Color]::Firebrick }
    elseif ($item) { $lblFontWarning.Text = "当前字体支持中文：$($item.Name)"; $lblFontWarning.ForeColor = [Drawing.Color]::DarkGreen }
    else { $lblFontWarning.Text = '' }
}

function Get-FrameInfo {
    if ($script:IsPortrait) { return [pscustomobject]@{ Width = 1080; Height = 1920 } }
    return [pscustomobject]@{ Width = 1920; Height = 1080 }
}

function Update-PreviewLayout {
    if ($script:IsPortrait) { $preview.Size = New-Object Drawing.Size(400, 711) } else { $preview.Size = New-Object Drawing.Size(815, 458) }
    $preview.Location = New-Object Drawing.Point([int](($previewHost.Width - $preview.Width) / 2), [int](($previewHost.Height - $preview.Height) / 2))
}

function Set-Orientation([bool]$Portrait) {
    if ($script:IsPortrait -ne $Portrait) {
        if ($script:IsPortrait) { $script:PortraitMargin = [int]$numMargin.Value } else { $script:LandscapeMargin = [int]$numMargin.Value }
    }
    $script:IsPortrait = $Portrait
    $numMargin.Value = if ($Portrait) { $script:PortraitMargin } else { $script:LandscapeMargin }
    $btnPortrait.BackColor = if ($Portrait) { [Drawing.Color]::LightSkyBlue } else { [Drawing.SystemColors]::Control }
    $btnLandscape.BackColor = if (-not $Portrait) { [Drawing.Color]::LightSkyBlue } else { [Drawing.SystemColors]::Control }
    Update-PreviewLayout
    Start-PreviewRender $false
}

function Get-SplitOptions {
    $frame = Get-FrameInfo
    $fontItem = Get-SelectedFontItem
    return @{
        FontName = if ($fontItem) { $fontItem.Name } else { 'Microsoft YaHei' }
        FontFile = if ($fontItem) { $fontItem.File } else { '' }
        FontSize = [int]$numFontSize.Value
        FrameWidth = $frame.Width
        FrameHeight = $frame.Height
        Outline = [int]$numOutline.Value
        SafeWidthPercent = 94
        MaxChars = [int]$numMaxChars.Value
        MinChars = [int]$numMinChars.Value
    }
}

function Load-ImageUnlocked([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $stream = New-Object IO.MemoryStream(,$bytes)
    try {
        $source = [Drawing.Image]::FromStream($stream)
        try { return New-Object Drawing.Bitmap($source) } finally { $source.Dispose() }
    } finally { $stream.Dispose() }
}

function Set-PreviewImage($Image, [bool]$Exact) {
    if ($preview.Image) { $preview.Image.Dispose() }
    $preview.Image = $Image
    $script:ExactPreviewReady = $Exact
    $preview.Invalidate()
}

function Get-CurrentVideo {
    if ($script:VideoFiles.Count -eq 0) { return $null }
    if ($script:VideoIndex -ge $script:VideoFiles.Count) { $script:VideoIndex = 0 }
    return $script:VideoFiles[$script:VideoIndex]
}

function Refresh-VideoList {
    $script:VideoFiles = @()
    if (Test-Path -LiteralPath $cfg.VideoDir -PathType Container) {
        $script:VideoFiles = @(Get-ChildItem -LiteralPath $cfg.VideoDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $VideoExts -contains $_.Extension.ToLowerInvariant() })
    }
}

function Stop-PreviewProcess {
    if ($script:PreviewProcess) {
        try { if (-not $script:PreviewProcess.HasExited) { $script:PreviewProcess.Kill() } } catch {}
        try { $script:PreviewProcess.Dispose() } catch {}
        $script:PreviewProcess = $null
    }
}

function Quote-ProcessArgument([string]$Value) { return '"' + ($Value -replace '"', '\"') + '"' }

function Start-PreviewRender([bool]$WithSubtitle) {
    try {
        Stop-PreviewProcess
        $script:PreviewGeneration += 1
        $generation = $script:PreviewGeneration
        $frame = Get-FrameInfo
        $video = Get-CurrentVideo
        $output = Join-Path $WorkDirForPreview ("preview_{0}.png" -f $generation)
        $scale = "scale=$($frame.Width):$($frame.Height):force_original_aspect_ratio=increase,crop=$($frame.Width):$($frame.Height)"
        $filter = $scale
        if ($WithSubtitle) {
            $fontItem = Get-SelectedFontItem
            if (-not $fontItem) { return }
            $style = Subtitle-Core\Get-SubtitleAssStyle -FontName $fontItem.Name -FontSize ([int]$numFontSize.Value) -PrimaryColor (To-HexColor $script:TextColor) -OutlineColor (To-HexColor $script:OutlineColor) -Outline ([int]$numOutline.Value) -MarginV ([int]$numMargin.Value)
            $splitOptions = Get-SplitOptions
            $chunks = @(Subtitle-Core\Split-SubtitleText -Text $txtSample.Text @splitOptions)
            $previewText = if ($chunks.Count -gt 0) { $chunks[0] } else { $txtSample.Text }
            Subtitle-Core\New-SrtFromSegments -Segments @([pscustomobject]@{ Start = 0.0; End = 10.0; Text = $previewText }) -Destination (Join-Path $WorkDirForPreview 'preview.srt')
            $tempFonts = Join-Path $WorkDirForPreview 'fonts'
            if (-not (Test-Path -LiteralPath $tempFonts)) { New-Item -ItemType Directory -Path $tempFonts -Force | Out-Null }
            Get-ChildItem -LiteralPath $FontDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension.ToLowerInvariant() -in @('.ttf', '.otf', '.ttc') } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $tempFonts -Force }
            $filter += ",subtitles=preview.srt:fontsdir=fonts:force_style='$style'"
        }
        $requestPath = Join-Path $WorkDirForPreview ("request_{0}.json" -f $generation)
        $request = [ordered]@{
            Ffmpeg = $Ffmpeg
            WorkDir = $WorkDirForPreview
            VideoPath = if ($video) { $video.FullName } else { '' }
            Time = [string]$numPreviewTime.Value
            Width = $frame.Width
            Height = $frame.Height
            Filter = $(if (-not $video -and -not $WithSubtitle) { 'null' } elseif (-not $video -and $WithSubtitle) { $filter.Substring($filter.IndexOf('subtitles=')) } else { $filter })
            OutputPath = $output
        }
        [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Quote-ProcessArgument $PreviewWorker) + ' -RequestPath ' + (Quote-ProcessArgument $requestPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        $script:PreviewProcess = $process
        $script:PreviewOutput = $output
        $script:PreviewKind = if ($WithSubtitle) { 'exact' } else { 'base' }
        $lblPreviewStatus.Text = '预览更新中，页面可以继续操作...'
        $lblPreviewStatus.ForeColor = [Drawing.Color]::DarkOrange
        $previewPollTimer.Start()
    } catch {
        $lblPreviewStatus.Text = "预览错误：$($_.Exception.Message)"
        $lblPreviewStatus.ForeColor = [Drawing.Color]::Firebrick
    }
}

$previewTimer = New-Object Windows.Forms.Timer
$previewTimer.Interval = 800
function Schedule-Preview {
    $previewTimer.Stop()
    $script:ExactPreviewReady = $false
    $preview.Invalidate()
    $previewTimer.Start()
}
$previewTimer.Add_Tick({
    $previewTimer.Stop()
    Start-PreviewRender $true
})

$previewPollTimer = New-Object Windows.Forms.Timer
$previewPollTimer.Interval = 100
$previewPollTimer.Add_Tick({
    if (-not $script:PreviewProcess -or -not $script:PreviewProcess.HasExited) { return }
    $previewPollTimer.Stop()
    $exitCode = $script:PreviewProcess.ExitCode
    $errorText = $script:PreviewProcess.StandardError.ReadToEnd()
    $kind = $script:PreviewKind
    $output = $script:PreviewOutput
    try { $script:PreviewProcess.Dispose() } catch {}
    $script:PreviewProcess = $null
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        $lblPreviewStatus.Text = "预览错误：$($errorText.Trim())"
        $lblPreviewStatus.ForeColor = [Drawing.Color]::Firebrick
        return
    }
    try {
        $image = Load-ImageUnlocked $output
        if ($kind -eq 'base') {
            if ($script:BaseImage) { $script:BaseImage.Dispose() }
            $script:BaseImage = New-Object Drawing.Bitmap($image)
            Set-PreviewImage $image $false
            Schedule-Preview
        } else {
            Set-PreviewImage $image $true
            $splitOptions = Get-SplitOptions
            $chunks = @(Subtitle-Core\Split-SubtitleText -Text $txtSample.Text @splitOptions)
            $lblPreviewStatus.Text = "精确预览已刷新；当前示例将拆为 $($chunks.Count) 条最多两行字幕"
            $lblPreviewStatus.ForeColor = [Drawing.Color]::DarkGreen
        }
    } catch {
        $lblPreviewStatus.Text = "预览错误：$($_.Exception.Message)"
        $lblPreviewStatus.ForeColor = [Drawing.Color]::Firebrick
    }
})

$preview.Add_Paint({
    param($sender, $e)
    $safePercent = 94
    $safeWidth = $preview.ClientSize.Width * $safePercent / 100.0
    $safeX = ($preview.ClientSize.Width - $safeWidth) / 2
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(180, 255, 80, 80), 1)
    try { $e.Graphics.DrawRectangle($pen, $safeX, 2, $safeWidth, $preview.ClientSize.Height - 5) } finally { $pen.Dispose() }
    if ($script:ExactPreviewReady) { return }
    $fontItem = Get-SelectedFontItem
    if (-not $fontItem -or [string]::IsNullOrWhiteSpace($txtSample.Text)) { return }
    $splitOptions = Get-SplitOptions
    $chunks = @(Subtitle-Core\Split-SubtitleText -Text $txtSample.Text @splitOptions)
    $displayText = if ($chunks.Count -gt 0) { $chunks[0] } else { $txtSample.Text }
    $fontPixels = [Math]::Max(12, [int]$numFontSize.Value * $preview.ClientSize.Height / 288.0)
    try { $font = New-Object Drawing.Font($fontItem.Family, $fontPixels, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel) } catch { $font = New-Object Drawing.Font($form.Font.FontFamily, $fontPixels) }
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $format.FormatFlags = [Drawing.StringFormatFlags]::NoWrap
    $marginPixels = [int]$numMargin.Value * $preview.ClientSize.Height / 288.0
    $height = $fontPixels * 1.5
    $rect = New-Object Drawing.RectangleF(0, ($preview.ClientSize.Height - $marginPixels - $height), $preview.ClientSize.Width, $height)
    try {
        $outlineBrush = New-Object Drawing.SolidBrush($script:OutlineColor)
        $textBrush = New-Object Drawing.SolidBrush($script:TextColor)
        $offset = [Math]::Max(1, [int]$numOutline.Value)
        foreach ($dx in @(-$offset, 0, $offset)) { foreach ($dy in @(-$offset, 0, $offset)) { if ($dx -ne 0 -or $dy -ne 0) { $r = New-Object Drawing.RectangleF(($rect.X + $dx), ($rect.Y + $dy), $rect.Width, $rect.Height); $e.Graphics.DrawString($displayText, $font, $outlineBrush, $r, $format) } } }
        $e.Graphics.DrawString($displayText, $font, $textBrush, $rect, $format)
        $outlineBrush.Dispose(); $textBrush.Dispose()
    } finally { $font.Dispose(); $format.Dispose() }
})

$cmbFont.Add_DrawItem({
    param($sender, $e)
    $e.DrawBackground()
    if ($e.Index -lt 0) { return }
    $item = $sender.Items[$e.Index]
    try { $drawFont = New-Object Drawing.Font($item.Family, 11) } catch { $drawFont = $form.Font }
    $brush = New-Object Drawing.SolidBrush($e.ForeColor)
    try { $e.Graphics.DrawString($item.Display, $drawFont, $brush, $e.Bounds.X + 3, $e.Bounds.Y + 4) } finally { $brush.Dispose(); if ($drawFont -ne $form.Font) { $drawFont.Dispose() } }
    $e.DrawFocusRectangle()
})

$preview.Add_MouseDown({ $script:IsDragging = $true })
$preview.Add_MouseMove({
    param($sender, $e)
    if (-not $script:IsDragging) { return }
    $margin = [int](($preview.ClientSize.Height - $e.Y) * 288.0 / $preview.ClientSize.Height)
    $numMargin.Value = [Math]::Min([int]$numMargin.Maximum, [Math]::Max([int]$numMargin.Minimum, $margin))
})
$preview.Add_MouseUp({ $script:IsDragging = $false; Schedule-Preview })

$changeControls = @($cmbFont, $numFontSize, $numOutline, $numMaxChars, $numMinChars, $numSafeWidth, $numMargin, $txtSample)
foreach ($control in $changeControls) {
    if ($control -is [Windows.Forms.ComboBox]) { $control.Add_SelectedIndexChanged({ Schedule-Preview }) }
    elseif ($control -is [Windows.Forms.NumericUpDown]) { $control.Add_ValueChanged({ Schedule-Preview }) }
    else { $control.Add_TextChanged({ Schedule-Preview }) }
}

$txtFontSearch.Add_TextChanged({
    $current = Get-SelectedFontItem
    Refresh-FontCombo $(if ($current) { $current.Name } else { $cfg.SubtitleFontName }) $(if ($current) { $current.File } else { $cfg.SubtitleFontFile })
})
$cmbFontCategory.Add_SelectedIndexChanged({
    $current = Get-SelectedFontItem
    Refresh-FontCombo $(if ($current) { $current.Name } else { $cfg.SubtitleFontName }) $(if ($current) { $current.File } else { $cfg.SubtitleFontFile })
})
$cmbFont.Add_SelectedIndexChanged({
    Update-FontWarning
    $btnSave.Text = '保存并应用到后续视频'
    $btnSave.BackColor = [Drawing.Color]::LightGoldenrodYellow
})
$btnImportFont.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = '字体文件 (*.ttf;*.otf;*.ttc)|*.ttf;*.otf;*.ttc'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -eq 'OK') {
        foreach ($file in $dialog.FileNames) { Copy-Item -LiteralPath $file -Destination $FontDir -Force }
        Load-FontItems
        Refresh-FontCombo $cfg.SubtitleFontName $cfg.SubtitleFontFile
    }
})
$btnOpenFonts.Add_Click({ Start-Process explorer.exe -ArgumentList $FontDir })
$btnOpenSubtitleCache.Add_Click({
    if (-not (Test-Path -LiteralPath $SubtitleCacheDir -PathType Container)) { New-Item -ItemType Directory -Path $SubtitleCacheDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $SubtitleCacheDir)
})
$btnDownloadParaformer.Add_Click({
    try {
        if ($script:ParaformerSetupProcess -and -not $script:ParaformerSetupProcess.HasExited) {
            [Windows.Forms.MessageBox]::Show('本地 Paraformer 正在下载，请勿重复启动。', '正在下载') | Out-Null
            return
        }
        if (-not ((Test-Path -LiteralPath $ParaformerSetup) -and (Test-Path -LiteralPath $ParaformerWorker))) {
            throw '本地 Paraformer 组件不完整，请重新安装软件更新包。'
        }
        $precheckReason = ''
        $precheckReady = Test-ParaformerWorkerReady ([ref]$precheckReason)
        if ($precheckReady) {
            $readyMessage = '本地模型已就绪，无需下载。' + $(if ($script:ParaformerReadyNotice) { "`r`n$($script:ParaformerReadyNotice)" } else { '' })
            if ($script:ParaformerReadyNotice -match '显卡不兼容') {
                $script:ParaformerDownloadConfirmed = $true
                $btnDownloadParaformer.Text = '升级显卡运行环境'
                $readyMessage += "`r`n可直接使用 CPU；再次点击可安装适配 RTX 50 系的 CUDA 12.8 运行环境。"
            } else {
                $script:ParaformerDownloadConfirmed = $false
                $btnDownloadParaformer.Text = '检测/下载本地 Paraformer'
            }
            $lblParaformerProgress.Text = $readyMessage
            Write-SubtitleSettingsLog 'PARAFORMER_LOCAL_READY_NO_DOWNLOAD'
            [Windows.Forms.MessageBox]::Show($readyMessage, '本地检测完成') | Out-Null
            return
        }
        Write-SubtitleSettingsLog "PRECHECK_NOT_READY: $precheckReason"
        if (-not $script:ParaformerDownloadConfirmed) {
            $script:ParaformerDownloadConfirmed = $true
            $btnDownloadParaformer.Text = '下载缺失组件'
            $lblParaformerProgress.Text = "本地模型未就绪：`r`n$precheckReason`r`n再次点击 [下载缺失组件] 开始下载。"
            [Windows.Forms.MessageBox]::Show("本地 Paraformer 未就绪，缺少：`r`n$precheckReason`r`n`r`n请点击 [下载缺失组件] 开始下载。", '本地检测完成') | Out-Null
            return
        }
        $script:ParaformerDownloadConfirmed = $false
        $setupLog = Join-Path $SettingsLogDir 'paraformer_setup.log'
        $script:ParaformerLauncherOut = Join-Path $SettingsLogDir 'paraformer_setup_launcher.out.log'
        $script:ParaformerLauncherErr = Join-Path $SettingsLogDir 'paraformer_setup_launcher.err.log'
        Remove-Item -LiteralPath $ParaformerProgress -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:ParaformerLauncherOut, $script:ParaformerLauncherErr -Force -ErrorAction SilentlyContinue
        $setupArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ParaformerSetup, '-RuntimeDir', (Join-Path $ParaformerRoot 'runtime'), '-ModelCacheDir', $ParaformerModelCache, '-WorkerPath', $ParaformerWorker, '-LogPath', $setupLog, '-ProgressPath', $ParaformerProgress)
        if ($precheckReason) { $setupArgs += @('-PrecheckReason', $precheckReason) }
        $script:ParaformerSetupStartedAt = Get-Date
        $script:ParaformerSetupProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $setupArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:ParaformerLauncherOut -RedirectStandardError $script:ParaformerLauncherErr
        $btnDownloadParaformer.Text = '正在下载…'
        $btnDownloadParaformer.Enabled = $false
        $lblParaformerProgress.Text = '正在准备下载进度…'
        $paraformerSetupTimer.Start()
        Write-SubtitleSettingsLog "PARAFORMER_SETUP_STARTED: $setupLog"
        [Windows.Forms.MessageBox]::Show("已开始下载本地 Paraformer。首次需要联网并下载较大文件，完成前请保持软件运行。详细进度日志：$setupLog", '正在下载') | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, '下载启动失败') | Out-Null
    }
})
$paraformerSetupTimer = New-Object Windows.Forms.Timer
$paraformerSetupTimer.Interval = 1000
$paraformerSetupTimer.Add_Tick({
    if (-not $script:ParaformerSetupProcess) { return }
    $setupLog = Join-Path $SettingsLogDir 'paraformer_setup.log'
    if (-not $script:ParaformerSetupProcess.HasExited) {
        $stage = '正在准备本地 Paraformer'
        $progressText = ''
        if (Test-Path -LiteralPath $ParaformerProgress) {
            try {
                $progress = Get-Content -LiteralPath $ParaformerProgress -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($progress.Stage) { $stage = $progress.Stage }
                if ([Int64]$progress.TotalBytes -gt 0) {
                    $done = [Int64]$progress.DownloadedBytes; $total = [Int64]$progress.TotalBytes; $left = [Math]::Max(0, $total - $done); $percent = [Math]::Min(100, [Math]::Round($done * 100 / $total, 1))
                    $progressText = "`r`n已下载：{0:N2} GB / {1:N2} GB（剩余 {2:N2} GB，{3}%）{4}" -f ($done / 1GB), ($total / 1GB), ($left / 1GB), $percent, $(if ($progress.Speed) { "，$($progress.Speed)" } else { '' })
                } else { $progressText = "`r`n正在获取当前文件大小…" }
            } catch {}
        }
        if (Test-Path -LiteralPath $setupLog) {
            $lastStage = @([IO.File]::ReadAllLines($setupLog,[Text.UTF8Encoding]::new($true)) | Where-Object { $_ -match '阶段：' } | Select-Object -Last 1)
            if ($lastStage.Count -gt 0) { $stage = $lastStage[0] -replace '^.*阶段：', '' }
        }
        $elapsed = if ($script:ParaformerSetupStartedAt) { ((Get-Date) - $script:ParaformerSetupStartedAt).ToString('hh\:mm\:ss') } else { '00:00:00' }
        $lblPreviewStatus.Text = "本地 Paraformer 安装中（$elapsed）：$stage"
        $lblParaformerProgress.Text = "$stage$progressText"
        return
    }
    $paraformerSetupTimer.Stop()
    $exitCode = $script:ParaformerSetupProcess.ExitCode
    try { $script:ParaformerSetupProcess.Dispose() } catch {}
    $script:ParaformerSetupProcess = $null
    $btnDownloadParaformer.Enabled = $true
    $btnDownloadParaformer.Text = '检测/下载本地 Paraformer'
    if ($exitCode -eq 0) {
        $btnDownloadParaformer.Text = '检测/下载本地 Paraformer'
        $lblParaformerProgress.Text = '下载完成，本地 Paraformer 已就绪。'
        [Windows.Forms.MessageBox]::Show('本地 Paraformer 已下载并准备完成。', '完成') | Out-Null
    } else {
        $failureLog = $setupLog
        if (-not (Test-Path -LiteralPath $setupLog)) {
            $failureLog = Join-Path $SettingsLogDir 'paraformer_setup_launcher.log'
            $details = @()
            foreach ($launcherLog in @($script:ParaformerLauncherOut, $script:ParaformerLauncherErr)) {
                if ($launcherLog -and (Test-Path -LiteralPath $launcherLog)) { $details += Get-Content -LiteralPath $launcherLog -Raw -ErrorAction SilentlyContinue }
            }
            $details = $details -join [Environment]::NewLine
            if ([string]::IsNullOrWhiteSpace($details)) { $details = '安装脚本未启动，未获得标准错误输出。' }
            [IO.File]::WriteAllText($failureLog, $details, [Text.UTF8Encoding]::new($true))
        }
        [Windows.Forms.MessageBox]::Show("本地 Paraformer 下载失败，退出码：$exitCode。请查看：$failureLog", '下载失败') | Out-Null
    }
})
$btnReloadFonts.Add_Click({ $current = Get-SelectedFontItem; Load-FontItems; Refresh-FontCombo $current.Name $current.File })

function Pick-Color([bool]$Outline) {
    $dialog = New-Object Windows.Forms.ColorDialog
    $dialog.FullOpen = $true
    $dialog.Color = if ($Outline) { $script:OutlineColor } else { $script:TextColor }
    if ($dialog.ShowDialog() -eq 'OK') {
        if ($Outline) { $script:OutlineColor = $dialog.Color } else { $script:TextColor = $dialog.Color }
        Update-ColorButtons
        Schedule-Preview
    }
}
$btnTextColor.Add_Click({ Pick-Color $false })
$btnOutlineColor.Add_Click({ Pick-Color $true })
$btnLandscape.Add_Click({ Set-Orientation $false })
$btnPortrait.Add_Click({ Set-Orientation $true })
$btnNextVideo.Add_Click({ if ($script:VideoFiles.Count -gt 0) { $script:VideoIndex = ($script:VideoIndex + 1) % $script:VideoFiles.Count }; Start-PreviewRender $false })
$numPreviewTime.Add_ValueChanged({ Start-PreviewRender $false })
$btnRefreshPreview.Add_Click({ Start-PreviewRender $true })

function Refresh-KeyState {
    try {
        $key = Get-AliyunApiKey
        if ([string]::IsNullOrWhiteSpace($key)) { $lblKeyState.Text = '未配置API Key'; $lblKeyState.ForeColor = [Drawing.Color]::Firebrick }
        else { $suffix = if ($key.Length -gt 4) { $key.Substring($key.Length - 4) } else { $key }; $lblKeyState.Text = "已配置，结尾：$suffix"; $lblKeyState.ForeColor = [Drawing.Color]::DarkGreen }
    } catch { $lblKeyState.Text = $_.Exception.Message; $lblKeyState.ForeColor = [Drawing.Color]::Firebrick }
}

function Save-CurrentKey {
    if ([string]::IsNullOrWhiteSpace($txtApiKey.Text)) { throw '请输入新的API Key。' }
    Save-AliyunApiKey -ApiKey $txtApiKey.Text
    $txtApiKey.Clear()
    Refresh-KeyState
}

$chkShowKey.Add_CheckedChanged({ $txtApiKey.UseSystemPasswordChar = -not $chkShowKey.Checked })
$btnSaveKey.Add_Click({ try { Save-CurrentKey; [Windows.Forms.MessageBox]::Show('API Key已加密保存。', '完成') | Out-Null } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败') | Out-Null } })
$btnReplaceKey.Add_Click({ try { Save-CurrentKey; [Windows.Forms.MessageBox]::Show('API Key已替换。', '完成') | Out-Null } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '替换失败') | Out-Null } })
$btnDeleteKey.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('确定删除这台电脑保存的阿里云API Key吗？', '确认', 'YesNo', 'Warning') -eq 'Yes') { Remove-AliyunApiKey; $txtApiKey.Clear(); Refresh-KeyState }
})
$btnSaveCloud.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace($txtAliyunModel.Text)) { throw '识别模型不能为空。' }
        $endpoint = Assert-AliyunEndpoint $txtAliyunEndpoint.Text.Trim()
        Save-SubtitleConfig ([ordered]@{ AliyunModel = $txtAliyunModel.Text.Trim(); AliyunEndpoint = $endpoint })
        [Windows.Forms.MessageBox]::Show('阿里云接口设置已保存。', '完成') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败') | Out-Null }
})

$cloudTestTimer = New-Object Windows.Forms.Timer
$cloudTestTimer.Interval = 150
$cloudTestTimer.Add_Tick({
    if (-not $script:CloudTestJob -or $script:CloudTestJob.State -in @('Running', 'NotStarted')) { return }
    $cloudTestTimer.Stop()
    try {
        $result = Receive-Job -Job $script:CloudTestJob -ErrorAction Stop
        $lblKeyState.Text = if ($result.Success) { '连接正常' } else { '连接失败' }
        $lblKeyState.ForeColor = if ($result.Success) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick }
        [Windows.Forms.MessageBox]::Show($result.Message, '阿里云连接测试') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '连接测试失败') | Out-Null }
    finally { Remove-Job -Job $script:CloudTestJob -Force -ErrorAction SilentlyContinue; $script:CloudTestJob = $null; $btnTestKey.Enabled = $true }
})
$btnTestKey.Add_Click({
    if ($script:CloudTestJob) { return }
    $key = if ([string]::IsNullOrWhiteSpace($txtApiKey.Text)) { try { Get-AliyunApiKey } catch { '' } } else { $txtApiKey.Text.Trim() }
    $model = $txtAliyunModel.Text.Trim()
    $endpoint = $txtAliyunEndpoint.Text.Trim()
    $modulePath = $AliyunModule
    $lblKeyState.Text = '正在后台测试连接...'
    $lblKeyState.ForeColor = [Drawing.Color]::DarkOrange
    $btnTestKey.Enabled = $false
    $script:CloudTestJob = Start-Job -ScriptBlock { param($path, $apiKey, $modelName, $taskEndpoint) Import-Module $path -Force; Test-AliyunConnection -ApiKey $apiKey -Model $modelName -Endpoint $taskEndpoint } -ArgumentList $modulePath, $key, $model, $endpoint
    $cloudTestTimer.Start()
})

$btnSave.Add_Click({
    try {
        if ($script:IsPortrait) { $script:PortraitMargin = [int]$numMargin.Value } else { $script:LandscapeMargin = [int]$numMargin.Value }
        $fontItem = Get-SelectedFontItem
        if (-not $fontItem) { throw '请选择字体。' }
        $relativeFontFile = ''
        if ($fontItem.File) { $relativeFontFile = $fontItem.File.Substring($FontDir.Length).TrimStart('\') }
        $values = [ordered]@{
            SubtitleFontName = $fontItem.Name
            SubtitleFontFile = $(if ($relativeFontFile) { 'fonts\' + $relativeFontFile } else { '' })
            SubtitleFontSize = [int]$numFontSize.Value
            SubtitleColor = To-HexColor $script:TextColor
            SubtitleOutlineColor = To-HexColor $script:OutlineColor
            SubtitleOutline = [int]$numOutline.Value
            SubtitleMaxCharsPerLine = [int]$numMaxChars.Value
            SubtitleMinChars = [int]$numMinChars.Value
            SubtitleSafeWidthPercent = 94
            SubtitleSourceMode = [string]$cmbSourceMode.SelectedItem.Value
            SubtitleMarginVPortrait = [int]$script:PortraitMargin
            SubtitleMarginVLandscape = [int]$script:LandscapeMargin
            SubtitleMarginV = $(if ($script:IsPortrait) { [int]$script:PortraitMargin } else { [int]$script:LandscapeMargin })
        }
        Save-SubtitleConfig $values
        $btnSave.Text = '已保存并应用'
        $btnSave.BackColor = [Drawing.Color]::LightGreen
        [Windows.Forms.MessageBox]::Show('字幕设置已保存。', '完成') | Out-Null
    } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败') | Out-Null }
})
$btnReset.Add_Click({
    $numFontSize.Value = 16; $numOutline.Value = 2; $numMaxChars.Value = 0; $numMinChars.Value = 6; $numSafeWidth.Value = 94; $cmbSourceMode.SelectedItem = $sourceModeOptions[0]
    $script:PortraitMargin = 30; $script:LandscapeMargin = 30; $numMargin.Value = 30
    $script:TextColor = [Drawing.Color]::White; $script:OutlineColor = [Drawing.Color]::Black; Update-ColorButtons; Schedule-Preview
})

$form.Add_Shown({
    Write-SubtitleSettingsLog 'FORM_SHOWN'
    $form.TopMost = $true
    $form.Activate()
    $form.BringToFront()
    Load-FontItems
    Refresh-FontCombo $cfg.SubtitleFontName $cfg.SubtitleFontFile
    $script:PortraitMargin = [int]$cfg.SubtitleMarginVPortrait
    $script:LandscapeMargin = [int]$cfg.SubtitleMarginVLandscape
    Refresh-VideoList
    Refresh-KeyState
    Set-Orientation $false
})
$form.Add_FormClosed({
    Write-SubtitleSettingsLog 'FORM_CLOSED'
    $previewTimer.Stop(); $previewPollTimer.Stop(); $cloudTestTimer.Stop(); $paraformerSetupTimer.Stop()
    Stop-PreviewProcess
    if ($script:CloudTestJob) { Stop-Job $script:CloudTestJob -ErrorAction SilentlyContinue; Remove-Job $script:CloudTestJob -Force -ErrorAction SilentlyContinue }
    if ($preview.Image) { $preview.Image.Dispose() }
    if ($script:BaseImage) { $script:BaseImage.Dispose() }
    foreach ($collection in $script:PrivateFontCollections) { try { $collection.Dispose() } catch {} }
    Remove-Item -LiteralPath $WorkDirForPreview -Recurse -Force -ErrorAction SilentlyContinue
})

[void]$form.ShowDialog()
