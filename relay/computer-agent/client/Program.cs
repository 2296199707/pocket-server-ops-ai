using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using Microsoft.Win32;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        bool created;
        using (var mutex = new Mutex(true, "PocketServerOps-Computer-Client", out created))
        {
            if (!created) return;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}

internal sealed class MainForm : Form
{
    private readonly string _agentPath;
    private readonly string _configPath;
    private readonly string _logPath;
    private readonly System.Windows.Forms.Timer _refreshTimer;
    private readonly Panel _content;
    private readonly TextBox _messageBox;
    private Label _statusLabel;
    private Label _detailLabel;
    private readonly NotifyIcon _tray;
    private Button _startupButton;
    private Label _startupLabel;
    private Process _agentProcess;
    private TextBox _pairingBox;
    private Button _savePairingButton;
    private string _lastLog = string.Empty;
    private bool _allowClose;
    private bool _startupEnabled;
    private readonly bool _startInBackground;

    public MainForm()
    {
        _agentPath = FindAgentPath();
        _startInBackground = HasArgument("--background");
        _configPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PocketServerOps", "computer-agent", "config.json");
        _logPath = Path.Combine(Path.GetDirectoryName(_configPath), "agent.log");

        Text = "PocketServerOps 电脑端";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(680, 440);
        Size = new Size(820, 560);
        BackColor = Color.FromArgb(248, 249, 251);
        Font = new Font("Segoe UI", 9F);
        FormClosing += OnFormClosing;

        var header = BuildHeader();
        _content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 0, 16, 12) };
        _messageBox = new TextBox
        {
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            Dock = DockStyle.Fill,
            BackColor = Color.White,
            BorderStyle = BorderStyle.FixedSingle,
            Font = new Font("Consolas", 9.5F),
            WordWrap = false
        };
        _content.Controls.Add(_messageBox);
        Controls.Add(_content);
        Controls.Add(header);

        _tray = BuildTray();
        _refreshTimer = new System.Windows.Forms.Timer { Interval = 1000 };
        _refreshTimer.Tick += delegate { RefreshState(); };
        Load += OnLoaded;
    }

    private Control BuildHeader()
    {
        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 102,
            ColumnCount = 2,
            RowCount = 3,
            Padding = new Padding(16, 12, 16, 8)
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62F));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38F));
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 30F));
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 24F));
        header.RowStyles.Add(new RowStyle(SizeType.Absolute, 20F));

        var title = new Label
        {
            Text = "PocketServerOps 电脑端",
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI Semibold", 15F),
            ForeColor = Color.FromArgb(30, 34, 42),
            TextAlign = ContentAlignment.MiddleLeft
        };
        _statusLabel = new Label
        {
            Text = "● 未启动",
            Dock = DockStyle.Fill,
            Font = new Font("Segoe UI Semibold", 10F),
            ForeColor = Color.FromArgb(120, 126, 138),
            TextAlign = ContentAlignment.MiddleLeft
        };
        _detailLabel = new Label
        {
            Text = "正在检查 Agent 状态",
            Dock = DockStyle.Fill,
            ForeColor = Color.FromArgb(100, 106, 118),
            TextAlign = ContentAlignment.MiddleLeft,
            AutoEllipsis = true
        };
        _startupLabel = new Label
        {
            Text = "登录启动：检测中",
            Dock = DockStyle.Fill,
            ForeColor = Color.FromArgb(100, 106, 118),
            TextAlign = ContentAlignment.MiddleLeft,
            AutoEllipsis = true
        };

        var actions = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.RightToLeft,
            WrapContents = false,
            AutoSize = false
        };
        _startupButton = CreateButton("开机启动", delegate { ToggleStartup(); });
        actions.Controls.Add(_startupButton);
        actions.Controls.Add(CreateButton("重新配对", delegate { ShowSetup(); }));
        actions.Controls.Add(CreateButton("打开日志", delegate { OpenFile(_logPath); }));
        actions.Controls.Add(CreateButton("配置目录", delegate { OpenDirectory(); }));

        header.Controls.Add(title, 0, 0);
        header.Controls.Add(actions, 1, 0);
        header.Controls.Add(_statusLabel, 0, 1);
        header.Controls.Add(_detailLabel, 1, 1);
        header.Controls.Add(_startupLabel, 0, 2);
        header.SetColumnSpan(_startupLabel, 2);
        return header;
    }

    private Button CreateButton(string text, EventHandler handler)
    {
        var button = new Button
        {
            Text = text,
            AutoSize = true,
            Height = 28,
            FlatStyle = FlatStyle.System,
            Margin = new Padding(4, 0, 0, 0)
        };
        button.Click += handler;
        return button;
    }

    private NotifyIcon BuildTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开主界面", null, delegate { ShowMainWindow(); });
        menu.Items.Add("重新配对", null, delegate { ShowMainWindow(); ShowSetup(); });
        menu.Items.Add("打开运行日志", null, delegate { OpenFile(_logPath); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出界面（Agent继续运行）", null, delegate
        {
            _allowClose = true;
            _tray.Visible = false;
            Close();
        });

        var tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "PocketServerOps 电脑端",
            ContextMenuStrip = menu,
            Visible = true
        };
        tray.DoubleClick += delegate { ShowMainWindow(); };
        return tray;
    }

    private void OnLoaded(object sender, EventArgs e)
    {
        RefreshState();
        if (File.Exists(_configPath))
        {
            SetStartup(true);
            StartAgent();
            if (_startInBackground) BeginInvoke(new Action(Hide));
        }
        else ShowSetup();
        _refreshTimer.Start();
    }

    private void ShowSetup()
    {
        var panel = new Panel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(24) };
        var title = new Label
        {
            Text = "配置电脑连接",
            Dock = DockStyle.Top,
            Height = 34,
            Font = new Font("Segoe UI Semibold", 13F)
        };
        var tip = new Label
        {
            Text = "在手机 App 的“电脑配对信息”中点击“复制配置”，粘贴下面的 JSON。\r\n保存后客户端会自动启动 Agent 并显示运行消息。",
            Dock = DockStyle.Top,
            Height = 54,
            AutoSize = false,
            ForeColor = Color.FromArgb(90, 96, 108)
        };
        _pairingBox = new TextBox
        {
            Multiline = true,
            ScrollBars = ScrollBars.Vertical,
            Dock = DockStyle.Fill,
            Font = new Font("Consolas", 10F),
            BorderStyle = BorderStyle.FixedSingle
        };
        _savePairingButton = new Button
        {
            Text = "保存并连接",
            AutoSize = true,
            Height = 32,
            Anchor = AnchorStyles.Right
        };
        _savePairingButton.Click += async delegate { await SavePairingAsync(); };
        var buttons = new Panel { Dock = DockStyle.Bottom, Height = 48 };
        buttons.Controls.Add(_savePairingButton);
        buttons.Resize += delegate { _savePairingButton.Left = buttons.Width - _savePairingButton.Width; };

        panel.Controls.Add(_pairingBox);
        panel.Controls.Add(buttons);
        panel.Controls.Add(tip);
        panel.Controls.Add(title);
        _content.Controls.Clear();
        _content.Controls.Add(panel);
        SetStatus("● 等待配置", Color.FromArgb(120, 126, 138), "尚未保存电脑配对信息");
    }

    private void ShowMessages()
    {
        _content.Controls.Clear();
        _content.Controls.Add(_messageBox);
        RefreshLog();
    }

    private async Task SavePairingAsync()
    {
        var pairing = (_pairingBox.Text ?? string.Empty).Trim();
        if (pairing.Length == 0)
        {
            MessageBox.Show(this, "请先粘贴手机 App 中的配对 JSON。", "无法保存", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        if (string.IsNullOrEmpty(_agentPath))
        {
            MessageBox.Show(this, "当前目录没有找到 Windows Agent EXE。请确认客户端和 Agent 在同一个文件夹。", "无法配置", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        _savePairingButton.Enabled = false;
        SetStatus("● 配置中", Color.DarkOrange, "正在保存手机配对信息");
        var result = await Task.Run(delegate { return ConfigureAgent(pairing); });
        _savePairingButton.Enabled = true;
        if (result.ExitCode != 0)
        {
            SetStatus("● 配置失败", Color.Firebrick, "请检查配对 JSON 和 Agent 日志");
            MessageBox.Show(this, result.Error.Length == 0 ? result.Output : result.Error, "配置失败", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        ShowMessages();
        SetStartup(true);
        StartAgent();
    }

    private SetupResult ConfigureAgent(string pairing)
    {
        var info = new ProcessStartInfo
        {
            FileName = _agentPath,
            Arguments = "--setup-stdin --configure-only",
            WorkingDirectory = Path.GetDirectoryName(_agentPath),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        try
        {
            using (var process = Process.Start(info))
            {
                process.StandardInput.Write(pairing);
                process.StandardInput.Close();
                var output = process.StandardOutput.ReadToEnd();
                var error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                return new SetupResult(process.ExitCode, output, error);
            }
        }
        catch (Exception error)
        {
            return new SetupResult(-1, string.Empty, error.Message);
        }
    }

    private void StartAgent()
    {
        if (_agentProcess != null && !_agentProcess.HasExited) return;
        if (string.IsNullOrEmpty(_agentPath))
        {
            SetStatus("● 找不到 Agent", Color.Firebrick, "请将客户端和 Agent 放在同一个文件夹");
            return;
        }
        var info = new ProcessStartInfo
        {
            FileName = _agentPath,
            Arguments = "--run",
            WorkingDirectory = Path.GetDirectoryName(_agentPath),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        try
        {
            _agentProcess = new Process { StartInfo = info, EnableRaisingEvents = true };
            _agentProcess.OutputDataReceived += OnAgentOutput;
            _agentProcess.ErrorDataReceived += OnAgentOutput;
            _agentProcess.Exited += delegate
            {
                RunOnUi(delegate
                {
                    SetStatus("● Agent 已退出", Color.Firebrick, "请查看运行日志");
                    AppendLive("[client] Agent 进程已退出");
                });
            };
            _agentProcess.Start();
            _agentProcess.BeginOutputReadLine();
            _agentProcess.BeginErrorReadLine();
            SetStatus("● 连接中", Color.DarkOrange, "Agent 已启动，等待中转认证");
        }
        catch (Exception error)
        {
            SetStatus("● 启动失败", Color.Firebrick, error.Message);
        }
    }

    private void ToggleStartup()
    {
        SetStartup(!_startupEnabled);
    }

    private void SetStartup(bool enabled)
    {
        try
        {
            using (var key = Registry.CurrentUser.OpenSubKey(
                "Software\\Microsoft\\Windows\\CurrentVersion\\Run", true))
            {
                if (key == null) throw new InvalidOperationException("无法访问当前用户的登录启动设置");
                if (enabled)
                {
                    key.SetValue("PocketServerOpsComputer", Quote(Application.ExecutablePath) + " --background");
                }
                else
                {
                    key.DeleteValue("PocketServerOpsComputer", false);
                }
            }
            _startupEnabled = enabled;
            _startupButton.Text = enabled ? "关闭自启动" : "开机启动";
            _startupLabel.Text = enabled ? "登录启动：已启用（当前用户）" : "登录启动：已关闭";
            _startupLabel.ForeColor = Color.FromArgb(100, 106, 118);
        }
        catch (Exception error)
        {
            _startupLabel.Text = "登录启动：设置失败";
            _startupLabel.ForeColor = Color.Firebrick;
            _detailLabel.Text = error.Message;
        }
    }

    private void OnAgentOutput(object sender, DataReceivedEventArgs e)
    {
        // The persistent agent.log is the single source for the message view.
        // Reading redirected output here keeps the child process pipe drained.
    }

    private void RefreshState()
    {
        RefreshLog();
        if (_agentProcess != null && _agentProcess.HasExited)
        {
            SetStatus("● Agent 已退出", Color.Firebrick, "请查看运行日志");
        }
    }

    private void RefreshLog()
    {
        if (!File.Exists(_logPath)) return;
        try
        {
            var text = File.ReadAllText(_logPath, Encoding.UTF8);
            if (text.Length > 240000) text = text.Substring(text.Length - 240000);
            if (text == _lastLog) return;
            _lastLog = text;
            if (_content.Controls.Contains(_messageBox))
            {
                _messageBox.Text = text;
                _messageBox.SelectionStart = _messageBox.TextLength;
                _messageBox.ScrollToCaret();
            }
            UpdateStatusFromLog(text);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void UpdateStatusFromLog(string text)
    {
        var lines = text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        for (var i = lines.Length - 1; i >= 0; i--)
        {
            var line = lines[i];
            if (line.IndexOf("已认证", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                SetStatus("● 已连接", Color.SeaGreen, "中转连接正常");
                return;
            }
            if (line.IndexOf("重连", StringComparison.OrdinalIgnoreCase) >= 0 || line.IndexOf("断开", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                SetStatus("● 重连中", Color.DarkOrange, line.Trim());
                return;
            }
            if (line.IndexOf("[error]", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                SetStatus("● 发生错误", Color.Firebrick, line.Trim());
                return;
            }
        }
    }

    private void AppendLive(string line)
    {
        if (!_content.Controls.Contains(_messageBox)) return;
        if (_messageBox.TextLength > 0) _messageBox.AppendText(Environment.NewLine);
        _messageBox.AppendText(line);
        _messageBox.SelectionStart = _messageBox.TextLength;
        _messageBox.ScrollToCaret();
    }

    private void SetStatus(string text, Color color, string detail)
    {
        if (InvokeRequired)
        {
            RunOnUi(delegate { SetStatus(text, color, detail); });
            return;
        }
        _statusLabel.Text = text;
        _statusLabel.ForeColor = color;
        _detailLabel.Text = detail;
    }

    private void ShowMainWindow()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
    }

    private void OpenFile(string filePath)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(filePath));
            if (!File.Exists(filePath)) File.WriteAllText(filePath, string.Empty, Encoding.UTF8);
            Process.Start(new ProcessStartInfo("notepad.exe", Quote(filePath)) { UseShellExecute = false });
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法打开文件", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void OpenDirectory()
    {
        try
        {
            var directory = Path.GetDirectoryName(_configPath);
            Directory.CreateDirectory(directory);
            Process.Start(new ProcessStartInfo("explorer.exe", Quote(directory)) { UseShellExecute = false });
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "无法打开目录", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void OnFormClosing(object sender, FormClosingEventArgs e)
    {
        if (_allowClose) return;
        e.Cancel = true;
        Hide();
    }

    private void RunOnUi(Action action)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(action); } catch (InvalidOperationException) { }
    }

    private static string FindAgentPath()
    {
        var files = Directory.GetFiles(Application.StartupPath, "PocketServerOps-Computer-v*-win-x64.exe");
        if (files.Length == 0) return string.Empty;
        Array.Sort(files, StringComparer.OrdinalIgnoreCase);
        return files[files.Length - 1];
    }

    private static bool HasArgument(string argument)
    {
        var args = Environment.GetCommandLineArgs();
        for (var i = 1; i < args.Length; i++)
        {
            if (string.Equals(args[i], argument, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}

internal sealed class SetupResult
{
    public SetupResult(int exitCode, string output, string error)
    {
        ExitCode = exitCode;
        Output = output ?? string.Empty;
        Error = error ?? string.Empty;
    }

    public int ExitCode { get; private set; }
    public string Output { get; private set; }
    public string Error { get; private set; }
}
