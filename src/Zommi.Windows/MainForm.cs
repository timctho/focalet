using System.Runtime.InteropServices;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class MainForm : Form
{
    private const int HotkeyId = 0x5A4D;
    private const int WmHotkey = 0x0312;
    private const uint ModControl = 0x0002;
    private const uint ModShift = 0x0004;
    private const uint VkReturn = 0x0D;
    private const uint VkSpace = 0x20;

    private static readonly Color Background = Color.FromArgb(24, 27, 36);
    private static readonly Color Panel = Color.FromArgb(34, 39, 51);
    private static readonly Color Muted = Color.FromArgb(158, 166, 184);
    private static readonly Color TextColor = Color.FromArgb(240, 242, 247);
    private static readonly Color Accent = Color.FromArgb(111, 220, 181);
    private static readonly Color Warning = Color.FromArgb(255, 193, 92);

    private readonly ForegroundContextCapture capture;
    private readonly CodexAppServerClient codex;
    private readonly bool autoLaunch;
    private readonly Label contextLabel = new();
    private readonly Label statusLabel = new();
    private readonly Label shortcutLabel = new();
    private readonly RichTextBox transcript = new();
    private readonly TextBox input = new();
    private readonly Button sendButton = new();
    private readonly Button closeButton = new();
    private readonly NotifyIcon trayIcon = new();

    private ContextSnapshot? invocationContext;
    private bool turnActive;
    private bool closeRequested;
    private bool hotkeyRegistered;
    private bool responsePrefixPending;

    public MainForm(ForegroundContextCapture capture, CodexAppServerClient codex, bool autoLaunch)
    {
        this.capture = capture;
        this.codex = codex;
        this.autoLaunch = autoLaunch;

        Text = "Zommi — floating Codex chat";
        ClientSize = new Size(560, 450);
        MinimumSize = new Size(460, 360);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        BackColor = Background;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(1);

        Controls.Add(BuildLayout());
        ConfigureTrayIcon();

        sendButton.Click += async (_, _) => await SendCurrentMessageAsync();
        closeButton.Click += (_, _) => HideChat();
        input.KeyDown += InputKeyDown;
        KeyDown += (_, eventArgs) =>
        {
            if (eventArgs.KeyCode == Keys.Escape)
            {
                HideChat();
            }
        };
        HandleCreated += (_, _) => RegisterInvocationHotkey();
        HandleDestroyed += (_, _) => UnregisterInvocationHotkey();
        FormClosing += OnFormClosing;
        Shown += OnShown;

        codex.StatusChanged += status => PostToUi(() => RenderStatus(status));
        codex.AgentMessageDelta += delta => PostToUi(() => AppendAgentDelta(delta));
        codex.TurnCompleted += status => PostToUi(() => CompleteTurn(status));
    }

    private Control BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Background,
            Padding = new Padding(14),
            ColumnCount = 1,
            RowCount = 5,
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 3,
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var title = new Label
        {
            Text = "Zommi",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 15f),
            ForeColor = TextColor,
            Margin = new Padding(0, 2, 10, 3),
        };
        shortcutLabel.AutoSize = true;
        shortcutLabel.ForeColor = Muted;
        shortcutLabel.Anchor = AnchorStyles.Left;
        shortcutLabel.Margin = new Padding(0, 8, 0, 0);
        StyleButton(closeButton, "×");
        closeButton.Font = new Font("Segoe UI", 13f);
        closeButton.Padding = new Padding(2, 0, 2, 0);
        closeButton.Margin = new Padding(8, 0, 0, 0);
        header.Controls.Add(title, 0, 0);
        header.Controls.Add(shortcutLabel, 1, 0);
        header.Controls.Add(closeButton, 2, 0);
        root.Controls.Add(header, 0, 0);

        contextLabel.AutoEllipsis = true;
        contextLabel.AccessibleName = "Invocation context";
        contextLabel.AutoSize = false;
        contextLabel.Height = 58;
        contextLabel.Dock = DockStyle.Fill;
        contextLabel.BackColor = Panel;
        contextLabel.ForeColor = Muted;
        contextLabel.Padding = new Padding(10, 8, 10, 8);
        contextLabel.Margin = new Padding(0, 8, 0, 10);
        contextLabel.Text = "Press the shortcut while hovering over a page, window, or folder.";
        root.Controls.Add(contextLabel, 0, 1);

        transcript.Dock = DockStyle.Fill;
        transcript.AccessibleName = "Codex conversation";
        transcript.ReadOnly = true;
        transcript.BorderStyle = BorderStyle.None;
        transcript.BackColor = Background;
        transcript.ForeColor = TextColor;
        transcript.Font = new Font("Segoe UI", 10f);
        transcript.DetectUrls = true;
        transcript.Margin = new Padding(0, 0, 0, 10);
        root.Controls.Add(transcript, 0, 2);

        var composer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            BackColor = Panel,
            Padding = new Padding(8),
            ColumnCount = 2,
        };
        composer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        composer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        input.Multiline = true;
        input.AccessibleName = "Zommi message";
        input.AcceptsReturn = true;
        input.BorderStyle = BorderStyle.None;
        input.BackColor = Panel;
        input.ForeColor = TextColor;
        input.Font = new Font("Segoe UI", 10.5f);
        input.PlaceholderText = "Ask about what you are hovering…";
        input.MinimumSize = new Size(0, 58);
        input.Dock = DockStyle.Fill;
        input.ScrollBars = ScrollBars.Vertical;
        StyleButton(sendButton, "Send");
        sendButton.AccessibleName = "Send message";
        sendButton.BackColor = Color.FromArgb(55, 92, 81);
        sendButton.Anchor = AnchorStyles.Bottom;
        sendButton.Margin = new Padding(8, 4, 0, 0);
        composer.Controls.Add(input, 0, 0);
        composer.Controls.Add(sendButton, 1, 0);
        root.Controls.Add(composer, 0, 3);

        statusLabel.AutoSize = true;
        statusLabel.AccessibleName = "Codex status";
        statusLabel.ForeColor = Muted;
        statusLabel.Margin = new Padding(2, 8, 0, 0);
        statusLabel.Text = "Starting…";
        root.Controls.Add(statusLabel, 0, 4);
        return root;
    }

    private static void StyleButton(Button button, string text)
    {
        button.Text = text;
        button.AutoSize = true;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = Color.FromArgb(46, 53, 70);
        button.ForeColor = TextColor;
        button.Padding = new Padding(8, 3, 8, 3);
        button.Cursor = Cursors.Hand;
    }

    private void ConfigureTrayIcon()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open floating chat", null, (_, _) => ShowChat(captureUnderlyingContext: false));
        menu.Items.Add("Exit Zommi", null, (_, _) => ExitApplication());
        trayIcon.Icon = SystemIcons.Application;
        trayIcon.Text = "Zommi floating Codex chat";
        trayIcon.ContextMenuStrip = menu;
        trayIcon.Visible = true;
        trayIcon.DoubleClick += (_, _) => ShowChat(captureUnderlyingContext: false);
    }

    private async void OnShown(object? sender, EventArgs eventArgs)
    {
        if (autoLaunch)
        {
            Hide();
            trayIcon.ShowBalloonTip(
                2500,
                "Zommi is ready",
                $"Hover over anything and press {shortcutLabel.Text} to chat with Codex.",
                ToolTipIcon.Info);
            try
            {
                await codex.EnsureStartedAsync();
            }
            catch (Exception exception)
            {
                RenderStatus($"Codex connection failed: {exception.Message}", warning: true);
            }
        }
        else
        {
            ShowChat(captureUnderlyingContext: false);
            RenderStatus("Acceptance mode · Codex relay disabled");
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId)
        {
            if (Visible)
            {
                if (!string.IsNullOrWhiteSpace(input.Text) && !turnActive)
                {
                    _ = SendCurrentMessageAsync();
                }
                else
                {
                    HideChat();
                }
            }
            else
            {
                ShowChat(captureUnderlyingContext: true);
            }

            return;
        }

        base.WndProc(ref message);
    }

    private void RegisterInvocationHotkey()
    {
        if (NativeMethods.RegisterHotKey(Handle, HotkeyId, ModControl, VkReturn))
        {
            hotkeyRegistered = true;
            shortcutLabel.Text = "Ctrl + Enter";
            return;
        }

        if (NativeMethods.RegisterHotKey(Handle, HotkeyId, ModControl | ModShift, VkSpace))
        {
            hotkeyRegistered = true;
            shortcutLabel.Text = "Ctrl + Shift + Space";
            RenderStatus("Ctrl + Enter was unavailable; using Ctrl + Shift + Space.", warning: true);
            return;
        }

        shortcutLabel.Text = "Shortcut unavailable";
        RenderStatus("Windows could not register a global Zommi shortcut.", warning: true);
    }

    private void UnregisterInvocationHotkey()
    {
        if (hotkeyRegistered)
        {
            _ = NativeMethods.UnregisterHotKey(Handle, HotkeyId);
            hotkeyRegistered = false;
        }
    }

    private void ShowChat(bool captureUnderlyingContext)
    {
        if (captureUnderlyingContext)
        {
            var result = capture.Capture(DateTimeOffset.UtcNow);
            invocationContext = result.Snapshot;
            RenderInvocationContext();
        }

        PositionAwayFromPointer();
        if (!Visible)
        {
            Show();
        }

        WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
        input.Focus();
        input.SelectionStart = input.TextLength;
    }

    private void HideChat()
    {
        Hide();
        invocationContext = null;
        contextLabel.Text = "Press the shortcut while hovering over a page, window, or folder.";
    }

    private void PositionAwayFromPointer()
    {
        if (!NativeMethods.GetCursorPos(out var pointer))
        {
            CenterToScreen();
            return;
        }

        var point = new Point(pointer.X, pointer.Y);
        var workArea = Screen.FromPoint(point).WorkingArea;
        var x = point.X + 24;
        var y = point.Y + 24;
        if (x + Width > workArea.Right)
        {
            x = point.X - Width - 24;
        }

        if (y + Height > workArea.Bottom)
        {
            y = point.Y - Height - 24;
        }

        Location = new Point(
            Math.Clamp(x, workArea.Left, Math.Max(workArea.Left, workArea.Right - Width)),
            Math.Clamp(y, workArea.Top, Math.Max(workArea.Top, workArea.Bottom - Height)));
    }

    private void RenderInvocationContext()
    {
        var snapshot = invocationContext;
        if (snapshot is null)
        {
            contextLabel.Text = "No accessible context was exposed under the pointer. Your typed message will still be sent.";
            return;
        }

        var parts = new List<string> { snapshot.Application };
        if (snapshot.Locator is not null)
        {
            parts.Add(snapshot.Locator.Value);
        }

        if (snapshot.IndicatedTarget is not null)
        {
            var target = snapshot.IndicatedTarget;
            parts.Add($"{target.ControlType ?? "target"}: {target.Name ?? "unnamed"}");
        }

        if (snapshot.VisibleText.Count > 0)
        {
            parts.Add(string.Join(" · ", snapshot.VisibleText.Take(3)));
        }

        contextLabel.Text = string.Join(Environment.NewLine, parts);
    }

    private async Task SendCurrentMessageAsync()
    {
        if (turnActive)
        {
            return;
        }

        var message = input.Text.Trim();
        if (message.Length == 0)
        {
            return;
        }

        turnActive = true;
        responsePrefixPending = true;
        sendButton.Enabled = false;
        input.Enabled = false;
        AppendTranscript("You", message, Accent);
        input.Clear();
        RenderStatus("Codex is working…");
        try
        {
            await codex.StartTurnAsync(message, invocationContext);
        }
        catch (Exception exception)
        {
            AppendTranscript("Error", exception.Message, Warning);
            CompleteTurn("failed");
        }
    }

    private void InputKeyDown(object? sender, KeyEventArgs eventArgs)
    {
        if (eventArgs.KeyCode == Keys.Escape)
        {
            eventArgs.SuppressKeyPress = true;
            HideChat();
            return;
        }

        if (eventArgs.KeyCode == Keys.Enter && !eventArgs.Shift)
        {
            eventArgs.SuppressKeyPress = true;
            _ = SendCurrentMessageAsync();
        }
    }

    private void AppendAgentDelta(string delta)
    {
        if (delta.Length == 0)
        {
            return;
        }

        if (responsePrefixPending)
        {
            AppendTranscript("Codex", string.Empty, Color.FromArgb(142, 190, 255), appendTrailingNewline: false);
            responsePrefixPending = false;
        }

        transcript.SelectionStart = transcript.TextLength;
        transcript.SelectionColor = TextColor;
        transcript.AppendText(delta);
        transcript.SelectionStart = transcript.TextLength;
        transcript.ScrollToCaret();
    }

    private void CompleteTurn(string status)
    {
        if (!responsePrefixPending && transcript.TextLength > 0 && !transcript.Text.EndsWith(Environment.NewLine, StringComparison.Ordinal))
        {
            transcript.AppendText(Environment.NewLine + Environment.NewLine);
        }

        turnActive = false;
        responsePrefixPending = false;
        sendButton.Enabled = true;
        input.Enabled = true;
        RenderStatus(status.Equals("completed", StringComparison.OrdinalIgnoreCase)
            ? "Codex ready"
            : $"Codex turn: {status}",
            warning: !status.Equals("completed", StringComparison.OrdinalIgnoreCase));
        input.Focus();
    }

    private void AppendTranscript(
        string role,
        string text,
        Color roleColor,
        bool appendTrailingNewline = true)
    {
        transcript.SelectionStart = transcript.TextLength;
        transcript.SelectionFont = new Font(transcript.Font, FontStyle.Bold);
        transcript.SelectionColor = roleColor;
        transcript.AppendText(role + Environment.NewLine);
        transcript.SelectionFont = transcript.Font;
        transcript.SelectionColor = TextColor;
        transcript.AppendText(text);
        if (appendTrailingNewline)
        {
            transcript.AppendText(Environment.NewLine + Environment.NewLine);
        }

        transcript.SelectionStart = transcript.TextLength;
        transcript.ScrollToCaret();
    }

    private void RenderStatus(string status, bool warning = false)
    {
        statusLabel.Text = status;
        statusLabel.ForeColor = warning ? Warning : Muted;
    }

    private void PostToUi(Action action)
    {
        if (IsDisposed || !IsHandleCreated)
        {
            return;
        }

        try
        {
            BeginInvoke(action);
        }
        catch (InvalidOperationException)
        {
            // Window teardown raced the background Codex stream.
        }
    }

    private void OnFormClosing(object? sender, FormClosingEventArgs eventArgs)
    {
        if (!closeRequested)
        {
            eventArgs.Cancel = true;
            HideChat();
            return;
        }

        trayIcon.Visible = false;
        trayIcon.Dispose();
        codex.Dispose();
    }

    private void ExitApplication()
    {
        closeRequested = true;
        Close();
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out Point point);

        [StructLayout(LayoutKind.Sequential)]
        internal struct Point
        {
            internal int X;
            internal int Y;
        }
    }
}
