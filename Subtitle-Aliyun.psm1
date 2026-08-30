$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Net.Http

$script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DefaultKeyPath = Join-Path $script:ModuleRoot 'config\aliyun-key.dat'
$script:UploadPolicyEndpoint = 'https://dashscope.aliyuncs.com/api/v1/uploads'
$script:DefaultTranscriptionEndpoint = 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription'
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('AutoCut-Aliyun-Key-v1')

function Save-AliyunApiKey {
    param(
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [string]$KeyPath = $script:DefaultKeyPath
    )
    $trimmed = $ApiKey.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { throw 'API Key不能为空。' }
    $dir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($trimmed)
    try {
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes,
            $script:Entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        [IO.File]::WriteAllText($KeyPath, [Convert]::ToBase64String($protected), [Text.Encoding]::ASCII)
    } finally {
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
    }
}

function Get-AliyunApiKey {
    param([string]$KeyPath = $script:DefaultKeyPath)
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) { return $null }
    try {
        $protected = [Convert]::FromBase64String([IO.File]::ReadAllText($KeyPath, [Text.Encoding]::ASCII).Trim())
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $script:Entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        try {
            return [Text.Encoding]::UTF8.GetString($plainBytes)
        } finally {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    } catch {
        throw '阿里云API Key无法解密，请在这台电脑重新输入。'
    }
}

function Remove-AliyunApiKey {
    param([string]$KeyPath = $script:DefaultKeyPath)
    Remove-Item -LiteralPath $KeyPath -Force -ErrorAction SilentlyContinue
}

function Get-AliyunHeaders {
    param([string]$ApiKey, [switch]$Async, [switch]$ResolveOss)
    $headers = @{ Authorization = "Bearer $ApiKey" }
    if ($Async) { $headers['X-DashScope-Async'] = 'enable' }
    if ($ResolveOss) { $headers['X-DashScope-OssResourceResolve'] = 'enable' }
    return $headers
}

function Assert-AliyunEndpoint {
    param([Parameter(Mandatory = $true)][string]$Endpoint)
    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        throw '阿里云端点格式无效。'
    }
    $host = $uri.DnsSafeHost.ToLowerInvariant()
    $officialHost = $host -in @('dashscope.aliyuncs.com', 'dashscope-intl.aliyuncs.com', 'dashscope-us.aliyuncs.com') -or
        $host -match '^[a-z0-9][a-z0-9-]{0,62}\.(cn-beijing|ap-southeast-1|eu-central-1)\.maas\.aliyuncs\.com$'
    if ($uri.Scheme -ne 'https' -or -not $uri.IsDefaultPort -or -not $officialHost -or $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
        throw '阿里云端点必须是官方HTTPS转写地址。'
    }
    $transcriptionPath = '/api/v1/services/audio/asr/transcription'
    if ($uri.AbsolutePath -eq '/api/v1') {
        $builder = New-Object UriBuilder($uri)
        $builder.Path = $transcriptionPath
        return $builder.Uri.AbsoluteUri
    }
    if ($uri.AbsolutePath -ne $transcriptionPath) { throw '阿里云端点路径必须是/api/v1基础地址或完整转写地址。' }
    return $uri.AbsoluteUri
}

function Protect-AliyunErrorText {
    param(
        [string]$Text,
        [string]$ApiKey
    )
    $safeText = [string]$Text
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $safeText = $safeText.Replace($ApiKey, '[已隐藏]')
    }
    $safeText = [regex]::Replace($safeText, '(?i)(Authorization\s*:\s*Bearer\s+)[^\s;,}]+', '$1[已隐藏]')
    $safeText = [regex]::Replace($safeText, '(?i)(Bearer\s+)[^\s;,}]+', '$1[已隐藏]')
    $safeText = [regex]::Replace($safeText, '(?i)(API\s*Key\s*[:=]\s*)[^\s;,}]+', '$1[已隐藏]')
    return $safeText
}

