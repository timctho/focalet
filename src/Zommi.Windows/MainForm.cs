using System.IO;
using Zommi.Core;

namespace Zommi.Windows;

internal sealed class MainForm : Form
{
    private static readonly Color Background = Color.FromArgb(20, 23, 31);
    private static readonly Color Card = Color.FromArgb(31, 36, 48);
    private static readonly Color Muted = Color.FromArgb(158, 166, 184);
    private static readonly Color TextColor = Color.FromArgb(240, 242, 247);
    private static readonly Color Accent = Color.FromArgb(111, 220, 181);
    private static readonly Color Warning = Color.FromArgb(255, 193, 92);

    private readonly StateStore stateStore;
    private readonly SharedSnapshotStore snapshots;
    private readonly ForegroundContextCapture capture;
    private readonly bool autoLaunch;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 700 };
    private readonly Label modeLabel = new() { AutoSize = true };
    private readonly Label hookLabel = new() { AutoSize = true };
    private readonly Label sessionDetailLabel = new() { AutoSize = true, MaximumSize = new Size(430, 0) };
    private readonly Label surfaceValue = CreateReadout();
    private readonly Label windowValue = CreateReadout();
    private readonly Label locatorValue = CreateReadout();
    private readonly Label targetValue = CreateReadout();
    private readonly Label selectionValue = CreateReadout();
    private readonly Label deliveryValue = CreateReadout();
    private readonly Button pauseButton = CreateButton("Pause");
    private readonly Button freezeButton = CreateButton("Freeze");
    private readonly Button newCodexButton = CreateButton("New Codex in WSL");

    private string integrationStatus = "Preparing WSL";
    private bool launchInProgress;
    private bool closing;

    public MainForm(
        StateStore stateStore,
        SharedSnapshotStore snapshots,
        ForegroundContextCapture capture,
        bool autoLaunch)
    {
        this.stateStore = stateStore;
        this.snapshots = snapshots;
        this.capture = capture;
        this.autoLaunch = autoLaunch;

        Text = "Zommi — live context for Codex";
        StartPosition = FormStartPosition.Manual;
        Location = new Point(Math.Max(24, Screen.PrimaryScreen?.WorkingArea.Right - 500 ?? 24), 48);
        ClientSize = new Size(456, 720);
        MinimumSize = new Size(430, 620);
        BackColor = Background;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 9.5f);
        TopMost = true;

        Controls.Add(BuildLayout());

        pauseButton.Click += (_, _) => TogglePause();
        freezeButton.Click += (_, _) => ToggleFreeze();
        newCodexButton.Click += async (_, _) => await LaunchNewWslCodexAsync();
        timer.Tick += (_, _) => OnTick();
        FormClosing += (_, _) => StopCaptureOnExit();
        Shown += async (_, _) =>
        {
            if (this.autoLaunch)
            {
                await LaunchNewWslCodexAsync();
            }
            else
            {
                integrationStatus = "Automatic launch disabled";
                RenderState();
            }
        };

        RenderState();
        timer.Start();
    }

    private Control BuildLayout()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(16),
            ColumnCount = 1,
            RowCount = 8,
            AutoScroll = true,
        };
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));

        var title = new Label
        {
            Text = "Zommi",
            AutoSize = true,
            Font = new Font("Segoe UI Semibold", 22f),
            ForeColor = TextColor,
        };
        var subtitle = new Label
        {
            Text = "Live desktop context for a fresh Codex session in WSL",
            AutoSize = true,
            ForeColor = Muted,
            Margin = new Padding(2, 0, 0, 10),
        };
        var header = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Dock = DockStyle.Fill };
        header.Controls.Add(title);
        header.Controls.Add(subtitle);
        root.Controls.Add(header);

        var statusRow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        StylePill(modeLabel);
        StylePill(hookLabel);
        statusRow.Controls.Add(modeLabel);
        statusRow.Controls.Add(hookLabel);
        root.Controls.Add(statusRow);

        var sessionCard = CreateCard("CODEX SESSION");
        var sessionGrid = sessionCard.Controls.OfType<TableLayoutPanel>().Single();
        sessionGrid.SetColumnSpan(sessionDetailLabel, 3);
        sessionGrid.Controls.Add(sessionDetailLabel, 0, 0);
        var detachButton = CreateButton("Detach");
        detachButton.Click += (_, _) => Detach();
        sessionGrid.Controls.Add(detachButton, 0, 1);
        sessionGrid.Controls.Add(pauseButton, 1, 1);
        sessionGrid.Controls.Add(freezeButton, 2, 1);
        root.Controls.Add(sessionCard);

        var snapshotCard = CreateCard("LATEST EPHEMERAL SNAPSHOT");
        var snapshotGrid = snapshotCard.Controls.OfType<TableLayoutPanel>().Single();
        AddReadout(snapshotGrid, "Surface", surfaceValue, 0);
        AddReadout(snapshotGrid, "Window", windowValue, 1);
        AddReadout(snapshotGrid, "Locator", locatorValue, 2);
        AddReadout(snapshotGrid, "Pointer target", targetValue, 3);
        AddReadout(snapshotGrid, "Selection", selectionValue, 4);
        AddReadout(snapshotGrid, "Last handoff", deliveryValue, 5);
        root.Controls.Add(snapshotCard);

        var launchCard = CreateCard("CODEX CLI IN WSL");
        var launchGrid = launchCard.Controls.OfType<TableLayoutPanel>().Single();
        var launchDescription = new Label
        {
            Text = "Zommi installs its local hook, opens the default WSL distribution, starts a new Codex CLI chat, and binds it automatically.",
            AutoSize = true,
            MaximumSize = new Size(400, 0),
            ForeColor = Muted,
        };
        launchGrid.SetColumnSpan(launchDescription, 3);
        launchGrid.Controls.Add(launchDescription, 0, 0);
        launchGrid.SetColumnSpan(newCodexButton, 3);
        launchGrid.Controls.Add(newCodexButton, 0, 1);
        root.Controls.Add(launchCard);

        var privacy = new Label
        {
            Text = "No screenshots. One expiring snapshot is overwritten locally. Terminal focus never replaces your last browser or Explorer context.",
            AutoSize = true,
            MaximumSize = new Size(420, 0),
            ForeColor = Muted,
            Padding = new Padding(3, 8, 3, 3),
        };
        root.Controls.Add(privacy);
        return root;
    }

    private static TableLayoutPanel CreateCard(string heading)
    {
        var panel = new TableLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Top,
            BackColor = Card,
            Padding = new Padding(12),
            Margin = new Padding(0, 8, 0, 0),
            ColumnCount = 1,
            RowCount = 2,
        };
        panel.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var layout = new TableLayoutPanel
        {
            AutoSize = true,
            Dock = DockStyle.Top,
            ColumnCount = 3,
            RowCount = 1,
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var title = new Label
        {
            Text = heading,
            AutoSize = true,
            ForeColor = Muted,
            Font = new Font("Segoe UI Semibold", 8.5f),
            Dock = DockStyle.Top,
            Padding = new Padding(0, 0, 0, 7),
        };
        panel.Controls.Add(title, 0, 0);
        panel.Controls.Add(layout, 0, 1);
        return panel;
    }

    private static void AddReadout(TableLayoutPanel grid, string label, Label value, int row)
    {
        while (grid.RowCount <= row)
        {
            grid.RowCount++;
        }

        var name = new Label
        {
            Text = label,
            AutoSize = true,
            ForeColor = Muted,
            Margin = new Padding(0, row == 0 ? 0 : 7, 10, 0),
        };
        grid.Controls.Add(name, 0, row);
        grid.SetColumnSpan(value, 2);
        grid.Controls.Add(value, 1, row);
    }

    private static Label CreateReadout() => new()
    {
        AutoSize = true,
        ForeColor = TextColor,
        MaximumSize = new Size(300, 0),
        Text = "—",
    };

    private static Button CreateButton(string text) => new()
    {
        Text = text,
        AutoSize = true,
        FlatStyle = FlatStyle.Flat,
        BackColor = Color.FromArgb(46, 53, 70),
        ForeColor = TextColor,
        Margin = new Padding(4),
        Padding = new Padding(4, 1, 4, 1),
    };

    private static void StylePill(Label label)
    {
        label.BackColor = Card;
        label.ForeColor = TextColor;
        label.Padding = new Padding(9, 5, 9, 5);
        label.Margin = new Padding(0, 0, 8, 4);
    }

    private void OnTick()
    {
        try
        {
            var binding = stateStore.ReadBinding();
            if (binding is { SessionId: not null, Mode: CaptureMode.Active })
            {
                var captureResult = capture.Capture(DateTimeOffset.UtcNow);
                if (captureResult.Snapshot is not null)
                {
                    snapshots.WriteSnapshot(captureResult.Snapshot);
                }
                else if (!captureResult.PreservePrevious)
                {
                    snapshots.DeleteSnapshot();
                }
            }

            var currentSnapshot = snapshots.ReadSnapshot();
            if (currentSnapshot is not null && currentSnapshot.ExpiresAtUtc < DateTimeOffset.UtcNow)
            {
                snapshots.DeleteSnapshot();
            }

            var launchIntent = stateStore.ReadLaunchIntent();
            if (launchIntent is not null && launchIntent.ExpiresAtUtc < DateTimeOffset.UtcNow)
            {
                stateStore.DeleteLaunchIntent();
                if (stateStore.ReadBinding()?.SessionId is null)
                {
                    integrationStatus = "Codex session was not detected";
                }
            }

            RenderState();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            modeLabel.Text = "Capture error";
            modeLabel.ForeColor = Warning;
        }
    }

    private void Detach()
    {
        stateStore.WriteBinding(new BindingState
        {
            SessionId = null,
            Mode = CaptureMode.Detached,
            UpdatedAtUtc = DateTimeOffset.UtcNow,
        });
        stateStore.DeleteLaunchIntent();
        snapshots.DeleteSnapshot();
        RenderState();
    }

    private void TogglePause()
    {
        var binding = stateStore.ReadBinding();
        if (binding?.SessionId is null)
        {
            return;
        }

        var nextMode = binding.Mode == CaptureMode.Paused ? CaptureMode.Active : CaptureMode.Paused;
        stateStore.WriteBinding(binding with { Mode = nextMode, UpdatedAtUtc = DateTimeOffset.UtcNow });
        if (nextMode == CaptureMode.Paused)
        {
            snapshots.DeleteSnapshot();
        }

        RenderState();
    }

    private void ToggleFreeze()
    {
        var binding = stateStore.ReadBinding();
        if (binding?.SessionId is null || binding.Mode == CaptureMode.Paused)
        {
            return;
        }

        if (binding.Mode == CaptureMode.Frozen)
        {
            stateStore.WriteBinding(binding with { Mode = CaptureMode.Active, UpdatedAtUtc = DateTimeOffset.UtcNow });
        }
        else
        {
            var snapshot = snapshots.ReadSnapshot();
            if (snapshot is null)
            {
                return;
            }

            snapshots.WriteSnapshot(snapshot with { ExpiresAtUtc = DateTimeOffset.UtcNow.AddMinutes(15) });
            stateStore.WriteBinding(binding with { Mode = CaptureMode.Frozen, UpdatedAtUtc = DateTimeOffset.UtcNow });
        }

        RenderState();
    }

    private void RenderState()
    {
        var binding = stateStore.ReadBinding() ?? new BindingState { Mode = CaptureMode.Detached };
        modeLabel.Text = binding.Mode switch
        {
            CaptureMode.Active => "● Capturing",
            CaptureMode.Frozen => "◆ Frozen",
            CaptureMode.Paused => "Ⅱ Paused",
            _ => "○ Detached",
        };
        modeLabel.ForeColor = binding.Mode == CaptureMode.Active ? Accent : binding.Mode == CaptureMode.Detached ? Muted : Warning;
        hookLabel.Text = integrationStatus;
        hookLabel.ForeColor = integrationStatus.Contains("failed", StringComparison.OrdinalIgnoreCase) ||
                              integrationStatus.Contains("not detected", StringComparison.OrdinalIgnoreCase)
            ? Warning
            : Accent;
        pauseButton.Text = binding.Mode == CaptureMode.Paused ? "Resume" : "Pause";
        freezeButton.Text = binding.Mode == CaptureMode.Frozen ? "Unfreeze" : "Freeze";
        pauseButton.Enabled = binding.SessionId is not null;
        freezeButton.Enabled = binding.SessionId is not null && binding.Mode != CaptureMode.Paused;

        var boundSession = stateStore.ReadSessions().FirstOrDefault(session =>
            string.Equals(session.SessionId, binding.SessionId, StringComparison.OrdinalIgnoreCase));
        sessionDetailLabel.ForeColor = Muted;
        var launchIntent = stateStore.ReadLaunchIntent();
        sessionDetailLabel.Text = binding.SessionId is not null
            ? $"Bound exactly to {binding.SessionId}\n{boundSession?.WorkingDirectory ?? "Working directory unavailable"}"
            : launchIntent is not null && launchIntent.ExpiresAtUtc >= DateTimeOffset.UtcNow
                ? "Starting a fresh Codex session in the default WSL distribution…"
                : "No Codex session is bound.";

        var snapshot = snapshots.ReadSnapshot();
        if (snapshot is null)
        {
            surfaceValue.Text = "—";
            windowValue.Text = "—";
            locatorValue.Text = "—";
            targetValue.Text = "—";
            selectionValue.Text = "—";
        }
        else
        {
            surfaceValue.Text = $"{snapshot.Application} · {snapshot.SurfaceKind} · {Age(snapshot.ObservedAtUtc)}";
            windowValue.Text = EmptyAsDash(snapshot.WindowTitle);
            locatorValue.Text = snapshot.Locator is null ? "Unavailable (not inferred)" : $"{snapshot.Locator.Kind}: {snapshot.Locator.Value}";
            targetValue.Text = snapshot.IndicatedTarget is null
                ? "Unavailable"
                : $"{snapshot.IndicatedTarget.ControlType ?? "control"}: {EmptyAsDash(snapshot.IndicatedTarget.Name)} ({snapshot.IndicatedTarget.Confidence})";
            selectionValue.Text = snapshot.Selection.Count == 0 ? "None exposed" : string.Join(" · ", snapshot.Selection);
        }

        var delivery = stateStore.ReadDelivery();
        deliveryValue.Text = delivery is null
            ? "None yet"
            : $"Snapshot {delivery.SnapshotId[..Math.Min(8, delivery.SnapshotId.Length)]} → {delivery.SessionId[..Math.Min(8, delivery.SessionId.Length)]} · {Age(delivery.DeliveredAtUtc)}";
    }

    private async Task LaunchNewWslCodexAsync()
    {
        if (launchInProgress)
        {
            return;
        }

        launchInProgress = true;
        newCodexButton.Enabled = false;
        integrationStatus = "Preparing WSL";
        RenderState();

        var previousBinding = stateStore.ReadBinding();
        var launchToken = Guid.NewGuid().ToString("N");
        try
        {
            var stateRoot = stateStore.RootDirectory;
            var channel = Environment.GetEnvironmentVariable("ZOMMI_CHANNEL");
            var installResult = await Task.Run(() => HookInstaller.InstallWsl(launchToken, stateRoot, channel));
            if (closing)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            stateStore.WriteLaunchIntent(new SessionLaunchIntent
            {
                Token = launchToken,
                ExpectedWorkingDirectory = installResult.Environment.LinuxHome,
                CreatedAtUtc = now,
                ExpiresAtUtc = now.AddMinutes(2),
            });
            stateStore.WriteBinding(new BindingState
            {
                SessionId = null,
                Mode = CaptureMode.Detached,
                UpdatedAtUtc = now,
            });
            snapshots.DeleteSnapshot();

            await Task.Run(() => WslCodexLauncher.Launch(installResult.Environment));
            integrationStatus = $"WSL ready · {installResult.Environment.DistroName}";
        }
        catch (Exception exception)
        {
            stateStore.DeleteLaunchIntent();
            stateStore.WriteBinding(previousBinding ?? new BindingState
            {
                SessionId = null,
                Mode = CaptureMode.Detached,
                UpdatedAtUtc = DateTimeOffset.UtcNow,
            });
            if (!closing)
            {
                integrationStatus = "WSL launch failed";
                MessageBox.Show(
                    this,
                    $"Could not start a fresh Codex session in WSL: {exception.Message}",
                    "Launch failed",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
            }
        }
        finally
        {
            launchInProgress = false;
            if (!closing && !IsDisposed)
            {
                newCodexButton.Enabled = true;
                RenderState();
            }
        }
    }

    private void StopCaptureOnExit()
    {
        closing = true;
        timer.Stop();
        stateStore.DeleteLaunchIntent();
        var binding = stateStore.ReadBinding();
        if (binding?.SessionId is not null)
        {
            stateStore.WriteBinding(binding with { Mode = CaptureMode.Paused, UpdatedAtUtc = DateTimeOffset.UtcNow });
        }

        snapshots.DeleteSnapshot();
    }

    private static string EmptyAsDash(string? value) => string.IsNullOrWhiteSpace(value) ? "—" : value;

    private static string Age(DateTimeOffset time)
    {
        var seconds = Math.Max(0, (int)(DateTimeOffset.UtcNow - time).TotalSeconds);
        return seconds < 60 ? $"{seconds}s ago" : $"{seconds / 60}m ago";
    }

}
