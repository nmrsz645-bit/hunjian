using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Collections.Concurrent;

namespace AutoCutDesktop;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        var appRoot = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        var installRoot = Directory.GetParent(appRoot)?.FullName;
        var launchedByStarter = string.Equals(Environment.GetEnvironmentVariable("HUNJIAN_LAUNCHED_BY_STARTER"), "1", StringComparison.Ordinal);
        var starter = installRoot is null ? null : Path.Combine(installRoot, "Start.cmd");
        var updaterConfig = installRoot is null ? null : Path.Combine(installRoot, "updater", "updater-config.json");
        if (!launchedByStarter && starter is not null && updaterConfig is not null && File.Exists(starter) && File.Exists(updaterConfig))
        {
            Process.Start(new ProcessStartInfo(starter) { WorkingDirectory = installRoot, UseShellExecute = true });
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
    }
}

internal sealed class MainForm : Form
{
    private const int RuntimeLogLineLimit = 500;
    private const int PendingRuntimeLogLimit = 1000;
    private readonly string _root = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    private readonly string _configPath;
    private readonly TextBox _runtimeLog = NewLogBox();
    private readonly TextBox _fileLog = NewLogBox();
    private readonly Label _monitorState = NewValueLabel();
    private readonly Label _currentAudio = NewValueLabel();
    private readonly Label _startTime = NewValueLabel();
    private readonly Label _completed = NewValueLabel();
    private readonly Label _todayCompleted = NewValueLabel();
    private readonly Label _failed = NewValueLabel();
    private readonly Label _lastComplete = NewValueLabel();
    private readonly Label _elapsed = NewValueLabel();
    private readonly TextBox _videoDir = NewPathBox();
    private readonly TextBox _audioDir = NewPathBox();
    private readonly TextBox _outputDir = NewPathBox();
    private readonly NumericUpDown _videosPerAudio = NewNumber(1, 99);
    private readonly NumericUpDown _parallelRenders = NewNumber(1, 12);
    private readonly NumericUpDown _supplementRounds = NewNumber(0, 12);
    private readonly NumericUpDown _videoCq = NewNumber(1, 51);
    private readonly NumericUpDown _fps = NewNumber(15, 120);
    private readonly NumericUpDown _imageSeconds = NewNumber(1, 600);
    private readonly NumericUpDown _minimumShortClipSeconds = NewNumber(1, 30);
    private readonly ComboBox _outputMode = NewCombo("auto", "portrait", "landscape");
    private readonly ComboBox _encoder = NewCombo("auto", "h264_nvenc", "libx264");
    private readonly ComboBox _clipMode = NewCombo("random - 随机30秒", "short - 短视频整段参与", "whole - 全部视频整段");
    private readonly CheckBox _enableSubtitles = NewCheck("启用字幕");
    private readonly CheckBox _enableImageMotion = NewCheck("图片动效");
    private readonly CheckBox _enableAtmosphere = NewCheck("氛围特效");
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    private readonly ConcurrentQueue<string> _pendingRuntimeLines = new();
    private readonly Queue<string> _runtimeLines = new();
    private readonly NotifyIcon _tray;
    private Process? _monitorProcess;
    private DateTime? _monitorStartedAt;
    private DateTime _nextStatusRefresh = DateTime.MinValue;
    private int _pendingRuntimeLineCount;
    private int _droppedRuntimeLineCount;
    private int _statusRefreshRunning;
    private int _completedCount;
    private int _todayCompletedCount;
    private int _failedCount;
    private string _currentAudioText = "-";
    private string _lastCompleteText = "-";
    private bool _allowExit;

    public MainForm()
    {
        _configPath = Path.Combine(_root, "config.ps1");
        Text = "自动剪辑桌面版 V16.1.15";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(1080, 720);
        Size = new Size(1280, 840);
        Font = new Font("Microsoft YaHei UI", 9F);
        BackColor = Color.White;

        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "自动剪辑桌面版 V16.1.15",
            Visible = true,
            ContextMenuStrip = BuildTrayMenu()
        };
        _tray.DoubleClick += (_, _) => RestoreWindow();

