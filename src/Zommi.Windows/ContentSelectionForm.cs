using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record ContentSelection(Rectangle Region, nint Window, CaptureRectangle? WindowBounds,
    string? WindowTitle, int ProcessId, bool WholeWindow);

/// <summary>One desktop gesture surface: click an outlined object, drag a region,
/// or choose the whole window. Selection clicks never reach the source app.</summary>
internal sealed class ContentSelectionForm : PointSelectionForm
{
    private readonly ContentScopeObserver observer;
    private readonly System.Windows.Forms.Timer hoverTimer = new() { Interval = 32 };
    private readonly FlowLayoutPanel toolbar = new()
    {
        AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
        WrapContents = false, Padding = new Padding(8),
    };
    private readonly Button larger;
    private readonly Button smaller;
    private readonly Button wholeWindow;
    private readonly Label hint = new() { AutoSize = true, Padding = new Padding(8, 10, 8, 4) };
    private IReadOnlyList<ContentOutline> scopes = [];
    private int scopeIndex;
    private bool scopePinned;
    private long observationVersion;
    private bool observationPending;
    private long nextRefreshAt;
    private Point? lastPoint;
    private Point? observedPoint;
    private Point? confirmPoint;
    private long confirmUntil;
    private Point? anchor;
    private Rectangle dragged;
    private nint targetWindow;
    private CaptureRectangle? targetBounds;
    private string targetTitle = "";
    private int targetProcessId;
    private readonly List<ContentSelection> selections = [];
    private readonly Queue<(Point Start, Point End, bool Additive)> pendingGestures = new();
    private bool additiveGesture;
    private bool confirmAdditive;
    private bool finishRequested;
    private const int MaximumSelections = 16;