function Get-AliyunErrorDetails {
    param(
        $ErrorRecord,
        [string]$ApiKey
    )
    $exception = $ErrorRecord.Exception
    $message = [string]$exception.Message
    $body = $null
    try {
        $response = $null
        $responseException = $exception
        while ($responseException -and -not $response) {
            try { $response = $responseException.Response } catch {}
            $responseException = $responseException.InnerException
        }
        if ($response) {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object IO.StreamReader($stream)
                try {
                    $body = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            }
        }
    } catch {}
    $text = $message
    if (-not [string]::IsNullOrWhiteSpace($body)) { $text = "$message；$body" }
    $exceptionTypeNames = @()
    $webExceptionStatuses = @()
    $currentException = $exception
    while ($currentException) {
        $exceptionTypeNames += $currentException.GetType().FullName
        if ($currentException -is [Net.WebException]) {
            $webExceptionStatuses += [string]$currentException.Status
        }
        $currentException = $currentException.InnerException
    }
    return [pscustomobject]@{
        ExceptionTypeNames = $exceptionTypeNames
        WebExceptionStatuses = $webExceptionStatuses
        Message = Protect-AliyunErrorText $message $ApiKey
        Body = Protect-AliyunErrorText $body $ApiKey
        Text = Protect-AliyunErrorText $text $ApiKey
    }
}

function Get-AliyunErrorCategory {
    param($ErrorDetails)
    if (-not $ErrorDetails.PSObject.Properties['Text']) {
        $ErrorDetails = Get-AliyunErrorDetails $ErrorDetails
    }
    $message = [string]$ErrorDetails.Text
    if ($message -match '(?i)401|403|InvalidApiKey|AccessDenied|Unauthorized|API Key|鉴权') { return 'NonRetryable' }
    if ($message -match '(?i)429|Throttling|RateQuota|限流|too many requests') { return 'Retryable' }
    if ($message -match '(?i)quota|balance|Arrearage|欠费|额度|billing|insufficient') { return 'NonRetryable' }

    if ($ErrorDetails.WebExceptionStatuses -contains 'ConnectFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'ConnectionClosed' -or
        $ErrorDetails.WebExceptionStatuses -contains 'KeepAliveFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'NameResolutionFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'PipelineFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'ProxyNameResolutionFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'ReceiveFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'RequestCanceled' -or
        $ErrorDetails.WebExceptionStatuses -contains 'SendFailure' -or
        $ErrorDetails.WebExceptionStatuses -contains 'Timeout') {
        return 'Retryable'
    }
    if ($ErrorDetails.ExceptionTypeNames -contains 'System.Net.Http.HttpRequestException') {
        return 'Retryable'
    }
    if ($ErrorDetails.ExceptionTypeNames -contains 'System.Threading.Tasks.TaskCanceledException') {
        return 'Retryable'
    }

    if ($message -match '(?i)timed out|超时|timeout') { return 'Retryable' }
    if ($message -match '(?i)actively refused|forcibly closed|remote name could not be resolved|no such host|connection reset|connection refused|connection aborted|network is unreachable|transport connection|temporary|temporarily|network|网络|连接|NameResolution|Unable to connect|ServiceUnavailable|HttpRequestException|\b5\d\d\b') { return 'Retryable' }
    return 'NonRetryable'
}

function Get-AliyunErrorText {
    param(
        $ErrorDetails,
        [string]$ApiKey
    )
    if (-not $ErrorDetails.PSObject.Properties['Text']) {
        $ErrorDetails = Get-AliyunErrorDetails $ErrorDetails $ApiKey
    }
    $message = Protect-AliyunErrorText $ErrorDetails.Text $ApiKey
    if ($message -match '(?i)401|403|InvalidApiKey|AccessDenied|Unauthorized|API Key|鉴权') { return "阿里云鉴权失败，请重新输入API Key。详情：$message" }
    if ($message -match '(?i)429|Throttling|RateQuota|限流') { return "阿里云接口限流，请稍后重试。详情：$message" }
    if ($message -match '(?i)quota|balance|Arrearage|欠费|额度') { return "阿里云额度不足或账号欠费。详情：$message" }
    if ($message -match '(?i)timed out|超时|timeout') { return "阿里云请求超时。详情：$message" }
    return "阿里云请求失败：$message"
}

