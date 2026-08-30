# Keep this file as UTF-8 with BOM for Windows PowerShell 5.1.
# Copy this file to config.ps1 on a new machine, then adjust paths and options.
# Do not commit config.ps1: it is the local user's runtime configuration.

$AutoCutRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$VideoDir = Join-Path $AutoCutRoot "视频位置"
$AudioDir = Join-Path $AutoCutRoot "音频位置"
$OutputDir = Join-Path $AutoCutRoot "完成"
$WorkDir = Join-Path $AutoCutRoot "work"
$EnableSubtitles = $true
$SubtitleSourceMode = 'paraformer_local'
$AliyunSubtitlesEnabled = $true
$AliyunModel = 'paraformer-v2'
$AliyunEndpoint = 'https://llm-5kjnipnd09ocidvh.cn-beijing.maas.aliyuncs.com/api/v1'
$AliyunTimeoutMinutes = 30
$WhisperModel = 'tiny'
$WhisperLanguage = 'zh'
$WhisperThreads = 4

$FastSinglePass = $true
$VideosPerAudio = 6
$ParallelRenders = 6
$SupplementRetryRounds = 3
$PreferFastVideoSources = $true
$ClipMode = 'random'
$MinClipSeconds = 30
$MaxClipSeconds = 30
$MinimumShortClipSeconds = 3
$OrientationSampleLimit = 24
$ImageDurationSeconds = 6
$EnableImageEffects = $true
$EnableAtmosphereEffects = $true
$AtmosphereEffectMode = 'random'
$TestSeconds = 10
$Fps = 30
$VideoCrf = 26
$VideoPreset = 'veryfast'
$PreferredVideoEncoder = 'auto'
$AudioBitrate = '192k'

$SubtitleMarginV = 30
$SubtitleMarginVPortrait = 30
$SubtitleMarginVLandscape = 30
$SubtitleFontSize = 16
$SubtitleFontName = 'Microsoft YaHei UI'
$SubtitleFontFile = ''
$SubtitleColor = 'FFFFFF'
$SubtitleOutlineColor = '000000'
$SubtitleOutline = 2
$SubtitleMaxCharsPerLine = 0
$SubtitleMinChars = 6
$SubtitleSafeWidthPercent = 94
$SubtitleMinimumDuration = 0.8
$ParaformerTimelineChunkSeconds = 60
$ParaformerTimelineChunkOverlapSeconds = 1

$OutputMode = 'auto'
$PortraitWidth = 1080
$PortraitHeight = 1920
$LandscapeWidth = 1920
$LandscapeHeight = 1080
$OverwriteOutput = $true

$UnimportantLogRetentionHours = 24
$ImportantLogRetentionDays = 7
$SoftwareBackupKeepCount = 5
$FailedWorkRetentionHours = 24