    public ContentSelectionForm(uint returnProcessId) : base(returnProcessId)
    {
        observer = new ContentScopeObserver(returnProcessId, observation =>
        {
            try { BeginInvoke(() => ApplyObservation(observation)); }
            catch (InvalidOperationException) { } // The user closed the picker.
        });
        Text = "Zommi content selection";
        Opacity = 0.65;
        toolbar.BackColor = Color.FromArgb(35, 39, 51);
        toolbar.ForeColor = Color.White;
        toolbar.Controls.Add(hint);
        smaller = AddButton("Smaller", () => ChangeScope(-1));
        larger = AddButton("Larger", () => ChangeScope(1));
        wholeWindow = AddButton("Whole window", SelectWindow);
        AddButton("Cancel", () => { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); });
        Controls.Add(toolbar);
        UpdateHint();
        PositionToolbar(Cursor.Position);
        hoverTimer.Tick += (_, _) => ObservePointer();
    }

    public IReadOnlyList<ContentSelection> Selections => selections;
    public string? ErrorMessage { get; private set; }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData)
    {
        // Enter confirms the outlined content even when a toolbar button has
        // focus. Otherwise WinForms can activate the initially focused Cancel.
        if ((keyData & Keys.KeyCode) == Keys.Enter)
        {
            if (anchor is not null || confirmPoint is not null || pendingGestures.Count > 0) finishRequested = true;
            else if (selections.Count > 0) Finish();
            else ConfirmObject();
            return true;
        }
        if (keyData == Keys.Up) { ChangeScope(1); return true; }
        if (keyData == Keys.Down) { ChangeScope(-1); return true; }
        return base.ProcessCmdKey(ref message, keyData);
    }

    private Button AddButton(string text, Action action)
    {
        var button = new Button { Text = text, AccessibleName = text, AutoSize = true, FlatStyle = FlatStyle.Flat, TabStop = true };
        button.Click += (_, _) => action();
        toolbar.Controls.Add(button);
        return button;
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        PositionToolbar(Cursor.Position);
        hoverTimer.Start();
        ObservePointer();
    }

    private void PositionToolbar(Point point)
    {
        var area = Screen.FromPoint(point).WorkingArea;
        var size = toolbar.PreferredSize;
        var x = area.Left + (area.Width - size.Width) / 2;
        var y = area.Top + 24;
        toolbar.Location = new Point(
            Math.Clamp(x, area.Left + 12, Math.Max(area.Left + 12, area.Right - size.Width - 12)) - Left,
            Math.Clamp(y, area.Top + 12, Math.Max(area.Top + 12, area.Bottom - size.Height - 12)) - Top);
    }

    private void ObservePointer()
    {
        var point = Cursor.Position;
        if (anchor is not null) return;
        if (confirmPoint is { } pressed)
        {
            if (!observationPending && Environment.TickCount64 >= nextRefreshAt) RequestObservation(pressed);
            return;
        }
        if (toolbar.Bounds.Contains(PointToClient(point))) return;
        if (point == lastPoint && (observationPending || Environment.TickCount64 < nextRefreshAt)) return;
        // Only an explicitly expanded scope stays pinned. Ordinary hover must
        // keep looking inside large containers to find their smaller children.
        if (scopePinned && scopes.Count > 0 && scopes[scopeIndex].Bounds.Contains(point)) return;
        RequestObservation(point);
    }

    private void RequestObservation(Point point)
    {
        lastPoint = point;
        scopePinned = false;
        observationPending = true;
        if (scopes.Count > 0 && !scopes[scopeIndex].Bounds.Contains(point))
        {
            var previous = OutlineBounds;
            scopes = [];
            scopeIndex = 0;
            targetBounds = null;
            UpdateHint();
            InvalidateOutline(previous);
        }
        observer.Request(++observationVersion, point);
    }

    private void ApplyObservation(ContentObservation observation)
    {
        if (IsDisposed || !Visible || observation.Version != observationVersion) return;
        var currentPoint = Cursor.Position;
        if (anchor is null && confirmPoint is null && currentPoint != observation.Point &&
            !toolbar.Bounds.Contains(PointToClient(currentPoint)))
        {
            RequestObservation(currentPoint);
            return;
        }
        var previous = OutlineBounds;
        var changed = !scopes.SequenceEqual(observation.Outlines);
        observationPending = false;
        nextRefreshAt = Environment.TickCount64 + 600;
        observedPoint = observation.Point;
        targetWindow = observation.Window;
        targetBounds = observation.WindowBounds;
        targetTitle = observation.WindowTitle;
        targetProcessId = observation.ProcessId;
        scopes = observation.Outlines;
        scopeIndex = 0;
        UpdateHint();
        if (changed) InvalidateOutline(previous);
        ResolveConfirmation();
    }

    private void ResolveConfirmation()
    {
        if (anchor is null && confirmPoint is not null && confirmPoint == observedPoint)
        {
            if (scopes.Count > 0)
            {
                confirmPoint = null;
                SelectObject(confirmAdditive);
            }
            else if (Environment.TickCount64 < confirmUntil)
            {
                // A provider timeout is not a resolved click. Retry that exact
                // press after it recovers, without blocking drag or cancellation.
                nextRefreshAt = Environment.TickCount64 + 100;
            }
            else
            {
                ErrorMessage = "The selected item could not be resolved. Try dragging a rectangle around it.";
                GrantForeground();
                DialogResult = DialogResult.Cancel;
                Close();
            }
        }
    }

    private void ChangeScope(int delta)
    {
        if (scopes.Count == 0) return;
        var previous = OutlineBounds;
        // Ignore in-flight hover results after an explicit scope adjustment.
        observationVersion++;
        observationPending = false;
        scopePinned = true;
        scopeIndex = Math.Clamp(scopeIndex + delta, 0, scopes.Count - 1);
        UpdateHint();
        InvalidateOutline(previous);
    }

    private void UpdateHint()
    {
        hint.Text = selections.Count == 0 ? "Drag or click · Ctrl to select several" :
            $"{selections.Count} selected · Enter to attach · Esc to cancel";
        toolbar.AccessibleDescription = "The image includes readable content inside your selection when available.";
        smaller.Enabled = scopeIndex > 0;
        larger.Enabled = scopeIndex + 1 < scopes.Count;
        wholeWindow.Enabled = targetBounds is { IsValid: true };
    }

    private void SelectObject(bool additive = false)
    {
        if (scopes.Count == 0) return;
        Complete(scopes[scopeIndex].Bounds, targetWindow, additive);
    }

    private void ConfirmObject(Point? point = null, bool additive = false)
    {
        if (point is null && scopePinned) { SelectObject(additive); return; }
        var target = point ?? lastPoint ?? Cursor.Position;
        if ((scopePinned && scopes.Count > 0 && scopes[scopeIndex].Bounds.Contains(target)) ||
            !observationPending && observedPoint == target && scopes.Count > 0)
        {
            SelectObject(additive);
            return;
        }
        // A quick click may beat the background lookup. Resolve that exact
        // press location without blocking the UI or attaching an old outline.
        confirmPoint = target;
        confirmAdditive = additive;
        confirmUntil = Environment.TickCount64 + 2_000;
        RequestObservation(target);
    }

    private void SelectWindow()
    {
        if (targetBounds is not { IsValid: true }) return;
        Complete(NativeCaptureWindow.CaptureBounds(targetWindow), targetWindow,
            (ModifierKeys & Keys.Control) != 0 || selections.Count > 0, wholeWindow: true);
    }

    private void Complete(Rectangle bounds, nint window, bool additive = false, bool wholeWindow = false)
    {
        if (bounds.Width < 4 || bounds.Height < 4) return;
        if (selections.Count >= MaximumSelections)
        {
            hint.Text = $"Maximum {MaximumSelections} selections · Enter to attach";
            finishRequested = false;
            return;
        }
        var identityBounds = window == 0 ? null : targetBounds;
        var title = window == 0 ? null : targetTitle;
        var processId = window == 0 ? 0 : targetProcessId;
        if (window == 0)
        {
            // Bind a queued rectangle now, while the overlay excludes itself.
            // Rectangles spanning several apps keep geometry without a guessed source.
            window = NativeCaptureWindow.ForRegion(bounds);
            if (window != 0)
            {
                identityBounds = NativeCaptureWindow.Bounds(window);
                title = NativeCaptureWindow.Title(window);
                processId = NativeCaptureWindow.ProcessId(window);
            }
        }
        var continueBatch = additive || selections.Count > 0 || pendingGestures.Count > 0;
        var selected = new ContentSelection(bounds, window, identityBounds, title, processId, wholeWindow);
        if (!selections.Contains(selected)) selections.Add(selected);
        if (continueBatch)
        {
            observationVersion++;
            observationPending = false;
            confirmPoint = null;
            scopePinned = false;
            lastPoint = null;
            var previous = OutlineBounds;
            scopes = [];
            scopeIndex = 0;
            UpdateHint();
            InvalidateOutline(previous);
            InvalidateOutline(bounds);
            ContinuePendingGestures();
            return;
        }
        Finish();
    }

    private void Finish()
    {
        if (selections.Count == 0) return;
        GrantForeground();
        DialogResult = DialogResult.OK;
        Close();
    }

    private void ContinuePendingGestures()
    {
        if (anchor is not null || confirmPoint is not null) return;
        if (pendingGestures.TryDequeue(out var gesture))
            CommitGesture(gesture.Start, gesture.End, gesture.Additive);
        else if (finishRequested) Finish();
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Right) { GrantForeground(); DialogResult = DialogResult.Cancel; Close(); return; }
        if (e.Button != MouseButtons.Left) return;
        var previous = OutlineBounds;
        anchor = PointToScreen(e.Location);
        additiveGesture = (ModifierKeys & Keys.Control) != 0 || selections.Count > 0;
        finishRequested = false;
        dragged = Rectangle.Empty;
        Capture = true;
        if (confirmPoint is null && lastPoint != anchor && !(scopePinned && scopes.Count > 0 && scopes[scopeIndex].Bounds.Contains(anchor.Value)))
            RequestObservation(anchor.Value);
        InvalidateOutline(previous);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (anchor is not { } start) return;
        var previous = OutlineBounds;
        var point = PointToScreen(e.Location);
        dragged = Rectangle.FromLTRB(Math.Min(start.X, point.X), Math.Min(start.Y, point.Y), Math.Max(start.X, point.X), Math.Max(start.Y, point.Y));
        InvalidateOutline(previous);
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left || anchor is not { } start) return;
        var point = PointToScreen(e.Location);
        anchor = null;
        Capture = false;
        if (confirmPoint is not null)
        {
            if (pendingGestures.Count + selections.Count + 1 < MaximumSelections)
                pendingGestures.Enqueue((start, point, additiveGesture));
            ResolveConfirmation();
            return;
        }
        CommitGesture(start, point, additiveGesture);
    }

    private void CommitGesture(Point start, Point point, bool additive)
    {
        var previous = OutlineBounds;
        if (Math.Abs(point.X - start.X) >= 4 && Math.Abs(point.Y - start.Y) >= 4)
            Complete(Rectangle.FromLTRB(Math.Min(start.X, point.X), Math.Min(start.Y, point.Y), Math.Max(start.X, point.X), Math.Max(start.Y, point.Y)), 0, additive);
        else if (Math.Abs(point.X - start.X) < 4 && Math.Abs(point.Y - start.Y) < 4) ConfirmObject(start, additive);
        else
        {
            // A thin accidental drag neither attaches a stale object nor
            // disables the next gesture.
            RequestObservation(point);
            InvalidateOutline(previous);
            ContinuePendingGestures();
        }
    }

    private Rectangle OutlineBounds => anchor is not null ? dragged : scopes.Count > 0 ? scopes[scopeIndex].Bounds : Rectangle.Empty;

    private void InvalidateOutline(Rectangle previous)
    {
        foreach (var bounds in new[] { previous, OutlineBounds })
        {
            if (bounds.IsEmpty) continue;
            var dirty = bounds;
            dirty.Offset(-Left, -Top);
            dirty.Inflate(4, 4);
            Invalidate(dirty);
            // Include the old/new label without repainting the whole desktop.
            Invalidate(new Rectangle(0, Math.Max(0, dirty.Top - 48), ClientSize.Width, 96));
        }
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        using var selectedPen = new Pen(Color.FromArgb(111, 205, 255), 3);
        using var numberFont = new Font("Segoe UI", 10, FontStyle.Bold);
        for (var index = 0; index < selections.Count; index++)
        {
            var selected = selections[index].Region;
            selected.Offset(-Left, -Top);
            e.Graphics.DrawRectangle(selectedPen, selected);
            var numberX = selected.Left + 3;
            var numberY = selected.Width < 36 || selected.Height < 30 ? Math.Max(0, selected.Top - 26) : selected.Top + 3;
            e.Graphics.FillRectangle(Brushes.Black, numberX, numberY, 28, 24);
            e.Graphics.DrawString((index + 1).ToString(), numberFont, Brushes.White, numberX + 4, numberY + 2);
        }
        var bounds = OutlineBounds;
        if (bounds.IsEmpty) return;
        bounds.Offset(-Left, -Top);
        using var pen = new Pen(Color.White, 3);
        using var fill = new SolidBrush(Color.FromArgb(45, 255, 255, 255));
        e.Graphics.FillRectangle(fill, bounds);
        e.Graphics.DrawRectangle(pen, bounds);
        var label = anchor is not null ? $"{bounds.Width} × {bounds.Height}" : scopes[scopeIndex].Label;
        using var font = new Font("Segoe UI", 11);
        var size = e.Graphics.MeasureString(label, font);
        var position = new PointF(Math.Clamp(bounds.Left, 4, Math.Max(4, ClientSize.Width - size.Width - 16)), Math.Clamp(bounds.Top - size.Height - 8, 4, Math.Max(4, ClientSize.Height - size.Height - 12)));
        e.Graphics.FillRectangle(Brushes.Black, position.X, position.Y, size.Width + 12, size.Height + 6);
        e.Graphics.DrawString(label, font, Brushes.White, position.X + 6, position.Y + 3);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { hoverTimer.Dispose(); observer.Dispose(); }
        base.Dispose(disposing);
    }
}