function Invoke-AliyunWithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [object[]]$ArgumentList = @(),
        [scriptblock]$SleepAction = { param([int]$Seconds) Start-Sleep -Seconds $Seconds },
        [string]$ApiKey
    )
    $delays = @(2, 5)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return & $Operation @ArgumentList
        } catch {
            $details = Get-AliyunErrorDetails $_ $ApiKey
            $category = Get-AliyunErrorCategory $details
            $message = Get-AliyunErrorText $details $ApiKey
            if ($category -ne 'Retryable' -or $attempt -eq 3) {
                throw $message
            }
            & $SleepAction $delays[$attempt - 1]
        }
    }
}

function Get-AliyunUploadPolicy {
    param([string]$ApiKey, [string]$Model = 'paraformer-v2', [int]$TimeoutSeconds = 30)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri = '{0}?action=getPolicy&model={1}' -f $script:UploadPolicyEndpoint, [Uri]::EscapeDataString($Model)
    try {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers (Get-AliyunHeaders $ApiKey) -TimeoutSec $TimeoutSeconds
    } catch {
        throw
    }
    if (-not $response.data -or -not $response.data.upload_host) {
        throw '阿里云没有返回有效的临时上传凭证。'
    }
    return $response.data
}

function Get-WindowsCurlPath {
    $systemCurl = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { $null } else { Join-Path $env:SystemRoot 'System32\curl.exe' }
    if ($systemCurl -and (Test-Path -LiteralPath $systemCurl -PathType Leaf)) {
        return [IO.Path]::GetFullPath($systemCurl)
    }
    $command = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and (Test-Path -LiteralPath $command.Path -PathType Leaf)) {
        return [IO.Path]::GetFullPath($command.Path)
    }
    throw '找不到Windows系统curl.exe。请在新电脑的“可选功能”中修复或安装系统curl，并确认curl.exe可从PATH运行。'
}

function New-AliyunCurlUploadCommand {
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string]$AudioPath,
        [Parameter(Mandatory = $true)][string]$CurlPath,
        [string]$FileName
    )
    if (-not (Test-Path -LiteralPath $AudioPath -PathType Leaf)) { throw "待上传音频不存在：$AudioPath" }
    if ([string]::IsNullOrWhiteSpace($FileName)) {
        $extension = [IO.Path]::GetExtension($AudioPath).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.wav' }
        $FileName = 'audio_{0}{1}' -f ([guid]::NewGuid().ToString('N')), $extension
    }
    $key = ([string]$Policy.upload_dir).TrimEnd('/') + '/' + $fileName
    $arguments = @(
        '--silent', '--show-error', '--location', '--fail', '--request', 'POST',
        '--form-string', ('OSSAccessKeyId={0}' -f [string]$Policy.oss_access_key_id),
        '--form-string', ('Signature={0}' -f [string]$Policy.signature),
        '--form-string', ('policy={0}' -f [string]$Policy.policy),
        '--form-string', ('x-oss-object-acl={0}' -f [string]$Policy.x_oss_object_acl),
        '--form-string', ('x-oss-forbid-overwrite={0}' -f [string]$Policy.x_oss_forbid_overwrite),
        '--form-string', ('key={0}' -f $key),
        '--form-string', 'success_action_status=200',
        '--form', ('file=@{0};type=application/octet-stream;filename={1}' -f $AudioPath, $FileName),
        [string]$Policy.upload_host
    )
    return [pscustomobject]@{
        FilePath = $CurlPath
        Arguments = $arguments
        OssUrl = "oss://$key"
    }
}

function Protect-AliyunUploadErrorText {
    param([string]$Text, $Policy)
    $safeText = Protect-AliyunErrorText $Text $null
    foreach ($value in @($Policy.signature, $Policy.policy, $Policy.oss_access_key_id)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $safeText = $safeText.Replace([string]$value, '[已隐藏]')
        }
    }
    if ([string]::IsNullOrWhiteSpace($safeText)) { return 'curl.exe未返回错误详情。' }
    if ($safeText.Length -gt 1000) { return $safeText.Substring(0, 1000) + '...' }
    return $safeText
}

