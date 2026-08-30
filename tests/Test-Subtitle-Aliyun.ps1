$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test-Helpers.ps1"

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Subtitle-Aliyun.psm1'
Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) 'Subtitle-Aliyun.psm1 必须存在'
Import-Module $modulePath -Force

foreach ($name in @(
    'Save-AliyunApiKey',
    'Get-AliyunApiKey',
    'Remove-AliyunApiKey',
    'Assert-AliyunEndpoint',
    'Get-WindowsCurlPath',
    'Test-AliyunConnection',
    'Invoke-AliyunTranscription'
)) {
    Assert-True ($null -ne (Get-Command $name -ErrorAction SilentlyContinue)) "必须导出函数 $name"
}

$tempRoot = Join-Path $env:TEMP ("autocut_aliyun_test_{0}" -f ([guid]::NewGuid().ToString('N')))
$keyPath = Join-Path $tempRoot 'aliyun-key.dat'
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $plainKey = 'sk-test-secret-value-123456'
    Save-AliyunApiKey -ApiKey $plainKey -KeyPath $keyPath
    Assert-True (Test-Path -LiteralPath $keyPath -PathType Leaf) '加密密钥文件必须生成'
    $onDisk = [IO.File]::ReadAllText($keyPath)
    Assert-True (-not $onDisk.Contains($plainKey)) '磁盘文件不得包含明文API Key'
    Assert-Equal $plainKey (Get-AliyunApiKey -KeyPath $keyPath) 'DPAPI加密密钥必须可以由当前用户解密'
    Remove-AliyunApiKey -KeyPath $keyPath
    Assert-True (-not (Test-Path -LiteralPath $keyPath)) '删除密钥后文件必须不存在'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$module = Get-Module Subtitle-Aliyun

$wrongCharsetHandlerType = 'WrongCharsetAliyunJsonHandler' -as [type]
if (-not $wrongCharsetHandlerType) {
    Add-Type -ReferencedAssemblies 'System.Net.Http' -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public sealed class WrongCharsetAliyunJsonHandler : HttpMessageHandler
{
    private readonly byte[] body;
    public string DeclaredCharset { get { return "iso-8859-1"; } }

    public WrongCharsetAliyunJsonHandler(string json)
    {
        var encoding = new UTF8Encoding(true);
        var preamble = encoding.GetPreamble();
        var content = new UTF8Encoding(false).GetBytes(json);
        body = new byte[preamble.Length + content.Length];
        Buffer.BlockCopy(preamble, 0, body, 0, preamble.Length);
        Buffer.BlockCopy(content, 0, body, preamble.Length, content.Length);
    }

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var response = new HttpResponseMessage(HttpStatusCode.OK);
        response.Content = new ByteArrayContent(body);
        response.Content.Headers.ContentType = new MediaTypeHeaderValue("text/plain");
        response.Content.Headers.ContentType.CharSet = "iso-8859-1";
        return Task.FromResult(response);
    }
}
'@
}

