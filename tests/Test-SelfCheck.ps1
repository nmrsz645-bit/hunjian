$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$root = Split-Path -Parent $PSScriptRoot
$launcher = [IO.File]::ReadAllText((Join-Path $root 'Start-AutoCut.ps1'), [Text.Encoding]::UTF8)
$manager = [IO.File]::ReadAllText((Join-Path $root 'AutoCut-Manager.ps1'), [Text.Encoding]::UTF8)
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'tools\Debug-AliyunUpload.ps1'))) '阿里云上传调试脚本不得进入发布目录'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'tools\Probe-AliyunResult.ps1'))) '阿里云结果编码探针不得进入发布目录'

foreach ($pattern in @(
    'Subtitle-Core\.psm1',
    'Subtitle-Aliyun\.psm1',
    'Subtitle-Preview-Worker\.ps1',
    'Test-AliyunConnection',
    'Get-AliyunApiKey',
    'Get-WindowsCurlPath',
    'fonts',
    'Test-SubtitlePreviewRender'
)) {
    Assert-True ($launcher -match $pattern) "自检缺少检查：$pattern"
}

Assert-True ($launcher -match 'SubtitleSourceMode') '自检必须读取字幕来源模式'
Assert-True ($launcher -match '仅阿里云模式') '自检必须说明严格阿里云模式'
Assert-True ($launcher -notmatch '将自动使用本地Whisper') '严格阿里云默认模式下自检不得提示自动回退Whisper'
Assert-True ($launcher -match 'Test-ToolRun\s+\$curlPath\s+@\(["'']--version["'']\)\s+["'']Windows curl\.exe["'']') '启动自检必须实际运行Windows curl.exe --version'
Assert-True ($launcher -match '新电脑[^\r\n]+curl') 'curl缺失或不可运行时必须给出新电脑修复提示'

$openccCheckFunction = [regex]::Match($launcher, '(?s)function\s+Test-OpenCCConversion\s*\([^)]*\)\s*\{.*?\n\}').Value
Assert-True (-not [string]::IsNullOrWhiteSpace($openccCheckFunction)) '启动器必须包含OpenCC实际转换自检函数'
Assert-True ($openccCheckFunction -match 'WriteAllText\(\$input,[\s\S]*測試繁體轉簡體[\s\S]*UTF8Encoding\]::new\(\$true\)') 'OpenCC自检必须显式创建带BOM的繁体输入'
Assert-True ($openccCheckFunction -match 'ReadAllText\(\$output,\s*\[Text\.Encoding\]::UTF8\)[\s\S]*测试繁体转简体') 'OpenCC自检必须读取并验证正确简体内容，不能只检查退出码'

$openccSelfCheckDir = Join-Path ([IO.Path]::GetTempPath()) ('autocut_opencc_selfcheck_contract_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $openccSelfCheckDir | Out-Null
try {
    $openccSelfCheckResult = & {
        param($functionSource, $rootPath, $logPath)
        $Root = $rootPath
        $VersionLogDir = $logPath
        $RunStamp = 'test'
        function Ensure-Dir($Path) { [IO.Directory]::CreateDirectory($Path) | Out-Null }
        function Write-Ok {}
        function Write-Bad {}
        Invoke-Expression $functionSource
        Test-OpenCCConversion `
            (Join-Path $rootPath 'tools\opencc\bin\opencc.exe') `
            (Join-Path $rootPath 'tools\opencc\share\opencc\t2s.json')
    } $openccCheckFunction $root $openccSelfCheckDir
    Assert-True $openccSelfCheckResult 'OpenCC自检必须在带BOM输入下验证实际简体内容成功'
} finally {
    Remove-Item -LiteralPath $openccSelfCheckDir -Recurse -Force -ErrorAction SilentlyContinue
}

$backupFunction = [regex]::Match($launcher, '(?s)function\s+New-VersionBackup\s*\{.*?\n\}').Value
Assert-True ($backupFunction -match 'Subtitle-Core\.psm1') '版本备份必须包含字幕核心模块'
Assert-True ($backupFunction -match 'Subtitle-Aliyun\.psm1') '版本备份必须包含阿里云模块'
Assert-True ($backupFunction -match 'AutoCut-Manager\.ps1') '版本备份必须包含管理界面'
Assert-True ($backupFunction -match 'Subtitle-Preview-Worker\.ps1') '版本备份必须包含后台预览程序'
Assert-True ($backupFunction -notmatch 'aliyun-key\.dat') '版本备份不得包含加密API Key'

Assert-True ($manager -match '字幕状态') '状态面板必须显示字幕状态'
Assert-True ($manager -match '字幕来源|字幕缓存') '状态面板必须从日志提取字幕来源或缓存状态'

Write-Host 'PASS Test-SelfCheck' -ForegroundColor Green