function Send-AudioToTemporaryOss {
    param(
        [Parameter(Mandatory = $true)]$Policy,
        [Parameter(Mandatory = $true)][string]$AudioPath,
        [string]$CurlPath = (Get-WindowsCurlPath)
    )
    $command = New-AliyunCurlUploadCommand -Policy $Policy -AudioPath $AudioPath -CurlPath $CurlPath
    try {
        $curlOutput = @(& $command.FilePath @($command.Arguments) 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $safeError = Protect-AliyunUploadErrorText $_.Exception.Message $Policy
        throw "临时音频上传失败：curl.exe无法运行。详情：$safeError"
    }
    if ($exitCode -ne 0) {
        $safeError = Protect-AliyunUploadErrorText (($curlOutput | Out-String).Trim()) $Policy
        throw "临时音频上传失败：curl.exe退出码 $exitCode。详情：$safeError"
    }
    return $command.OssUrl
}

function Get-AliyunTaskState {
    param([Parameter(Mandatory = $true)]$Response)
    if ($Response.code) { throw "阿里云任务错误 $($Response.code)：$($Response.message)" }
    if (-not $Response.output) { throw '阿里云任务响应缺少output。' }
    $status = [string]$Response.output.task_status
    if ($status -in @('PENDING', 'RUNNING')) {
        return [pscustomobject]@{ Status = $status; TranscriptionUrl = $null; Duration = $null }
    }
    if ($status -ne 'SUCCEEDED') {
        throw "阿里云任务失败，状态：$status；$($Response.message)"
    }
    $result = @($Response.output.results)[0]
    if (-not $result) { throw '阿里云任务成功但没有返回子任务结果。' }
    if ([string]$result.subtask_status -ne 'SUCCEEDED') {
        throw "阿里云子任务失败 $($result.code)：$($result.message)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$result.transcription_url)) {
        throw '阿里云任务成功但没有返回转写结果地址。'
    }
    return [pscustomobject]@{
        Status = 'SUCCEEDED'
        TranscriptionUrl = [string]$result.transcription_url
        Duration = $Response.usage.duration
    }
}

function Submit-AliyunTask {
    param(
        [string]$ApiKey,
        [string]$OssUrl,
        [string]$Endpoint,
        [string]$Model,
        [int]$TimeoutSeconds
    )
    $Endpoint = Assert-AliyunEndpoint $Endpoint
    $payload = @{
        model = $Model
        input = @{ file_urls = @($OssUrl) }
        parameters = @{
            channel_id = @(0)
            language_hints = @('zh', 'en')
            timestamp_alignment_enabled = $true
            disfluency_removal_enabled = $false
        }
    } | ConvertTo-Json -Depth 8
    try {
        $response = Invoke-RestMethod -Method Post -Uri $Endpoint -Headers (Get-AliyunHeaders $ApiKey -Async -ResolveOss) -ContentType 'application/json' -Body $payload -TimeoutSec $TimeoutSeconds
    } catch {
        throw
    }
    if ($response.code) { throw "阿里云提交任务失败 $($response.code)：$($response.message)" }
    $taskId = [string]$response.output.task_id
    if ([string]::IsNullOrWhiteSpace($taskId)) { throw '阿里云没有返回任务ID。' }
    return $taskId
}

function Wait-AliyunTask {
    param(
        [string]$ApiKey,
        [string]$TaskId,
        [string]$Endpoint,
        [int]$TimeoutMinutes
    )
    $Endpoint = Assert-AliyunEndpoint $Endpoint
    $baseUri = $Endpoint.Substring(0, $Endpoint.IndexOf('/api/v1/'))
    $taskUri = "$baseUri/api/v1/tasks/$TaskId"
    $deadline = (Get-Date).AddMinutes([Math]::Max(1, $TimeoutMinutes))
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-RestMethod -Method Post -Uri $taskUri -Headers (Get-AliyunHeaders $ApiKey) -ContentType 'application/json' -TimeoutSec 30
        } catch {
            throw
        }
        $state = Get-AliyunTaskState $response
        if ($state.Status -eq 'SUCCEEDED') { return $state }
        Start-Sleep -Seconds 1
    }
    throw "阿里云识别超过 $TimeoutMinutes 分钟仍未完成。"
}

