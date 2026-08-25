using System.Runtime.InteropServices;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class MainForm : Form
{
    private const int ContextHotkeyId = 0x5A4D;
    private const int ImageHotkeyId = 0x5A4E;
    private const int WmHotkey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModShift = 0x0004;
    private const uint VkA = 0x41;
    private const int ContextPreviewHideDelayMilliseconds = 250;

    private static readonly Color Background = Color.FromArgb(47, 47, 48);
    private static readonly Color Panel = Color.FromArgb(57, 57, 58);
    private static readonly Color Muted = Color.FromArgb(181, 181, 183);
    private static readonly Color TextColor = Color.FromArgb(246, 246, 246);
    private static readonly Color Accent = Color.FromArgb(216, 232, 255);
    private static readonly Color ContextChip = Color.FromArgb(76, 83, 94);
    private static readonly Color ThinkingColor = Color.FromArgb(193, 199, 210);
    private static readonly Color ToolColor = Color.FromArgb(173, 215, 202);
    private static readonly Color Warning = Color.FromArgb(255, 190, 102);

    private readonly ForegroundContextCapture capture;
    private readonly CodexAppServerClient codex;
    private readonly bool autoLaunch;
    private readonly Func<RegionSelectionForm> regionSelectorFactory;
    private readonly Label statusLabel = new();
    private readonly Label shortcutLabel = new();
    private readonly Label queryLabel = new();
    private readonly RichTextBox transcript = new();
    private readonly RichTextBox input = new();
    private readonly Button sendButton = new();
    private readonly Button copyButton = new();
    private readonly Button closeButton = new();
    private readonly NotifyIcon trayIcon = new();
    private readonly ContextPreviewForm contextPreview = new();
    private readonly System.Windows.Forms.Timer contextPreviewHideTimer = new()
    {
        Interval = ContextPreviewHideDelayMilliseconds,
    };
    private readonly List<ContextAttachment> attachments = [];
    private readonly HashSet<string> activityHeaders = new(StringComparer.Ordinal);
    private readonly HashSet<string> activityWithDelta = new(StringComparer.Ordinal);

    private bool turnActive;
    private bool closeRequested;
    private bool contextHotkeyRegistered;
    private bool imageHotkeyRegistered;
    private bool responsePrefixPending;
    private bool stylingComposer;
    private ContextAttachment? previewedAttachment;
    private Point? pointerOverride;

    public MainForm(
        ForegroundContextCapture capture,
        CodexAppServerClient codex,
        bool autoLaunch,
        Func<RegionSelectionForm>? regionSelectorFactory = null)
    {
        this.capture = capture;
        this.codex = codex;
        this.autoLaunch = autoLaunch;
        this.regionSelectorFactory = regionSelectorFactory ?? (() => new RegionSelectionForm());

        Text = "Zommi — floating Codex chat";
        ClientSize = new Size(760, 390);
        MinimumSize = new Size(540, 270);
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        KeyPreview = true;
        DoubleBuffered = true;
        Opacity = 0.96;
        BackColor = Background;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 9.5f);
        Padding = new Padding(1);

        Controls.Add(BuildLayout());
        ConfigureTrayIcon();

        sendButton.Click += async (_, _) => await SendCurrentMessageAsync();
        copyButton.Click += (_, _) => CopyTranscript();
        closeButton.Click += (_, _) => HideChat();
        input.KeyDown += InputKeyDown;
        input.TextChanged += (_, _) => StyleContextTokens();
        input.MouseMove += InputMouseMove;
        input.MouseEnter += (_, _) => CancelContextPreviewHide();
        input.MouseLeave += (_, _) => ScheduleContextPreviewHide();
        contextPreview.PointerEntered += (_, _) => MonitorContextPreviewPointer();
        contextPreview.PointerExited += (_, _) => ScheduleContextPreviewHide();
        contextPreviewHideTimer.Tick += (_, _) => FinishScheduledContextPreviewHide();
        KeyDown += (_, eventArgs) =>
        {
            if (eventArgs.KeyCode == Keys.Escape)
            {
                HideChat();
            }
        };
        HandleCreated += (_, _) =>
        {
            RegisterInvocationHotkeys();
            ApplyGlassEffect();
        };
        HandleDestroyed += (_, _) => UnregisterInvocationHotkeys();
        Resize += (_, _) => ApplyRoundedRegion();
        Paint += (_, eventArgs) =>
        {
            using var border = new Pen(Color.FromArgb(116, 116, 119), 1f);
            eventArgs.Graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
        };
        FormClosing += OnFormClosing;
        Shown += OnShown;

        codex.StatusChanged += status => PostToUi(() => RenderStatus(status));
        codex.StreamUpdate += update => PostToUi(() => AppendStreamUpdate(update));
        codex.TurnCompleted += status => PostToUi(() => CompleteTurn(status));
    }

    private Control BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            BackColor = Background,
            Padding = new Padding(18, 12, 18, 12),
            ColumnCount = 1,
            RowCount = 4,
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(BuildHeader(), 0, 0);

        transcript.Dock = DockStyle.Fill;
        transcript.Name = "CodexTranscript";
        transcript.AccessibleName = "Codex conversation including thinking and tool activity";
        transcript.ReadOnly = true;
        transcript.BorderStyle = BorderStyle.None;
        transcript.BackColor = Background;
        transcript.ForeColor = TextColor;
        transcript.Font = new Font("Segoe UI", 10.5f);
        transcript.DetectUrls = true;
        transcript.Margin = new Padding(8, 14, 8, 12);
        transcript.ScrollBars = RichTextBoxScrollBars.Vertical;
        root.Controls.Add(transcript, 0, 1);

        root.Controls.Add(BuildComposer(), 0, 2);

        shortcutLabel.AutoSize = true;
        shortcutLabel.Name = "ZommiShortcuts";
        shortcutLabel.ForeColor = Muted;
        shortcutLabel.Margin = new Padding(4, 9, 0, 0);
        shortcutLabel.Text = "Alt + A · image  Alt + Shift + A";
        root.Controls.Add(shortcutLabel, 0, 3);
        return root;
    }

    private Control BuildHeader()
    {
        var header = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            ColumnCount = 4,
            Padding = new Padding(4, 2, 0, 8),
        };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        statusLabel.Name = "CodexStatus";
        statusLabel.AccessibleName = "Codex status";
        statusLabel.AutoSize = true;
        statusLabel.ForeColor = Muted;
        statusLabel.Font = new Font("Segoe UI Semibold", 9.5f);
        statusLabel.Margin = new Padding(0, 7, 14, 0);
        statusLabel.Text = "◉  starting…";

        queryLabel.AutoEllipsis = true;
        queryLabel.Dock = DockStyle.Fill;
        queryLabel.TextAlign = ContentAlignment.MiddleRight;
        queryLabel.ForeColor = Color.FromArgb(224, 224, 225);
        queryLabel.Margin = new Padding(8, 7, 10, 0);
        queryLabel.Text = "Ask Codex about what you see";

        StyleButton(copyButton, "▣");
        copyButton.Name = "CopyTranscript";
        copyButton.AccessibleName = "Copy transcript";
        copyButton.Font = new Font("Segoe UI Symbol", 11f);
        copyButton.Margin = new Padding(4, 0, 4, 0);

        StyleButton(closeButton, "×");
        closeButton.AccessibleName = "Hide Zommi";
        closeButton.Font = new Font("Segoe UI", 13f);
        closeButton.Margin = new Padding(4, 0, 0, 0);

        header.Controls.Add(statusLabel, 0, 0);
        header.Controls.Add(queryLabel, 1, 0);
        header.Controls.Add(copyButton, 2, 0);
        header.Controls.Add(closeButton, 3, 0);
        MakeDraggable(header, statusLabel, queryLabel);
        return header;
    }

    private Control BuildComposer()
    {
        var composer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            AutoSize = true,
            BackColor = Panel,
            Padding = new Padding(12, 10, 10, 10),
            ColumnCount = 2,
            Margin = new Padding(0),
        };
        composer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        composer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));

        input.Multiline = true;
        input.Name = "ZommiComposer";
        input.AccessibleName = "Zommi message with attached context tokens";
        input.AccessibleDescription = "Context tokens appear here as soon as Alt+A or Alt+Shift+A captures them.";
        input.AcceptsTab = false;
        input.BorderStyle = BorderStyle.None;
        input.BackColor = Panel;
        input.ForeColor = TextColor;
        input.Font = new Font("Segoe UI", 10.5f);
        input.MinimumSize = new Size(0, 66);
        input.Dock = DockStyle.Fill;
        input.ScrollBars = RichTextBoxScrollBars.Vertical;

        StyleButton(sendButton, "Send  ↵");
        sendButton.Name = "SendMessage";
        sendButton.AccessibleName = "Send message";
        sendButton.BackColor = Color.FromArgb(83, 83, 85);
        sendButton.Anchor = AnchorStyles.Bottom;
        sendButton.Margin = new Padding(10, 4, 0, 0);

        composer.Controls.Add(input, 0, 0);
        composer.Controls.Add(sendButton, 1, 0);
        return composer;
    }

    private static void StyleButton(Button button, string text)
    {
        button.Text = text;
        button.AutoSize = true;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = Color.FromArgb(67, 67, 69);
        button.ForeColor = TextColor;
        button.Padding = new Padding(8, 3, 8, 3);
        button.Cursor = Cursors.Hand;
    }

    private void MakeDraggable(params Control[] controls)
    {
        foreach (var control in controls)
        {
            control.MouseDown += (_, eventArgs) =>
            {
                if (eventArgs.Button != MouseButtons.Left)
                {
                    return;
                }

                _ = NativeMethods.ReleaseCapture();
                _ = NativeMethods.SendMessage(Handle, NativeMethods.WmNcLButtonDown, NativeMethods.HtCaption, 0);
            };
        }
    }

    private void ConfigureTrayIcon()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open floating chat", null, (_, _) => ShowChat());
        menu.Items.Add("Capture context (Alt+A)", null, (_, _) => CaptureContextAndShow());
        menu.Items.Add("Select image context (Alt+Shift+A)", null, (_, _) => SelectImageContext());
        menu.Items.Add("Exit Zommi", null, (_, _) => ExitApplication());
        trayIcon.Icon = SystemIcons.Application;
        trayIcon.Text = "Zommi floating Codex chat";
        trayIcon.ContextMenuStrip = menu;
        trayIcon.Visible = true;
        trayIcon.DoubleClick += (_, _) => ShowChat();
    }

    private async void OnShown(object? sender, EventArgs eventArgs)
    {
        if (autoLaunch)
        {
            Hide();
            trayIcon.ShowBalloonTip(
                2500,
                "Zommi is ready",
                "Hover over anything and press Alt+A. Use Alt+Shift+A to select image context.",
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
            ShowChat();
            RenderStatus("Acceptance mode · Codex relay disabled");
        }
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey)
        {
            if (message.WParam.ToInt32() == ContextHotkeyId)
            {
                CaptureContextAndShow();
                return;
            }

            if (message.WParam.ToInt32() == ImageHotkeyId)
            {
                SelectImageContext();
                return;
            }
        }

        base.WndProc(ref message);
    }

    private void RegisterInvocationHotkeys()
    {
        contextHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, ContextHotkeyId, ModAlt, VkA);
        imageHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, ImageHotkeyId, ModAlt | ModShift, VkA);
        shortcutLabel.AccessibleName =
            $"{shortcutLabel.Text}; Alt+A registered: {contextHotkeyRegistered}; Alt+Shift+A registered: {imageHotkeyRegistered}";
        shortcutLabel.AccessibleDescription =
            $"Alt+A registered: {contextHotkeyRegistered}; Alt+Shift+A registered: {imageHotkeyRegistered}";

        if (!contextHotkeyRegistered || !imageHotkeyRegistered)
        {
            var unavailable = new List<string>();
            if (!contextHotkeyRegistered)
            {
                unavailable.Add("Alt+A");
            }

            if (!imageHotkeyRegistered)
            {
                unavailable.Add("Alt+Shift+A");
            }

            RenderStatus($"Shortcut unavailable: {string.Join(", ", unavailable)}", warning: true);
        }
    }

    private void UnregisterInvocationHotkeys()
    {
        if (contextHotkeyRegistered)
        {
            _ = NativeMethods.UnregisterHotKey(Handle, ContextHotkeyId);
            contextHotkeyRegistered = false;
        }

        if (imageHotkeyRegistered)
        {
            _ = NativeMethods.UnregisterHotKey(Handle, ImageHotkeyId);
            imageHotkeyRegistered = false;
        }
    }

    private void CaptureContextAndShow()
    {
        var pointerBeforeFocus = ReadPointer();
        var result = capture.Capture(DateTimeOffset.UtcNow);
        if (result.Snapshot is not null)
        {
            AddAttachment(new ContextAttachment
            {
                Token = ContextTokens.Create(result.Snapshot, attachments.Select(item => item.Token)),
                Snapshot = result.Snapshot,
            });
            RenderStatus($"Attached {attachments[^1].Token}");
        }
        else if (!result.PreservePrevious)
        {
            RenderStatus("No accessible context was exposed under the pointer", warning: true);
        }

        ShowChat();
        RestorePointer(pointerBeforeFocus);
    }

    private void SelectImageContext()
    {
        var wasVisible = Visible;
        HideContextPreview();
        Hide();
        using var selector = regionSelectorFactory();
        var dialogResult = selector.ShowDialog();
        if (dialogResult == DialogResult.OK && selector.Result is { } result)
        {
            var token = ContextTokens.CreateImage(attachments.Select(item => item.Token));
            AddAttachment(new ContextAttachment
            {
                Token = token,
                ImagePng = result.Png,
            });
            RenderStatus($"Attached {token} · {result.Bounds.Width}×{result.Bounds.Height}");
            ShowChat();
            if (pointerOverride is not null)
            {
                pointerOverride = new Point(420, 120);
            }
        }
        else if (!string.IsNullOrWhiteSpace(selector.ErrorMessage))
        {
            RenderStatus($"Image selection failed: {selector.ErrorMessage}", warning: true);
            ShowChat();
        }
        else if (wasVisible)
        {
            ShowChat();
        }
    }

    private void AddAttachment(ContextAttachment attachment)
    {
        attachments.Add(attachment);
        if (input.TextLength > 0 && !char.IsWhiteSpace(input.Text[^1]))
        {
            input.AppendText(" ");
        }

        input.AppendText(attachment.Token + " ");
        input.SelectionStart = input.TextLength;
        StyleContextTokens();
    }

    internal void SeedAcceptanceContexts()
    {
        var now = DateTimeOffset.UtcNow;
        var first = new ContextSnapshot
        {
            SnapshotId = "seeded-docs-context",
            ObservedAtUtc = now,
            ExpiresAtUtc = now.AddMinutes(5),
            SurfaceKind = "Browser",
            Application = "Acceptance Browser",
            ProcessName = "acceptance-browser",
            WindowTitle = "Seeded documentation tab",
            Locator = new LocatorInfo { Kind = "URL", Value = "https://docs.example.com/guide" },
            Selection = ["SELECTED_TEXT_IS_PRIMARY"],
            VisibleText = Enumerable.Range(1, 80)
                .Select(index => $"Scrollable surrounding documentation line {index}")
                .ToArray(),
            Confidence = "high",
        };
        var second = first with
        {
            SnapshotId = "seeded-shop-context",
            WindowTitle = "Seeded shopping tab",
            Locator = new LocatorInfo { Kind = "URL", Value = "https://shop.example.com/item" },
            Selection = [],
            VisibleText = ["Second tab text"],
        };
        AddAttachment(new ContextAttachment
        {
            Token = ContextTokens.Create(first, attachments.Select(item => item.Token)),
            Snapshot = first,
        });
        AddAttachment(new ContextAttachment
        {
            Token = ContextTokens.Create(second, attachments.Select(item => item.Token)),
            Snapshot = second,
        });
        AddAttachment(new ContextAttachment
        {
            Token = ContextTokens.CreateImage(attachments.Select(item => item.Token)),
            ImagePng = Convert.FromBase64String(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="),
        });
        RenderStatus("seeded UI acceptance");
        Shown += (_, _) => BeginInvoke(() =>
        {
            pointerOverride = new Point(80, 80);
            contextPreview.ShowContext(attachments[0], new Point(Right - 30, Top + 40));
        });
    }

    private void ShowChat()
    {
        var pointerBeforeFocus = ReadPointer();
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
        RestorePointer(pointerBeforeFocus);
    }

    private void HideChat()
    {
        HideContextPreview();
        Hide();
    }

    private void PositionAwayFromPointer()
    {
        var pointer = ReadPointer();
        if (pointer is null)
        {
            CenterToScreen();
            return;
        }

        var point = pointer.Value;
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

    private Point? ReadPointer()
    {
        if (pointerOverride is { } overridden)
        {
            return overridden;
        }

        return NativeMethods.GetCursorPos(out var pointer)
            ? new Point(pointer.X, pointer.Y)
            : null;
    }

    private void RestorePointer(Point? pointer)
    {
        if (pointerOverride is null && pointer is { } value)
        {
            _ = NativeMethods.SetCursorPos(value.X, value.Y);
        }
    }

    private void StyleContextTokens()
    {
        if (stylingComposer || input.IsDisposed)
        {
            return;
        }

        stylingComposer = true;
        try
        {
            attachments.RemoveAll(attachment =>
                !input.Text.Contains(attachment.Token, StringComparison.Ordinal));
            var selectionStart = input.SelectionStart;
            var selectionLength = input.SelectionLength;
            input.SelectAll();
            input.SelectionColor = TextColor;
            input.SelectionBackColor = Panel;

            foreach (var attachment in attachments)
            {
                var offset = 0;
                while ((offset = input.Text.IndexOf(attachment.Token, offset, StringComparison.Ordinal)) >= 0)
                {
                    input.Select(offset, attachment.Token.Length);
                    input.SelectionColor = Accent;
                    input.SelectionBackColor = ContextChip;
                    offset += attachment.Token.Length;
                }
            }

            input.Select(
                Math.Min(selectionStart, input.TextLength),
                Math.Min(selectionLength, Math.Max(0, input.TextLength - selectionStart)));
        }
        finally
        {
            stylingComposer = false;
        }
    }

    private void InputMouseMove(object? sender, MouseEventArgs eventArgs)
    {
        var attachment = FindAttachmentAt(input.GetCharIndexFromPosition(eventArgs.Location));
        if (attachment is null)
        {
            ScheduleContextPreviewHide();
            input.Cursor = Cursors.IBeam;
            return;
        }

        CancelContextPreviewHide();
        input.Cursor = Cursors.Hand;
        if (!ReferenceEquals(previewedAttachment, attachment) || !contextPreview.Visible)
        {
            previewedAttachment = attachment;
            contextPreview.ShowContext(attachment, Cursor.Position);
        }
    }

    private ContextAttachment? FindAttachmentAt(int characterIndex)
    {
        foreach (var attachment in attachments)
        {
            var offset = 0;
            while ((offset = input.Text.IndexOf(attachment.Token, offset, StringComparison.Ordinal)) >= 0)
            {
                if (characterIndex >= offset && characterIndex < offset + attachment.Token.Length)
                {
                    return attachment;
                }

                offset += attachment.Token.Length;
            }
        }

        return null;
    }

    private void HideContextPreview()
    {
        CancelContextPreviewHide();
        previewedAttachment = null;
        contextPreview.Hide();
    }

    private void ScheduleContextPreviewHide()
    {
        if (!contextPreview.Visible)
        {
            return;
        }

        contextPreviewHideTimer.Stop();
        contextPreviewHideTimer.Start();
    }

    private void CancelContextPreviewHide()
    {
        contextPreviewHideTimer.Stop();
    }

    private void MonitorContextPreviewPointer()
    {
        contextPreviewHideTimer.Stop();
        if (contextPreview.Visible)
        {
            contextPreviewHideTimer.Start();
        }
    }

    private void FinishScheduledContextPreviewHide()
    {
        contextPreviewHideTimer.Stop();
        if (contextPreview.Visible && contextPreview.Bounds.Contains(Cursor.Position))
        {
            contextPreviewHideTimer.Start();
            return;
        }

        HideContextPreview();
    }

    private async Task SendCurrentMessageAsync()
    {
        if (turnActive)
        {
            return;
        }

        var visibleMessage = input.Text.Trim();
        var activeAttachments = attachments
            .Where(attachment => visibleMessage.Contains(attachment.Token, StringComparison.Ordinal))
            .ToArray();
        var message = visibleMessage;
        foreach (var attachment in activeAttachments)
        {
            message = message.Replace(attachment.Token, " ", StringComparison.Ordinal);
        }

        message = string.Join(' ', message.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (message.Length == 0)
        {
            return;
        }

        var snapshots = activeAttachments
            .Select(attachment => attachment.Snapshot)
            .Where(snapshot => snapshot is not null)
            .Cast<ContextSnapshot>()
            .ToArray();
        var images = activeAttachments
            .Select(attachment => attachment.ImageDataUrl)
            .Where(image => image is not null)
            .Cast<string>()
            .ToArray();

        turnActive = true;
        responsePrefixPending = true;
        activityHeaders.Clear();
        activityWithDelta.Clear();
        sendButton.Enabled = false;
        input.Enabled = false;
        queryLabel.Text = message;
        AppendTranscript("You", visibleMessage, Accent);
        input.Clear();
        attachments.RemoveAll(attachment => activeAttachments.Contains(attachment));
        HideContextPreview();
        RenderStatus("thinking…");
        try
        {
            await codex.StartTurnAsync(message, snapshots, images);
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

    private void AppendStreamUpdate(CodexStreamUpdate update)
    {
        if (update.Kind == CodexStreamKind.Assistant)
        {
            AppendAgentDelta(update.Text);
            return;
        }

        var itemKey = update.ItemId ?? $"{update.Kind}:{update.Title}";
        if (update.Lifecycle == CodexStreamLifecycle.Started)
        {
            EnsureActivityHeader(itemKey, update);
            if (update.Text.Length > 0 && update.Kind != CodexStreamKind.Thinking)
            {
                AppendActivityText(update.Text + Environment.NewLine, update.Kind);
            }

            RenderStatus(update.Kind == CodexStreamKind.Thinking ? "thinking…" : $"using {update.Title.ToLowerInvariant()}…");
            return;
        }

        if (update.Lifecycle == CodexStreamLifecycle.Delta)
        {
            EnsureActivityHeader(itemKey, update);
            if (update.Text.Length > 0)
            {
                AppendActivityText(update.Text, update.Kind);
                activityWithDelta.Add(itemKey);
            }

            RenderStatus(update.Kind == CodexStreamKind.Thinking ? "thinking…" : $"using {update.Title.ToLowerInvariant()}…");
            return;
        }

        EnsureActivityHeader(itemKey, update);
        if (!activityWithDelta.Contains(itemKey) && update.Text.Length > 0)
        {
            AppendActivityText(update.Text + Environment.NewLine, update.Kind);
        }

        if (update.Kind == CodexStreamKind.Tool && !string.IsNullOrWhiteSpace(update.Status))
        {
            AppendActivityText($"  ↳ {update.Status}{Environment.NewLine}", update.Kind);
        }

        AppendActivityText(Environment.NewLine, update.Kind);
    }

    private void EnsureActivityHeader(string itemKey, CodexStreamUpdate update)
    {
        if (!activityHeaders.Add(itemKey))
        {
            return;
        }

        var title = update.Kind switch
        {
            CodexStreamKind.Thinking => "◉  thinking…",
            CodexStreamKind.Plan => "◇  plan",
            CodexStreamKind.ToolOutput => "↳  tool output",
            _ => $"◇  {update.Title.ToLowerInvariant()}",
        };
        transcript.SelectionStart = transcript.TextLength;
        transcript.SelectionFont = new Font(transcript.Font, FontStyle.Bold);
        transcript.SelectionColor = update.Kind == CodexStreamKind.Thinking ? ThinkingColor : ToolColor;
        transcript.AppendText(title + Environment.NewLine);
        transcript.SelectionFont = transcript.Font;
    }

    private void AppendActivityText(string text, CodexStreamKind kind)
    {
        transcript.SelectionStart = transcript.TextLength;
        transcript.SelectionFont = transcript.Font;
        transcript.SelectionColor = kind == CodexStreamKind.Thinking ? ThinkingColor : Muted;
        transcript.AppendText(text);
        transcript.SelectionStart = transcript.TextLength;
        transcript.ScrollToCaret();
    }

    private void AppendAgentDelta(string delta)
    {
        if (delta.Length == 0)
        {
            return;
        }

        if (responsePrefixPending)
        {
            AppendTranscript("Codex", string.Empty, TextColor, appendTrailingNewline: false);
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
            ? "ready"
            : $"turn {status}",
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

    private void CopyTranscript()
    {
        if (!string.IsNullOrWhiteSpace(transcript.Text))
        {
            Clipboard.SetText(transcript.Text);
            RenderStatus("copied");
        }
    }

    private void RenderStatus(string status, bool warning = false)
    {
        statusLabel.Text = $"◉  {status}";
        statusLabel.AccessibleName = codex.ThreadId is null
            ? $"Codex status: {status}"
            : $"Codex status: {status}; thread {codex.ThreadId}";
        statusLabel.AccessibleDescription = codex.ThreadId is null
            ? status
            : $"Codex thread {codex.ThreadId}";
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
        contextPreviewHideTimer.Dispose();
        contextPreview.Dispose();
        codex.Dispose();
    }

    private void ExitApplication()
    {
        closeRequested = true;
        Close();
    }

    private void ApplyGlassEffect()
    {
        if (!IsHandleCreated)
        {
            return;
        }

        var enabled = 1;
        _ = NativeMethods.DwmSetWindowAttribute(
            Handle,
            NativeMethods.DwmWindowAttribute.UseImmersiveDarkMode,
            ref enabled,
            sizeof(int));
        var corner = (int)NativeMethods.DwmWindowCornerPreference.Round;
        _ = NativeMethods.DwmSetWindowAttribute(
            Handle,
            NativeMethods.DwmWindowAttribute.WindowCornerPreference,
            ref corner,
            sizeof(int));
        var backdrop = (int)NativeMethods.DwmSystemBackdropType.TransientWindow;
        _ = NativeMethods.DwmSetWindowAttribute(
            Handle,
            NativeMethods.DwmWindowAttribute.SystemBackdropType,
            ref backdrop,
            sizeof(int));
        ApplyRoundedRegion();
    }

    private void ApplyRoundedRegion()
    {
        if (Width <= 0 || Height <= 0)
        {
            return;
        }

        var regionHandle = NativeMethods.CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 26, 26);
        if (regionHandle == IntPtr.Zero)
        {
            return;
        }

        var replacement = System.Drawing.Region.FromHrgn(regionHandle);
        _ = NativeMethods.DeleteObject(regionHandle);
        var previous = Region;
        Region = replacement;
        previous?.Dispose();
    }

    private static class NativeMethods
    {
        internal const int WmNcLButtonDown = 0x00A1;
        internal const int HtCaption = 0x0002;

        internal enum DwmWindowAttribute
        {
            UseImmersiveDarkMode = 20,
            WindowCornerPreference = 33,
            SystemBackdropType = 38,
        }

        internal enum DwmWindowCornerPreference
        {
            Round = 2,
        }

        internal enum DwmSystemBackdropType
        {
            TransientWindow = 3,
        }

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool RegisterHotKey(IntPtr windowHandle, int id, uint modifiers, uint virtualKey);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool UnregisterHotKey(IntPtr windowHandle, int id);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool ReleaseCapture();

        [DllImport("user32.dll")]
        internal static extern IntPtr SendMessage(IntPtr windowHandle, int message, int wParam, int lParam);

        [DllImport("dwmapi.dll")]
        internal static extern int DwmSetWindowAttribute(
            IntPtr windowHandle,
            DwmWindowAttribute attribute,
            ref int attributeValue,
            int attributeSize);

        [DllImport("gdi32.dll")]
        internal static extern IntPtr CreateRoundRectRgn(
            int left,
            int top,
            int right,
            int bottom,
            int widthEllipse,
            int heightEllipse);

        [DllImport("gdi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool DeleteObject(IntPtr graphicsObject);

        [StructLayout(LayoutKind.Sequential)]
        internal struct Point
        {
            internal int X;
            internal int Y;
        }
    }
}