        Controls.Add(BuildLayout());
        Load += (_, _) => InitializeManager();
        FormClosing += OnClosing;
        _timer.Tick += (_, _) => OnTimerTick();
    }

    private Control BuildLayout()
    {
        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildMonitorTab());
        tabs.TabPages.Add(BuildConfigTab());
        tabs.TabPages.Add(BuildLogTab());
        return tabs;
    }

    private TabPage BuildMonitorTab()
    {
        var tab = new TabPage("运行监控") { Padding = new Padding(14) };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3 };
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 192));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var commandBar = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(0, 8, 0, 0) };
        commandBar.Controls.Add(NewButton("开始监控", StartMonitor, 118));
        commandBar.Controls.Add(NewButton("停止监控", StopMonitor, 118));
        commandBar.Controls.Add(NewButton("10 秒测试", StartTest, 110));
        commandBar.Controls.Add(NewButton("环境自检", StartSelfCheck, 110));
        commandBar.Controls.Add(NewButton("保存配置", (_, _) => SaveConfig(null, EventArgs.Empty), 110));
        commandBar.Controls.Add(NewButton("字幕设置", OpenSubtitleSettings, 110));
        commandBar.Controls.Add(NewButton("打开完成", (_, _) => OpenDirectory(_outputDir.Text), 100));
        commandBar.Controls.Add(NewButton("打开日志", (_, _) => OpenDirectory(Path.Combine(_root, "logs")), 100));

        var state = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 4, Padding = new Padding(12), BackColor = Color.FromArgb(247, 249, 251) };
        for (var i = 0; i < 4; i++) state.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25));
        AddStatus(state, 0, 0, "监控状态", _monitorState);
        AddStatus(state, 1, 0, "正在剪辑", _currentAudio);
        AddStatus(state, 2, 0, "开始时间", _startTime);
        AddStatus(state, 3, 0, "已运行时间", _elapsed);
        AddStatus(state, 0, 2, "今日已剪辑", _todayCompleted);
        AddStatus(state, 1, 2, "完成视频", _completed);
        AddStatus(state, 2, 2, "失败音频", _failed);
        AddStatus(state, 3, 2, "上次完成", _lastComplete);
        AddStatus(state, 0, 3, "程序目录", NewValueLabel(_root));

        var logGroup = new GroupBox { Text = "当前任务输出", Dock = DockStyle.Fill, Padding = new Padding(8) };
        logGroup.Controls.Add(_runtimeLog);
        layout.Controls.Add(commandBar, 0, 0);
        layout.Controls.Add(state, 0, 1);
        layout.Controls.Add(logGroup, 0, 2);
        tab.Controls.Add(layout);
        return tab;
    }

    private TabPage BuildConfigTab()
    {
        var tab = new TabPage("配置") { Padding = new Padding(14), AutoScroll = true };
        var main = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 4, Padding = new Padding(0) };
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 95));
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 95));
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));

        AddPath(main, 0, "视频位置", _videoDir);
        AddPath(main, 1, "音频位置", _audioDir);
        AddPath(main, 2, "完成位置", _outputDir);
        AddField(main, 3, "生成数量", _videosPerAudio, "并发数量", _parallelRenders);
        AddField(main, 4, "补剪轮数", _supplementRounds, "画质 CQ", _videoCq);
        AddField(main, 5, "帧率 FPS", _fps, "图片秒数", _imageSeconds);
        AddField(main, 6, "输出方向", _outputMode, "视频编码器", _encoder);
        AddField(main, 7, "取材方式", _clipMode, "短视频最短秒数", _minimumShortClipSeconds);
        var toggles = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 12, 0, 4) };
        toggles.Controls.AddRange([_enableSubtitles, _enableImageMotion, _enableAtmosphere]);
        var commands = new FlowLayoutPanel { Dock = DockStyle.Top, AutoSize = true, Padding = new Padding(0, 12, 0, 0) };
        commands.Controls.Add(NewButton("保存配置", (_, _) => SaveConfig(null, EventArgs.Empty), 120));
        commands.Controls.Add(NewButton("重新读取", (_, _) => LoadConfig(), 120));
        commands.Controls.Add(NewButton("打开字幕设置", OpenSubtitleSettings, 130));

        var wrapper = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        wrapper.Controls.Add(commands);
        wrapper.Controls.Add(toggles);
        wrapper.Controls.Add(main);
        tab.Controls.Add(wrapper);
        return tab;
    }

    private TabPage BuildLogTab()
    {
        var tab = new TabPage("日志") { Padding = new Padding(14) };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 44 };
        buttons.Controls.Add(NewButton("刷新日志", (_, _) => RefreshFileLog(), 110));
        buttons.Controls.Add(NewButton("打开日志目录", (_, _) => OpenDirectory(Path.Combine(_root, "logs")), 130));
        buttons.Controls.Add(NewButton("打开失败音频", (_, _) => OpenDirectory(Path.Combine(_root, "失败音频")), 130));
        buttons.Controls.Add(NewButton("打开版本备份", (_, _) => OpenDirectory(Path.Combine(_root, "banbenbeifen")), 130));
        tab.Controls.Add(_fileLog);
        tab.Controls.Add(buttons);
        return tab;
    }

    private void InitializeManager()
    {
        Directory.CreateDirectory(Path.Combine(_root, "logs"));
        AppendRuntime($"桌面版已启动：{_root}");
        LoadConfig();
        RefreshStatus();
        RefreshFileLog();
        _timer.Start();
    }

    private void OnTimerTick()
    {
        DrainRuntimeLog();
        UpdateStatusLabels();
        if (DateTime.Now >= _nextStatusRefresh) RefreshStatus();
    }

    private void StartMonitor(object? sender, EventArgs e)
    {
        if (_monitorProcess is { HasExited: false })
        {
            AppendRuntime("监控已经在运行。");
            return;
        }
        if (!SaveConfig(sender, e) || !EnsureRuntimePathsAvailable()) return;
        var script = Path.Combine(_root, "Auto-Monitor.ps1");
        if (!File.Exists(script)) { ShowError("找不到 Auto-Monitor.ps1。"); return; }
        try
        {
            _monitorProcess = StartPowerShell(script, "", "监控");
            _monitorStartedAt = DateTime.Now;
            AppendRuntime("监控已在后台启动。");
            RefreshStatus();
        }
        catch (Exception ex) { ShowError("启动监控失败：" + ex.Message); }
    }

    private void StopMonitor(object? sender, EventArgs e)
    {
        if (_monitorProcess is not { HasExited: false })
        {
            AppendRuntime("没有正在运行的桌面版监控进程。");
            return;
        }
        try
        {
            _monitorProcess.Kill(true);
            _monitorProcess.Dispose();
            _monitorProcess = null;
            _monitorStartedAt = null;
            AppendRuntime("监控已停止。");
        }
        catch (Exception ex) { ShowError("停止监控失败：" + ex.Message); }
        RefreshStatus();
    }

    private void StartTest(object? sender, EventArgs e)
    {
        if (!SaveConfig(sender, e) || !EnsureRuntimePathsAvailable()) return;
        var script = Path.Combine(_root, "Start-AutoCut.ps1");
        RunShortTask(script, "-Test", "10 秒测试");
    }

    private void StartSelfCheck(object? sender, EventArgs e)
    {
        var script = Path.Combine(_root, "Start-AutoCut.ps1");
        RunShortTask(script, "-CheckOnly", "环境自检");
    }

    private void OpenSubtitleSettings(object? sender, EventArgs e)
    {
        var script = Path.Combine(_root, "Subtitle-Settings.ps1");
        if (!File.Exists(script)) { ShowError("找不到 Subtitle-Settings.ps1。"); return; }
        try
        {
            var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(executable)) executable = "powershell.exe";
            var psi = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = $"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File \"{script}\"",
                WorkingDirectory = _root,
                UseShellExecute = false,
                CreateNoWindow = false,
                WindowStyle = ProcessWindowStyle.Normal
            };
            var process = Process.Start(psi);
            if (process == null) throw new InvalidOperationException("PowerShell 未能启动。");
            AppendRuntime("字幕设置器已启动。启动日志位于 logs\\subtitle_settings_*.log。");
        }
        catch (Exception ex) { ShowError("打开字幕设置失败：" + ex.Message); }
    }

    private void RunShortTask(string script, string args, string name)
    {
        if (!File.Exists(script)) { ShowError("找不到脚本：" + script); return; }
        var worker = new Thread(() =>
        {
            try
            {
                AppendRuntime(name + "开始。");
                using var process = StartPowerShell(script, args, name);
                process.WaitForExit();
                AppendRuntime(name + "结束，退出码：" + process.ExitCode);
                BeginInvoke(RefreshStatus);
                BeginInvoke(RefreshFileLog);
            }
            catch (Exception ex) { AppendRuntime(name + "失败：" + ex.Message); }
        }) { IsBackground = true };
        worker.Start();
    }

    private Process StartPowerShell(string script, string scriptArguments, string label)
    {
        var psi = CreatePowerShellStartInfo(script, scriptArguments);
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) QueueRuntime($"{label}: {e.Data}"); };
        process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) QueueRuntime($"{label} 错误: {e.Data}"); };
        process.Exited += (_, _) => BeginInvoke(new Action(RefreshStatus));
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private ProcessStartInfo CreatePowerShellStartInfo(string script, string scriptArguments)
    {
        var executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        if (!File.Exists(executable)) executable = "powershell.exe";
        return new ProcessStartInfo
        {
            FileName = executable,
            Arguments = $"-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{script}\" {scriptArguments}",
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        };
    }

    private void LoadConfig()
    {
        try
        {
            var config = ReadConfigWithPowerShell();
            _videoDir.Text = config.GetValueOrDefault("VideoDir", Path.Combine(_root, "视频位置"));
            _audioDir.Text = config.GetValueOrDefault("AudioDir", Path.Combine(_root, "音频位置"));
            _outputDir.Text = config.GetValueOrDefault("OutputDir", Path.Combine(_root, "完成"));
            SetNumber(_videosPerAudio, config, "VideosPerAudio", 6);
            SetNumber(_parallelRenders, config, "ParallelRenders", 6);
            SetNumber(_supplementRounds, config, "SupplementRetryRounds", 3);
            SetNumber(_videoCq, config, "VideoCrf", 26);
            SetNumber(_fps, config, "Fps", 30);
            SetNumber(_imageSeconds, config, "ImageDurationSeconds", 6);
            SetNumber(_minimumShortClipSeconds, config, "MinimumShortClipSeconds", 3);
            SetCombo(_outputMode, config.GetValueOrDefault("OutputMode", "auto"));
            SetCombo(_encoder, config.GetValueOrDefault("PreferredVideoEncoder", "auto"));
            SetClipMode(_clipMode, config.GetValueOrDefault("ClipMode", "random"));
            _enableSubtitles.Checked = ToBool(config, "EnableSubtitles", true);
            _enableImageMotion.Checked = ToBool(config, "EnableImageEffects", true);
            _enableAtmosphere.Checked = ToBool(config, "EnableAtmosphereEffects", false);
            AppendRuntime("配置已读取。");
        }
        catch (Exception ex) { ShowError("读取配置失败：" + ex.Message); }
    }

    private Dictionary<string, string> ReadConfigWithPowerShell()
    {
        if (!File.Exists(_configPath)) throw new FileNotFoundException("config.ps1 不存在", _configPath);
        EnsureConfigEncoding();
        var ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        var names = new[] { "VideoDir", "AudioDir", "OutputDir", "VideosPerAudio", "ParallelRenders", "SupplementRetryRounds", "VideoCrf", "Fps", "ImageDurationSeconds", "MinimumShortClipSeconds", "OutputMode", "PreferredVideoEncoder", "ClipMode", "EnableSubtitles", "EnableImageEffects", "EnableAtmosphereEffects" };
        var pairs = string.Join(";", names.Select(n => "'" + n + "'=$" + n));
        var command = "& { . '" + _configPath.Replace("'", "''") + "'; [ordered]@{" + pairs + "} | ConvertTo-Json -Compress }";
        var psi = new ProcessStartInfo(ps, "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + command.Replace("\"", "\\\"") + "\"")
        {
            WorkingDirectory = _root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("无法启动 PowerShell。");
        var output = p.StandardOutput.ReadToEnd();
        var error = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException(error.Trim());
        using var json = JsonDocument.Parse(output);
        return json.RootElement.EnumerateObject().ToDictionary(x => x.Name, x => x.Value.ToString(), StringComparer.OrdinalIgnoreCase);
    }

    private void EnsureConfigEncoding()
    {
        var bytes = File.ReadAllBytes(_configPath);
        var hasUtf8Bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
        if (hasUtf8Bom) return;

        string text;
        try
        {
            // PowerShell 5 reads a UTF-8 file without a BOM as ANSI.
            text = new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            text = Encoding.Default.GetString(bytes);
        }
        File.WriteAllText(_configPath, text, new UTF8Encoding(true));
    }

    private bool SaveConfig(object? sender, EventArgs e)
    {
        try
        {
            ValidatePathText(_videoDir.Text, "视频位置");
            ValidatePathText(_audioDir.Text, "音频位置");
            ValidatePathText(_outputDir.Text, "完成位置");
            var backupDir = Path.Combine(_root, "backups");
            Directory.CreateDirectory(backupDir);
            File.Copy(_configPath, Path.Combine(backupDir, "config_before_desktop_save_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".ps1"), true);
            var text = File.ReadAllText(_configPath, Encoding.UTF8);
            text = SetConfigValue(text, "VideoDir", QuotePowerShell(_videoDir.Text));
            text = SetConfigValue(text, "AudioDir", QuotePowerShell(_audioDir.Text));
            text = SetConfigValue(text, "OutputDir", QuotePowerShell(_outputDir.Text));
            text = SetConfigValue(text, "VideosPerAudio", _videosPerAudio.Value.ToString());
            text = SetConfigValue(text, "ParallelRenders", _parallelRenders.Value.ToString());
            text = SetConfigValue(text, "SupplementRetryRounds", _supplementRounds.Value.ToString());
            text = SetConfigValue(text, "VideoCrf", _videoCq.Value.ToString());
            text = SetConfigValue(text, "Fps", _fps.Value.ToString());
            text = SetConfigValue(text, "ImageDurationSeconds", _imageSeconds.Value.ToString());
            text = SetConfigValue(text, "MinimumShortClipSeconds", _minimumShortClipSeconds.Value.ToString());
            text = SetConfigValue(text, "OutputMode", QuotePowerShell(_outputMode.Text));
            text = SetConfigValue(text, "PreferredVideoEncoder", QuotePowerShell(_encoder.Text));
            text = SetConfigValue(text, "ClipMode", QuotePowerShell(GetClipMode(_clipMode)));
            text = SetConfigValue(text, "EnableSubtitles", ToPowerShellBool(_enableSubtitles.Checked));
            text = SetConfigValue(text, "EnableImageEffects", ToPowerShellBool(_enableImageMotion.Checked));
            foreach (var obsolete in new[] { "EnableDedupEffects", "EnableFullDedup", "DedupMinSourceGapSeconds", "DedupFrameIntervalSeconds", "DedupConsecutiveFrames" }) text = RemoveConfigValue(text, obsolete);
            text = SetConfigValue(text, "EnableAtmosphereEffects", ToPowerShellBool(_enableAtmosphere.Checked));
            var temp = _configPath + ".desktop.tmp";
            File.WriteAllText(temp, text, new UTF8Encoding(true));
            File.Move(temp, _configPath, true);
            var unavailable = new[] { ("视频位置", _videoDir.Text), ("音频位置", _audioDir.Text), ("完成位置", _outputDir.Text) }
                .Where(x => !Directory.Exists(x.Item2.Trim()))
                .Select(x => x.Item1 + "当前不可访问：" + x.Item2.Trim())
                .ToArray();
            AppendRuntime(unavailable.Length == 0
                ? "配置已保存。新配置将在下一条任务开始时生效。"
                : "配置已保存；以下目录当前不可访问，开始任务前请连接后再试：" + string.Join("；", unavailable));
            return true;
        }
        catch (Exception ex) { ShowError("保存配置失败：" + ex.Message); return false; }
    }

    private static string SetConfigValue(string source, string name, string value)
    {
        var pattern = @"(?m)^\s*\$" + Regex.Escape(name) + @"\s*=.*$";
        var replacement = "$" + name + " = " + value;
        return Regex.IsMatch(source, pattern) ? Regex.Replace(source, pattern, _ => replacement) : source.TrimEnd() + Environment.NewLine + replacement + Environment.NewLine;
    }

    private static string RemoveConfigValue(string source, string name) => Regex.Replace(source, @"(?m)^\s*\$" + Regex.Escape(name) + @"\s*=.*(?:\r?\n|$)", "");

    private static string QuotePowerShell(string value) => "'" + value.Trim().Replace("'", "''") + "'";
    private static string ToPowerShellBool(bool value) => value ? "$true" : "$false";

    private static void ValidatePathText(string value, string label)
    {
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException(label + "不能为空。");
        _ = Path.GetFullPath(value.Trim());
    }

    private bool EnsureRuntimePathsAvailable()
    {
        var unavailable = new List<string>();
        foreach (var (label, value) in new[] { ("视频位置", _videoDir.Text), ("音频位置", _audioDir.Text), ("完成位置", _outputDir.Text) })
        {
            try { Directory.CreateDirectory(value.Trim()); }
            catch { unavailable.Add(label + "不可访问：" + value.Trim()); }
        }
        if (unavailable.Count == 0) return true;
        ShowError("配置已经保存，但当前不能开始任务：\r\n" + string.Join("\r\n", unavailable));
        return false;
    }

    private void RefreshStatus()
    {
        UpdateStatusLabels();
        _nextStatusRefresh = DateTime.Now.AddSeconds(10);
        if (Interlocked.Exchange(ref _statusRefreshRunning, 1) != 0) return;
        var outputDir = _outputDir.Text;
        _ = Task.Run(() => ReadStatusSnapshot(outputDir)).ContinueWith(task =>
        {
            if (IsDisposed || !IsHandleCreated) { Interlocked.Exchange(ref _statusRefreshRunning, 0); return; }
            try
            {
                BeginInvoke(new Action(() =>
                {
                    try
                    {
                        if (task.Status == TaskStatus.RanToCompletion)
                        {
                            var snapshot = task.Result;
                            _completedCount = snapshot.Completed;
                            _todayCompletedCount = snapshot.TodayCompleted;
                            _failedCount = snapshot.Failed;
                            _currentAudioText = snapshot.CurrentAudio;
                            _lastCompleteText = snapshot.LastComplete;
                            UpdateStatusLabels();
                        }
                    }
                    finally { Interlocked.Exchange(ref _statusRefreshRunning, 0); }
                }));
            }
            catch { Interlocked.Exchange(ref _statusRefreshRunning, 0); }
        }, TaskScheduler.Default);
    }

    private void UpdateStatusLabels()
    {
        var active = _monitorProcess is { HasExited: false };
        _monitorState.Text = active ? "监控中" : "未监控";
        _monitorState.ForeColor = active ? Color.ForestGreen : Color.Firebrick;
        _startTime.Text = _monitorStartedAt?.ToString("yyyy-MM-dd HH:mm:ss") ?? "-";
        _elapsed.Text = _monitorStartedAt is null ? "-" : (DateTime.Now - _monitorStartedAt.Value).ToString(@"hh\:mm\:ss");
        _completed.Text = _completedCount.ToString();
        _todayCompleted.Text = _todayCompletedCount.ToString();
        _failed.Text = _failedCount.ToString();
        _currentAudio.Text = _currentAudioText;
        _lastComplete.Text = _lastCompleteText;
    }

    private StatusSnapshot ReadStatusSnapshot(string outputDir)
    {
        var lines = ReadLatestLogLines(40);
        var current = lines.LastOrDefault(x => x.Contains("开始处理：", StringComparison.Ordinal));
        var complete = lines.LastOrDefault(x => x.Contains("本音频输出目录", StringComparison.Ordinal) || x.Contains("全部任务完成", StringComparison.Ordinal));
        return new StatusSnapshot(
            CountFiles(outputDir, new[] { ".mp4", ".mov", ".mkv" }),
            ReadTodayCompletedVideoCount(),
            CountFiles(Path.Combine(_root, "失败音频"), new[] { ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg", ".wma" }),
            current is null ? "-" : AfterColon(current),
            complete is null ? "-" : AfterColon(complete));
    }

    private void RefreshFileLog()
    {
        _fileLog.Text = "正在读取最新日志…";
        _ = Task.Run(() => ReadLatestLogLines(2000)).ContinueWith(task =>
        {
            if (IsDisposed || !IsHandleCreated || task.Status != TaskStatus.RanToCompletion) return;
            try { BeginInvoke(new Action(() => _fileLog.Text = string.Join(Environment.NewLine, task.Result))); } catch { }
        }, TaskScheduler.Default);
    }

    private string[] ReadLatestLogLines(int maxLines)
    {
        try
        {
            var logDir = Path.Combine(_root, "logs");
            if (!Directory.Exists(logDir)) return Array.Empty<string>();
            var latest = Directory.EnumerateFiles(logDir, "*.log", SearchOption.TopDirectoryOnly)
                .Where(path => Path.GetFileName(path).StartsWith("monitor_", StringComparison.OrdinalIgnoreCase) ||
                               (Path.GetFileName(path).StartsWith("run_", StringComparison.OrdinalIgnoreCase) && !path.EndsWith(".job.log", StringComparison.OrdinalIgnoreCase)))
                .Select(path => new FileInfo(path)).OrderByDescending(x => x.LastWriteTime).FirstOrDefault();
            if (latest is null) return Array.Empty<string>();
            const int tailBytes = 2 * 1024 * 1024;
            using var stream = new FileStream(latest.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var startedMidFile = stream.Length > tailBytes;
            if (startedMidFile) stream.Seek(-tailBytes, SeekOrigin.End);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            if (startedMidFile) reader.ReadLine(); // Discard a partial first line after seeking.
            return reader.ReadToEnd().Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                .Where(line => !string.IsNullOrEmpty(line)).TakeLast(maxLines).ToArray();
        }
        catch { return Array.Empty<string>(); }
    }

    private static int CountFiles(string directory, string[] extensions)
    {
        try
        {
            if (!Directory.Exists(directory)) return 0;
            return Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories).Count(path => extensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase));
        }
        catch { return 0; }
    }

    private int ReadTodayCompletedVideoCount()
    {
        try
        {
            var path = Path.Combine(_root, "config", "daily_video_stats.json");
            if (!File.Exists(path)) return 0;
            using var document = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
            var root = document.RootElement;
            if (!root.TryGetProperty("Date", out var date) || date.GetString() != DateTime.Today.ToString("yyyy-MM-dd")) return 0;
            return root.TryGetProperty("VideoCount", out var count) && count.TryGetInt32(out var value) ? Math.Max(0, value) : 0;
        }
        catch { return 0; }
    }

    private void AppendRuntime(string text)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { QueueRuntime(text); return; }
        AppendRuntimeLines([text]);
    }

    private void QueueRuntime(string text)
    {
        if (Interlocked.Increment(ref _pendingRuntimeLineCount) > PendingRuntimeLogLimit)
        {
            Interlocked.Decrement(ref _pendingRuntimeLineCount);
            Interlocked.Increment(ref _droppedRuntimeLineCount);
            return;
        }
        _pendingRuntimeLines.Enqueue(text);
    }

    private void DrainRuntimeLog()
    {
        var lines = new List<string>();
        while (lines.Count < 120 && _pendingRuntimeLines.TryDequeue(out var line))
        {
            Interlocked.Decrement(ref _pendingRuntimeLineCount);
            lines.Add(line);
        }
        var dropped = Interlocked.Exchange(ref _droppedRuntimeLineCount, 0);
        if (dropped > 0) lines.Add($"界面日志过多，已省略 {dropped} 行；完整记录请查看 logs。");
        if (lines.Count > 0) AppendRuntimeLines(lines);
    }

    private void AppendRuntimeLines(IEnumerable<string> lines)
    {
        foreach (var line in lines)
        {
            _runtimeLines.Enqueue("[" + DateTime.Now.ToString("HH:mm:ss") + "] " + line);
            while (_runtimeLines.Count > RuntimeLogLineLimit) _runtimeLines.Dequeue();
        }
        _runtimeLog.Lines = _runtimeLines.ToArray();
        _runtimeLog.SelectionStart = _runtimeLog.TextLength;
        _runtimeLog.ScrollToCaret();
    }

    private sealed record StatusSnapshot(int Completed, int TodayCompleted, int Failed, string CurrentAudio, string LastComplete);

    private void OnClosing(object? sender, FormClosingEventArgs e)
    {
        if (!_allowExit && _monitorProcess is { HasExited: false })
        {
            e.Cancel = true;
            Hide();
            _tray.ShowBalloonTip(1500, "自动剪辑仍在监控", "程序已最小化到通知区域。", ToolTipIcon.Info);
            return;
        }
        _timer.Stop();
        _tray.Visible = false;
        _tray.Dispose();
    }

    private ContextMenuStrip BuildTrayMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("显示管理界面", null, (_, _) => RestoreWindow());
        menu.Items.Add("停止监控", null, StopMonitor);
        menu.Items.Add("退出", null, (_, _) => { _allowExit = true; StopMonitor(null, EventArgs.Empty); Close(); });
        return menu;
    }

    private void RestoreWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private static void AddStatus(TableLayoutPanel panel, int column, int row, string title, Label value)
    {
        var titleLabel = new Label { Text = title, AutoSize = true, ForeColor = Color.DimGray, Margin = new Padding(8, 4, 8, 1) };
        value.Margin = new Padding(8, 1, 8, 8);
        panel.Controls.Add(titleLabel, column, row);
        panel.Controls.Add(value, column, row + 1);
    }

    private void AddPath(TableLayoutPanel table, int row, string label, TextBox box)
    {
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        table.Controls.Add(new Label { Text = label, Anchor = AnchorStyles.Left, AutoSize = true }, 0, row);
        table.Controls.Add(box, 1, row);
        var choose = NewButton("选择", (_, _) => ChooseDirectory(box), 70);
        table.Controls.Add(choose, 2, row);
        table.Controls.Add(new Label(), 3, row);
    }

    private static void AddField(TableLayoutPanel table, int row, string leftName, Control left, string rightName, Control right)
    {
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        table.Controls.Add(new Label { Text = leftName, Anchor = AnchorStyles.Left, AutoSize = true }, 0, row);
        left.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        table.Controls.Add(left, 1, row);
        table.Controls.Add(new Label { Text = rightName, Anchor = AnchorStyles.Left, AutoSize = true }, 2, row);
        right.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        table.Controls.Add(right, 3, row);
    }

    private void ChooseDirectory(TextBox target)
    {
        using var dialog = new FolderBrowserDialog { SelectedPath = Directory.Exists(target.Text) ? target.Text : _root, ShowNewFolderButton = true };
        if (dialog.ShowDialog(this) == DialogResult.OK) target.Text = dialog.SelectedPath;
    }

    private static TextBox NewLogBox() => new() { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 9F), BackColor = Color.White };
    private static TextBox NewPathBox() => new() { Dock = DockStyle.Fill };
    private static NumericUpDown NewNumber(decimal min, decimal max) => new() { Minimum = min, Maximum = max, Width = 140 };
    private static ComboBox NewCombo(params string[] items) { var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 160 }; box.Items.AddRange(items); box.SelectedIndex = 0; return box; }
    private static CheckBox NewCheck(string text) => new() { Text = text, AutoSize = true, Padding = new Padding(6), Margin = new Padding(4) };
    private static Label NewValueLabel(string? text = null) => new() { Text = text ?? "-", AutoSize = false, AutoEllipsis = true, Height = 28, ForeColor = Color.Black, Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold) };
    private static Button NewButton(string text, EventHandler handler, int width) { var button = new Button { Text = text, Width = width, Height = 32, Margin = new Padding(0, 0, 8, 0) }; button.Click += handler; return button; }
    private static void SetNumber(NumericUpDown control, Dictionary<string, string> config, string key, decimal fallback) { control.Value = decimal.TryParse(config.GetValueOrDefault(key), out var value) ? Math.Clamp(value, control.Minimum, control.Maximum) : fallback; }
    private static void SetCombo(ComboBox control, string value) { var index = control.FindStringExact(value); control.SelectedIndex = index >= 0 ? index : 0; }
    private static string GetClipMode(ComboBox control) => control.Text.Split(' ', 2)[0];
    private static void SetClipMode(ComboBox control, string value)
    {
        for (var index = 0; index < control.Items.Count; index++)
        {
            if (control.Items[index]?.ToString()?.StartsWith(value + " -", StringComparison.OrdinalIgnoreCase) == true)
            {
                control.SelectedIndex = index;
                return;
            }
        }
        control.SelectedIndex = 0;
    }
    private static bool ToBool(Dictionary<string, string> config, string key, bool fallback) => bool.TryParse(config.GetValueOrDefault(key), out var value) ? value : fallback;
    private static string AfterColon(string value) { var index = value.LastIndexOf('：'); return index >= 0 ? value[(index + 1)..].Trim() : value.Trim(); }
    private void ShowError(string message) { AppendRuntime(message); MessageBox.Show(this, message, "自动剪辑桌面版", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    private static void OpenDirectory(string path) { if (Directory.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true }); }
}