function Test-AliyunConnection {
    param(
        [string]$ApiKey = (Get-AliyunApiKey),
        [string]$Endpoint = $script:DefaultTranscriptionEndpoint,
        [string]$Model = 'paraformer-v2'
    )
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        return [pscustomobject]@{ Success = $false; Message = '尚未设置阿里云API Key。' }
    }
    try {
        $Endpoint = Assert-AliyunEndpoint $Endpoint
        [void](Get-AliyunUploadPolicy $ApiKey $Model 20)
        return [pscustomobject]@{ Success = $true; Message = '阿里云连接和API Key验证成功。'; Endpoint = $Endpoint }
    } catch {
        $details = Get-AliyunErrorDetails $_ $ApiKey
        return [pscustomobject]@{ Success = $false; Message = Get-AliyunErrorText $details $ApiKey }
    }
}

function Get-AliyunTranscriptionResult {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Net.Http.HttpClient]$HttpClient
    )
    $ownsClient = $null -eq $HttpClient
    if ($ownsClient) {
        $HttpClient = New-Object Net.Http.HttpClient
        $HttpClient.Timeout = [TimeSpan]::FromSeconds(60)
    }
    try {
        $bytes = $HttpClient.GetByteArrayAsync($Uri).GetAwaiter().GetResult()
        if ($null -eq $bytes -or $bytes.Length -eq 0) { throw '阿里云转写结果为空。' }
        $jsonText = [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimStart([char]0xFEFF)
        try {
            return $jsonText | ConvertFrom-Json
        } catch {
            throw "阿里云转写结果不是有效的UTF-8 JSON：$($_.Exception.Message)"
        }
    } finally {
        if ($ownsClient) { $HttpClient.Dispose() }
    }
}

function Invoke-AliyunTranscriptionOnce {
    param(
        [Parameter(Mandatory = $true)][string]$AudioPath,
        [string]$ApiKey = (Get-AliyunApiKey),
        [string]$Endpoint = $script:DefaultTranscriptionEndpoint,
        [string]$Model = 'paraformer-v2',
        [int]$TimeoutMinutes = 30
    )
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw '尚未设置阿里云API Key。' }
    $Endpoint = Assert-AliyunEndpoint $Endpoint
    $policy = Invoke-AliyunWithRetry -ApiKey $ApiKey -ArgumentList @($ApiKey, $Model) -Operation {
        param($key, $modelName)
        Get-AliyunUploadPolicy $key $modelName 30
    }
    $ossUrl = Invoke-AliyunWithRetry -ApiKey $ApiKey -ArgumentList @($policy, $AudioPath) -Operation {
        param($uploadPolicy, $path)
        Send-AudioToTemporaryOss $uploadPolicy $path
    }
    $taskId = Invoke-AliyunWithRetry -ApiKey $ApiKey -ArgumentList @($ApiKey, $ossUrl, $Endpoint, $Model) -Operation {
        param($key, $uploadedUrl, $taskEndpoint, $modelName)
        Submit-AliyunTask $key $uploadedUrl $taskEndpoint $modelName 30
    }
    $state = Invoke-AliyunWithRetry -ApiKey $ApiKey -ArgumentList @($ApiKey, $taskId, $Endpoint, $TimeoutMinutes) -Operation {
        param($key, $id, $taskEndpoint, $timeout)
        Wait-AliyunTask $key $id $taskEndpoint $timeout
    }
    return Invoke-AliyunWithRetry -ApiKey $ApiKey -ArgumentList @($state.TranscriptionUrl) -Operation {
        param($resultUrl)
        Get-AliyunTranscriptionResult -Uri $resultUrl
    }
}

function Invoke-AliyunTranscription {
    param(
        [Parameter(Mandatory = $true)][string]$AudioPath,
        [string]$ApiKey = (Get-AliyunApiKey),
        [string]$Endpoint = $script:DefaultTranscriptionEndpoint,
        [string]$Model = 'paraformer-v2',
        [int]$TimeoutMinutes = 30
    )
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw '尚未设置阿里云API Key。' }
    $Endpoint = Assert-AliyunEndpoint $Endpoint
    Invoke-AliyunTranscriptionOnce -AudioPath $AudioPath -ApiKey $ApiKey -Endpoint $Endpoint -Model $Model -TimeoutMinutes $TimeoutMinutes
}

Export-ModuleMember -Function @(
    'Save-AliyunApiKey',
    'Get-AliyunApiKey',
    'Remove-AliyunApiKey',
    'Assert-AliyunEndpoint',
    'Get-WindowsCurlPath',
    'Test-AliyunConnection',
    'Invoke-AliyunTranscription'
)