$utf8Json = '{"transcripts":[{"text":"测试原始中文","sentences":[{"begin_time":0,"end_time":1000,"text":"测试原始中文","words":[]}]}]}'
$wrongCharsetClient = New-Object Net.Http.HttpClient([WrongCharsetAliyunJsonHandler]::new($utf8Json))
try {
    $rawResultError = $null
    $rawResult = $null
    try {
        $rawResult = & $module {
            param($client)
            Get-AliyunTranscriptionResult -Uri 'https://result.example/wrong-content-type.json' -HttpClient $client
        } $wrongCharsetClient
    } catch {
        $rawResultError = $_.Exception.Message
    }
    Assert-True ([string]::IsNullOrWhiteSpace($rawResultError)) '错误Content-Type的Aliyun结果必须按原始UTF-8字节成功解析'
    Assert-Equal '测试原始中文' ([string]$rawResult.transcripts[0].sentences[0].text) '结果下载不得依Content-Type错误编码产生mojibake'

    $corePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Subtitle-Core.psm1'
    Import-Module $corePath -Force -DisableNameChecking
    $rawSrtPath = Join-Path $env:TEMP ('autocut_raw_utf8_result_' + [guid]::NewGuid().ToString('N') + '.srt')
    try {
        $rawSegments = @(Subtitle-Core\Convert-AliyunResultToSegments `
            -AliyunResult $rawResult `
            -AudioDuration 1.0 `
            -SplitOptions @{ FontName='Microsoft YaHei'; FontSize=16; FrameWidth=1080; FrameHeight=1920; Outline=2; SafeWidthPercent=84; MaxChars=0; MinChars=1 })
        Subtitle-Core\New-SrtFromSegments -Segments $rawSegments -Destination $rawSrtPath
        $rawSrtText = [IO.File]::ReadAllText($rawSrtPath, [Text.Encoding]::UTF8)
        Assert-True ($rawSrtText -match '测试原始中文') '错误Content-Type场景生成的实际SRT必须保留原始中文'
        Assert-True ($rawSrtText -notmatch 'æ²|è¯|åŽŸ|ä¸­|æ–‡|Ã|Â') '错误Content-Type场景生成的实际SRT不得包含常见mojibake'
    } finally {
        Remove-Item -LiteralPath $rawSrtPath -Force -ErrorAction SilentlyContinue
    }
} finally {
    $wrongCharsetClient.Dispose()
}

$curlTestRoot = Join-Path $env:TEMP ("autocut_curl_upload_test_{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $curlTestRoot -Force | Out-Null
try {
    $curlAudioPath = Join-Path $curlTestRoot 'audio sample.wav'
    [IO.File]::WriteAllBytes($curlAudioPath, [byte[]](1,2,3,4))
    $curlPolicy = [pscustomobject]@{
        upload_host = 'https://oss-upload.example'
        upload_dir = 'upload-dir'
        oss_access_key_id = 'oss-access-secret'
        signature = 'signature-secret'
        policy = 'policy-secret'
        x_oss_object_acl = 'private'
        x_oss_forbid_overwrite = 'true'
    }
    $dashScopeApiKey = 'sk-command-secret-123456'
    $curlCommand = & $module {
        param($policy, $audio, $curlPath)
        New-AliyunCurlUploadCommand -Policy $policy -AudioPath $audio -CurlPath $curlPath -FileName 'audio_fixed.wav'
    } $curlPolicy $curlAudioPath 'C:\Windows\System32\curl.exe'
    Assert-Equal 'C:\Windows\System32\curl.exe' $curlCommand.FilePath '上传命令必须使用发现到的Windows curl.exe'
    Assert-Equal 'oss://upload-dir/audio_fixed.wav' $curlCommand.OssUrl '上传命令必须返回对应OSS对象地址'
    Assert-Equal 'https://oss-upload.example' $curlCommand.Arguments[-1] 'curl上传URL必须使用policy返回的upload_host'
    foreach ($option in @('--silent','--show-error','--location','--fail')) {
        Assert-True ($curlCommand.Arguments -contains $option) "curl上传命令必须包含兼容参数：$option"
    }
    Assert-True ($curlCommand.Arguments -notcontains '--fail-with-body') 'curl上传命令不得依赖7.76才支持的--fail-with-body'

    $formValues = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $curlCommand.Arguments.Count - 1; $i++) {
        if ($curlCommand.Arguments[$i] -in @('--form','--form-string')) {
            [void]$formValues.Add([string]$curlCommand.Arguments[$i + 1])
        }
    }
    foreach ($field in @('OSSAccessKeyId','Signature','policy','x-oss-object-acl','x-oss-forbid-overwrite','key','success_action_status','file')) {
        Assert-True ($formValues -match ("^$([regex]::Escape($field))=")) "curl multipart必须包含OSS字段：$field"
    }
    Assert-True ($formValues[-1] -match '^file=@') 'curl multipart的file字段必须最后添加'
    Assert-True (($curlCommand.Arguments -join "`n") -notmatch [regex]::Escape($dashScopeApiKey)) 'curl上传命令参数不得包含DashScope API Key'

    $fakeCurlPath = Join-Path $curlTestRoot 'fake-curl.cmd'
    [IO.File]::WriteAllText(
        $fakeCurlPath,
        "@echo off`r`necho Signature=signature-secret policy=policy-secret OSSAccessKeyId=oss-access-secret API Key=$dashScopeApiKey 1^>^&2`r`nexit /b 22`r`n",
        [Text.Encoding]::ASCII
    )
    $curlFailureMessage = $null
    try {
        & $module {
            param($policy, $audio, $curlPath)
            Send-AudioToTemporaryOss -Policy $policy -AudioPath $audio -CurlPath $curlPath
        } $curlPolicy $curlAudioPath $fakeCurlPath | Out-Null
    } catch {
        $curlFailureMessage = $_.Exception.Message
    }
    Assert-True ($curlFailureMessage -match 'curl.*退出码.*22') 'curl非0退出必须生成包含退出码的中文上传错误'
    foreach ($secret in @('signature-secret','policy-secret','oss-access-secret',$dashScopeApiKey)) {
        Assert-True (-not $curlFailureMessage.Contains($secret)) 'curl失败错误不得泄露签名、policy、OSS访问标识或API Key'
    }
} finally {
    Remove-Item -LiteralPath $curlTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$transcriptionPath = '/api/v1/services/audio/asr/transcription'
$endpointCases = @(
    @{ Input = 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription'; Expected = 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription' },
    @{ Input = 'https://dashscope.aliyuncs.com/api/v1'; Expected = 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription' },
    @{ Input = 'https://llm-workspace-placeholder.cn-beijing.maas.aliyuncs.com/api/v1'; Expected = 'https://llm-workspace-placeholder.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription' },
    @{ Input = 'https://workspace-1.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription'; Expected = 'https://workspace-1.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription' }
)
foreach ($case in $endpointCases) {
    $validated = Assert-AliyunEndpoint -Endpoint $case.Input
    Assert-Equal $case.Expected $validated '官方HTTPS基础地址必须规范化，完整转写地址必须保持不变'
}

foreach ($endpoint in @(
    'http://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription',
    'http://dashscope.aliyuncs.com/api/v1',
    'https://evil.example/api/v1/services/audio/asr/transcription',
    'https://evil.example/api/v1',
    'https://dashscope.aliyuncs.com/api/v2',
    'https://dashscope.aliyuncs.com/api/v1/apps/steal/completion',
    'https://dashscope.aliyuncs.com:444/api/v1/services/audio/asr/transcription'
)) {
    $endpointMessage = $null
    try { Assert-AliyunEndpoint -Endpoint $endpoint | Out-Null } catch { $endpointMessage = $_.Exception.Message }
    Assert-True ($endpointMessage -match '官方|HTTPS|端点') "非官方端点必须被拒绝：$endpoint"
}

$endpointNetworkState = [pscustomobject]@{ Calls = 0 }
$endpointRuntimeMessage = & $module {
    param($state)
    function Invoke-RestMethod { $state.Calls++; throw '不应发起网络请求' }
    try {
        try {
            Submit-AliyunTask -ApiKey 'sk-secret' -OssUrl 'oss://audio' -Endpoint 'https://evil.example/api/v1/services/audio/asr/transcription' -Model 'paraformer-v2' -TimeoutSeconds 1 | Out-Null
        } catch {
            return $_.Exception.Message
        }
    } finally {
        Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }
} $endpointNetworkState
Assert-Equal 0 $endpointNetworkState.Calls '运行时必须在发送Authorization前拒绝恶意端点'
Assert-True ($endpointRuntimeMessage -match '官方|端点') '运行时端点拒绝必须给出清晰错误'

$normalizedRuntimeState = [pscustomobject]@{ Calls = 0; Uri = '' }
$normalizedTaskId = & $module {
    param($state)
    function Invoke-RestMethod {
        param($Method, $Uri, $Headers, $ContentType, $Body, $TimeoutSec)
        $state.Calls++
        $state.Uri = [string]$Uri
        return [pscustomobject]@{ output = [pscustomobject]@{ task_id = 'task-normalized' } }
    }
    try {
        Submit-AliyunTask -ApiKey 'sk-placeholder' -OssUrl 'oss://audio' -Endpoint 'https://llm-runtime-placeholder.cn-beijing.maas.aliyuncs.com/api/v1' -Model 'paraformer-v2' -TimeoutSeconds 1
    } finally {
        Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }
} $normalizedRuntimeState
Assert-Equal 'task-normalized' $normalizedTaskId '运行时基础地址规范化后必须正常提交任务'
Assert-Equal 1 $normalizedRuntimeState.Calls '运行时基础地址只应提交一次'
Assert-Equal 'https://llm-runtime-placeholder.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription' $normalizedRuntimeState.Uri '运行时必须把基础地址规范化为完整转写URL'

$connectionEndpointState = [pscustomobject]@{ Calls = 0 }
$connectionEndpointResult = & $module {
    param($state)
    function Get-AliyunUploadPolicy { $state.Calls++; throw '不应请求上传凭证' }
    try {
        Test-AliyunConnection -ApiKey 'sk-secret' -Endpoint 'https://evil.example/api/v1/services/audio/asr/transcription'
    } finally {
        Remove-Item Function:\Get-AliyunUploadPolicy -ErrorAction SilentlyContinue
    }
} $connectionEndpointState
Assert-True (-not $connectionEndpointResult.Success) '连接测试必须拒绝恶意任务端点'
Assert-Equal 0 $connectionEndpointState.Calls '连接测试必须先校验当前端点再发送Authorization'

$connectionBaseState = [pscustomobject]@{ Calls = 0 }
$connectionBaseResult = & $module {
    param($state)
    function Get-AliyunUploadPolicy {
        $state.Calls++
        return [pscustomobject]@{ upload_host = 'https://oss.example' }
    }
    try {
        Test-AliyunConnection -ApiKey 'sk-placeholder' -Endpoint 'https://llm-connection-placeholder.cn-beijing.maas.aliyuncs.com/api/v1'
    } finally {
        Remove-Item Function:\Get-AliyunUploadPolicy -ErrorAction SilentlyContinue
    }
} $connectionBaseState
Assert-True $connectionBaseResult.Success '连接测试必须接受官方workspace的/api/v1基础地址'
Assert-Equal 1 $connectionBaseState.Calls '连接测试规范化基础地址后必须继续API Key检查'
Assert-Equal 'https://llm-connection-placeholder.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription' $connectionBaseResult.Endpoint '连接测试成功结果必须使用并返回规范化后的完整端点'

$categoryCases = @(
    @{ Name = '鉴权失败'; Message = '阿里云鉴权失败，请重新输入API Key。'; Expected = 'NonRetryable' },
    @{ Name = 'API Key无效'; Message = 'InvalidApiKey: API Key无效。'; Expected = 'NonRetryable' },
    @{ Name = '账号欠费'; Message = '阿里云账号欠费。'; Expected = 'NonRetryable' },
    @{ Name = '额度不足'; Message = '阿里云额度不足。'; Expected = 'NonRetryable' },
    @{ Name = '接口限流'; Message = '阿里云接口限流，请稍后重试。'; Expected = 'Retryable' },
    @{ Name = 'HTTP 500'; Message = 'HTTP 500 Internal Server Error'; Expected = 'Retryable' },
    @{ Name = 'HTTP 599'; Message = 'HTTP 599 Network Connect Timeout'; Expected = 'Retryable' },
    @{ Name = '请求超时'; Message = '阿里云请求超时。'; Expected = 'Retryable' },
    @{ Name = '临时网络错误'; Message = '临时网络连接失败，请稍后重试。'; Expected = 'Retryable' }
)
foreach ($case in $categoryCases) {
    $errorRecord = [pscustomobject]@{ Exception = [Exception]::new($case.Message) }
    $category = & $module { param($value) Get-AliyunErrorCategory $value } $errorRecord
    Assert-Equal $case.Expected $category "$($case.Name)分类必须正确"
}

$sleepDelays = New-Object 'System.Collections.Generic.List[int]'
$sleepAction = {
    param([int]$Seconds)
    [void]$sleepDelays.Add($Seconds)
}.GetNewClosure()

$connectionExceptionCases = @(
    @{ Name = '连接被拒绝'; Exception = [Net.WebException]::new('No connection could be made because the target machine actively refused it.', [Net.WebExceptionStatus]::ConnectFailure) },
    @{ Name = '连接被关闭'; Exception = [Net.WebException]::new('An existing connection was forcibly closed by the remote host.', [Net.WebExceptionStatus]::ConnectionClosed) },
    @{ Name = 'HTTP客户端连接错误'; Exception = [Net.Http.HttpRequestException]::new('An error occurred while sending the request.') },
    @{ Name = 'HTTP客户端任务取消'; Exception = [Threading.Tasks.TaskCanceledException]::new('A task was canceled.') }
)
foreach ($case in $connectionExceptionCases) {
    $errorRecord = [pscustomobject]@{ Exception = $case.Exception }
    $category = & $module { param($value) Get-AliyunErrorCategory $value } $errorRecord
    Assert-Equal 'Retryable' $category "$($case.Name)必须可重试"
}

$executionApiKey = 'sk-execution-secret-123456'
$executionState = [pscustomobject]@{ Calls = 0 }
$executionDelays = New-Object 'System.Collections.Generic.List[int]'
$executionSleep = {
    param([int]$Seconds)
    [void]$executionDelays.Add($Seconds)
}.GetNewClosure()
$executionOperation = {
    & $module {
        param($key)
        Get-AliyunUploadPolicy -ApiKey $key -Model 'paraformer-v2' -TimeoutSeconds 1
    } $executionApiKey
}.GetNewClosure()
$executionMessage = $null
$executionResult = & $module {
    param($state, $sleep, $key, $operation)
    function Invoke-RestMethod {
        $state.Calls++
        throw [Net.WebException]::new(
            "ReceiveFailure Authorization: Bearer $key",
            $null,
            [Net.WebExceptionStatus]::ReceiveFailure,
            $null
        )
    }
    try {
        try {
            Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep -ApiKey $key | Out-Null
        } catch {
            return [pscustomobject]@{ Message = $_.Exception.Message }
        }
    } finally {
        Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    }
} $executionState $executionSleep $executionApiKey $executionOperation
$executionMessage = $executionResult.Message
Assert-Equal 3 $executionState.Calls '实际网络步骤的临时连接错误必须由外层重试三次'
Assert-Equal '2,5' ($executionDelays -join ',') '实际网络步骤的重试退避必须为2秒和5秒'
Assert-True (-not $executionMessage.Contains($executionApiKey)) '实际网络步骤错误不得泄露API Key'
Assert-True ($executionMessage -match '请求失败') '实际网络步骤必须保留中文错误信息'

$task5ResponseType = 'Task5WebResponse' -as [type]
if (-not $task5ResponseType) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;

public sealed class Task5WebResponse : WebResponse
{
    private readonly byte[] body;
    public int ReadCount { get; private set; }

    public Task5WebResponse(string text)
    {
        body = Encoding.UTF8.GetBytes(text);
    }

    public override Stream GetResponseStream()
    {
        ReadCount++;
        return new MemoryStream(body, false);
    }
}
'@
}
$task5ResponseBody = '{"code":"Throttling.RateQuota"}'
$task5ResponseList = New-Object 'System.Collections.Generic.List[object]'
$task5ResponseRetryState = [pscustomobject]@{ Count = 0 }
$task5ResponseRetryOperation = {
    $task5ResponseRetryState.Count++
    $task5Response = [Task5WebResponse]::new($task5ResponseBody)
    [void]$task5ResponseList.Add($task5Response)
    $task5Exception = [Net.WebException]::new('HTTP 500', $null, [Net.WebExceptionStatus]::ProtocolError, $task5Response)
    throw $task5Exception
}.GetNewClosure()
$task5ResponseRetryMessage = $null
try {
    & $module {
        param($operation, $sleep)
        Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep
    } $task5ResponseRetryOperation $sleepAction | Out-Null
} catch {
    $task5ResponseRetryMessage = $_.Exception.Message
}
Assert-Equal 3 $task5ResponseRetryState.Count '响应体中的限流错误必须重试三次'
$task5ResponseReadCount = ($task5ResponseList | ForEach-Object ReadCount | Measure-Object -Sum).Sum
Assert-Equal 3 $task5ResponseReadCount '每次失败只能读取响应流一次'
Assert-True ($task5ResponseRetryMessage -match '限流') '响应体错误码必须保留清晰中文错误'

$apiKey = 'sk-test-secret-value-123456'
$secretException = [Exception]::new("HTTP 401 Authorization: Bearer $apiKey; API Key=$apiKey")
$secretRecord = [pscustomobject]@{ Exception = $secretException }
$secretDetails = & $module {
    param($record, $key)
    Get-AliyunErrorDetails $record $key
} $secretRecord $apiKey
$secretDetailsText = "$($secretDetails.Message) $($secretDetails.Body) $($secretDetails.Text)"
Assert-True (-not $secretDetailsText.Contains($apiKey)) '结构化错误详情不得泄露API Key'
Assert-True ($secretDetailsText -notmatch '(?i)Bearer\s+sk-') '结构化错误详情不得泄露Bearer凭据'
Assert-True (-not ([string]($secretDetails | Out-String)).Contains($apiKey)) '结构化错误对象不得携带原始API Key'
$secretOperation = {
    throw $secretException
}.GetNewClosure()
$secretMessage = $null
try {
    & $module {
        param($operation, $sleep, $key)
        Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep -ApiKey $key
    } $secretOperation $sleepAction $apiKey | Out-Null
} catch {
    $secretMessage = $_.Exception.Message
}
Assert-True (-not $secretMessage.Contains($apiKey)) '错误详情不得泄露API Key'
Assert-True ($secretMessage -notmatch '(?i)Bearer\s+sk-') '错误详情不得泄露Bearer凭据'
Assert-True ($secretMessage -match '鉴权失败') '脱敏后仍必须保留中文错误摘要'

$sleepDelays.Clear()
$transientState = [pscustomobject]@{ Count = 0 }
$transientOperation = {
    $transientState.Count++
    if ($transientState.Count -lt 3) { throw '临时网络连接失败。' }
    return '识别成功'
}.GetNewClosure()
$retryResult = & $module {
    param($operation, $sleep)
    Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep
} $transientOperation $sleepAction
Assert-Equal '识别成功' $retryResult '临时错误第三次重试必须成功'
Assert-Equal 3 $transientState.Count '临时错误最多应尝试三次'
Assert-Equal '2,5' ($sleepDelays -join ',') '重试退避必须为2秒和5秒'

$workflowRetryState = [pscustomobject]@{
    PolicyCalls = 0
    UploadCalls = 0
    SubmitCalls = 0
    WaitCalls = 0
    DownloadCalls = 0
    TaskIds = New-Object 'System.Collections.Generic.List[string]'
}
$workflowResult = & $module {
    param($state)
    $script:workflowRetryProbeState = $state
    function Start-Sleep {}
    function Get-AliyunUploadPolicy { $script:workflowRetryProbeState.PolicyCalls++; return [pscustomobject]@{ upload_host = 'https://oss.example' } }
    function Send-AudioToTemporaryOss { $script:workflowRetryProbeState.UploadCalls++; return 'oss://audio-key' }
    function Submit-AliyunTask { $script:workflowRetryProbeState.SubmitCalls++; return 'task-1' }
    function Wait-AliyunTask {
        param($ApiKey, $TaskId)
        $script:workflowRetryProbeState.WaitCalls++
        [void]$script:workflowRetryProbeState.TaskIds.Add($TaskId)
        if ($script:workflowRetryProbeState.WaitCalls -eq 1) { throw 'HTTP 500 Internal Server Error' }
        return [pscustomobject]@{ TranscriptionUrl = 'https://result.example/result.json' }
    }
    function Get-AliyunTranscriptionResult { $script:workflowRetryProbeState.DownloadCalls++; return [pscustomobject]@{ transcripts = @() } }
    try {
        Invoke-AliyunTranscription -AudioPath 'audio.wav' -ApiKey 'sk-secret' -Endpoint 'https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription'
    } finally {
        foreach ($name in @('Start-Sleep','Get-AliyunUploadPolicy','Send-AudioToTemporaryOss','Submit-AliyunTask','Wait-AliyunTask','Get-AliyunTranscriptionResult')) {
            Remove-Item "Function:\$name" -ErrorAction SilentlyContinue
        }
        Remove-Variable workflowRetryProbeState -Scope Script -ErrorAction SilentlyContinue
    }
} $workflowRetryState
Assert-Equal 1 $workflowRetryState.PolicyCalls '轮询重试不得重新获取上传凭证'
Assert-Equal 1 $workflowRetryState.UploadCalls '轮询重试不得重新上传音频'
Assert-Equal 1 $workflowRetryState.SubmitCalls '拿到task ID后不得重复提交阿里云任务'
Assert-Equal 2 $workflowRetryState.WaitCalls '临时轮询失败必须使用同一task ID重试'
Assert-Equal 'task-1,task-1' ($workflowRetryState.TaskIds -join ',') '轮询重试必须保留同一task ID'
Assert-Equal 1 $workflowRetryState.DownloadCalls '轮询成功后只下载一次结果'
Assert-True ($null -ne $workflowResult) '保留任务身份的重试必须返回识别结果'

$sleepDelays.Clear()
$authState = [pscustomobject]@{ Count = 0 }
$authOperation = {
    $authState.Count++
    throw '阿里云鉴权失败，请重新输入API Key。'
}.GetNewClosure()
$authMessage = $null
try {
    & $module {
        param($operation, $sleep)
        Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep
    } $authOperation $sleepAction | Out-Null
} catch {
    $authMessage = $_.Exception.Message
}
Assert-Equal 1 $authState.Count '鉴权错误必须立即失败且不得重试'
Assert-Equal '' ($sleepDelays -join ',') '鉴权错误不得新增退避等待'
Assert-True ($authMessage -match '鉴权失败') '鉴权错误必须保留清晰中文信息'

$sleepDelays.Clear()
$limitState = [pscustomobject]@{ Count = 0 }
$limitOperation = {
    $limitState.Count++
    throw '阿里云接口限流，请稍后重试。'
}.GetNewClosure()
$limitMessage = $null
try {
    & $module {
        param($operation, $sleep)
        Invoke-AliyunWithRetry -Operation $operation -SleepAction $sleep
    } $limitOperation $sleepAction | Out-Null
} catch {
    $limitMessage = $_.Exception.Message
}
Assert-Equal 3 $limitState.Count '限流错误第三次失败后必须停止重试'
Assert-Equal '2,5' ($sleepDelays -join ',') '第三次失败后不得继续退避'
Assert-True ($limitMessage -match '限流') '限流错误必须保留清晰中文信息'

$pending = & $module { Get-AliyunTaskState ([pscustomobject]@{ output = [pscustomobject]@{ task_status = 'PENDING' } }) }
Assert-Equal 'PENDING' $pending.Status 'PENDING响应必须继续等待'

$succeededResponse = [pscustomobject]@{
    output = [pscustomobject]@{
        task_status = 'SUCCEEDED'
        results = @([pscustomobject]@{
            subtask_status = 'SUCCEEDED'
            transcription_url = 'https://example.invalid/result.json'
        })
    }
    usage = [pscustomobject]@{ duration = 9 }
}
$succeeded = & $module { param($value) Get-AliyunTaskState $value } $succeededResponse
Assert-Equal 'SUCCEEDED' $succeeded.Status '成功响应必须识别为SUCCEEDED'
Assert-Equal 'https://example.invalid/result.json' $succeeded.TranscriptionUrl '成功响应必须返回结果地址'
Assert-Equal 9 $succeeded.Duration '成功响应必须保留计费语音时长'

$failedResponse = [pscustomobject]@{
    output = [pscustomobject]@{
        task_status = 'SUCCEEDED'
        results = @([pscustomobject]@{
            subtask_status = 'FAILED'
            code = 'InvalidFile.DownloadFailed'
            message = 'cannot download'
        })
    }
}
$failedMessage = $null
try {
    & $module { param($value) Get-AliyunTaskState $value } $failedResponse | Out-Null
} catch {
    $failedMessage = $_.Exception.Message
}
Assert-True ($failedMessage -match 'InvalidFile.DownloadFailed') '子任务失败必须包含阿里云错误码'

$moduleText = [IO.File]::ReadAllText($modulePath, [Text.Encoding]::UTF8)
$transcriptionOnceStart = $moduleText.IndexOf('function Invoke-AliyunTranscriptionOnce')
$transcriptionOnceEnd = $moduleText.IndexOf('function Invoke-AliyunTranscription', $transcriptionOnceStart + 1)
$transcriptionOnceFunction = if ($transcriptionOnceStart -ge 0 -and $transcriptionOnceEnd -gt $transcriptionOnceStart) {
    $moduleText.Substring($transcriptionOnceStart, $transcriptionOnceEnd - $transcriptionOnceStart)
} else { '' }
Assert-True (-not [string]::IsNullOrWhiteSpace($transcriptionOnceFunction)) '必须找到单次阿里云转写工作流源码'
Assert-True ($transcriptionOnceFunction -match 'Get-AliyunTranscriptionResult') '转写结果阶段必须调用原始字节UTF-8下载入口'
Assert-True ($transcriptionOnceFunction -notmatch 'Invoke-RestMethod') '转写结果URL不得再由Invoke-RestMethod按错误Content-Type解码'
Assert-True ($moduleText -match 'X-DashScope-Async') '提交任务必须启用异步请求头'
Assert-True ($moduleText -match 'X-DashScope-OssResourceResolve') '临时OSS地址必须启用解析请求头'
Assert-True ($moduleText -match 'timestamp_alignment_enabled') 'Paraformer必须启用时间戳校准'
Assert-True ($moduleText -match 'curl\.exe') '本地音频必须使用Windows系统curl.exe上传临时OSS'
Assert-True ($moduleText -notmatch 'MultipartFormDataContent') '正式上传不得继续使用已确认失败的.NET MultipartFormDataContent'
Assert-True ($moduleText -notmatch 'sk-[A-Za-z0-9]{8,}') '模块中不得写死API Key'

Write-Host 'PASS Test-Subtitle-Aliyun' -ForegroundColor Green
