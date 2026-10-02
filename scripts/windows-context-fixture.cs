using System;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

// UIA requests require a live message pump while the acceptance driver waits
// for the separate capture process. Never create this fixture on that driver.
public sealed class ZommiContextFixture : IDisposable
{
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    private readonly Thread thread;
    private readonly ManualResetEvent ready = new ManualResetEvent(false);
    private Form form;
    private Button front;
    private Button back;
    private DataGridView grid;
    private Exception failure;
    public IntPtr Window { get; private set; }

    public ZommiContextFixture()
    {
        thread = new Thread(() =>
        {
            var previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
            try
            {
                form = new Form {
                    Text = "Zommi native context fixture", FormBorderStyle = FormBorderStyle.None,
                    StartPosition = FormStartPosition.Manual, Bounds = new Rectangle(140, 140, 500, 360),
                    TopMost = true, ShowInTaskbar = false, BackColor = Color.White, AutoScaleMode = AutoScaleMode.None,
                };
                var panel = new Panel { Bounds = new Rectangle(20, 20, 420, 260), AccessibleName = "Native comment", BackColor = Color.AliceBlue };
                panel.Controls.Add(new Label { Text = "Selected native line", AutoSize = false, Bounds = new Rectangle(20, 40, 350, 40), Font = new Font("Segoe UI", 14) });
                panel.Controls.Add(new Label { Text = "Parent includes this second line.", AutoSize = false, Bounds = new Rectangle(20, 110, 350, 40), Font = new Font("Segoe UI", 14) });
                panel.Controls.Add(new Button { Text = "+", AccessibleName = "Tiny add item", Bounds = new Rectangle(350, 195, 18, 18) });
                panel.Controls.Add(new Button { Text = "-", AccessibleName = "Tiny remove item", Bounds = new Rectangle(374, 195, 18, 18) });
                form.Controls.Add(panel);
                back = new Button { Text = "Behind", AccessibleName = "Back overlap item", TabIndex = 0, Bounds = new Rectangle(20, 290, 180, 55) };
                front = new Button { Text = "In front", AccessibleName = "Front overlap item", TabIndex = 1, Bounds = new Rectangle(45, 300, 110, 35) };
                form.Controls.Add(back);
                form.Controls.Add(front);
                front.BringToFront();
                form.Shown += (sender, args) => { Window = form.Handle; ready.Set(); };
                Application.Run(form);
            }
            catch (Exception error) { failure = error; ready.Set(); }
            finally { if (form != null) form.Dispose(); SetThreadDpiAwarenessContext(previousDpi); }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!ready.WaitOne(10000)) throw new TimeoutException("The native context fixture did not start.");
        if (failure != null) throw new InvalidOperationException("The native context fixture failed.", failure);
        // Shown can precede Windows applying the initial topmost style. Apply
        // it on the running UI thread before the driver starts a selector.
        Raise();
    }

    public void Dispose()
    {
        if (form != null && !form.IsDisposed) form.BeginInvoke(new Action(() => form.Close()));
        if (!thread.Join(5000)) throw new TimeoutException("The native context fixture did not stop.");
        ready.Dispose();
    }

    // Simulates an application whose accessibility provider cannot immediately
    // answer. The selection overlay must still paint and accept drag input.
    public void PauseProvider(int milliseconds)
    {
        using (var entered = new ManualResetEvent(false))
        {
            form.BeginInvoke(new Action(() => { entered.Set(); Thread.Sleep(milliseconds); }));
            if (!entered.WaitOne(5000)) throw new TimeoutException("Could not pause the source provider.");
        }
    }

    public void BringBackToFront()
    {
        form.Invoke(new Action(() => back.BringToFront()));
    }

    public void WaitForProvider()
    {
        // A posted barrier confirms the deliberately paused UI thread resumed.
        form.Invoke(new Action(() => { }));
    }

    public void ChangeTitle()
    {
        form.Invoke(new Action(() => form.Text += " changed"));
    }

    public void ExpandForAnnotations()
    {
        form.Invoke(new Action(() => form.Size = new Size(900, 600)));
    }

    public void ChangeVisibleText()
    {
        form.Invoke(new Action(() => {
            foreach (Control parent in form.Controls)
                foreach (Control child in parent.Controls)
                    if (child is Label) child.Text = "Source changed after capture";
            form.Refresh();
        }));
    }

    public void EnableHoverText()
    {
        form.Invoke(new Action(() => {
            foreach (Control parent in form.Controls)
                foreach (Control child in parent.Controls)
                    if (child is Label) {
                        var label = child;
                        var original = label.Text;
                        label.MouseEnter += (sender, args) => { label.Text = "Pointer hover changed this line"; };
                        label.MouseLeave += (sender, args) => { label.Text = original; };
                    }
        }));
    }

    public void Raise()
    {
        form.Invoke(new Action(() => {
            form.TopMost = false;
            form.TopMost = true;
            form.BringToFront();
            form.Activate();
        }));
    }

    public void ShowGrid()
    {
        form.Invoke(new Action(() => {
            grid = new DataGridView {
                Bounds = new Rectangle(20, 20, 450, 290), AllowUserToAddRows = false,
                RowHeadersVisible = false, ReadOnly = true, AccessibleName = "Database table",
            };
            grid.Columns.Add("alias", "Database Alias");
            grid.Columns.Add("host", "Host");
            grid.Columns[0].Width = 240;
            grid.Columns[1].Width = 180;
            for (var row = 1; row <= 4; row++) grid.Rows.Add("Database " + row, "localhost");
            grid.RowTemplate.Height = 40;
            foreach (DataGridViewRow row in grid.Rows) row.Height = 40;
            form.Controls.Add(grid);
            grid.BringToFront();
        }));
    }

    public void ShowControls()
    {
        form.Invoke(new Action(() => {
            var panel = new Panel { Bounds = new Rectangle(20, 20, 450, 290), BackColor = Color.White };
            var editor = new TextBox { Name = "comment-editor", AccessibleName = "Review comment", Text = "Read only draft", ReadOnly = true, Bounds = new Rectangle(20, 20, 260, 32) };
            panel.Controls.Add(editor);
            panel.Controls.Add(new Button { Name = "publish-button", Text = "Publish", Enabled = false, Bounds = new Rectangle(20, 65, 110, 30) });
            panel.Controls.Add(new CheckBox { Name = "notify-toggle", Text = "Notify", Checked = false, Bounds = new Rectangle(150, 65, 110, 30) });
            panel.Controls.Add(new TextBox { UseSystemPasswordChar = true, Text = "DO_NOT_CAPTURE_PASSWORD", Bounds = new Rectangle(20, 110, 260, 25) });
            form.Controls.Add(panel);
            panel.BringToFront();
            editor.Focus();
        }));
    }

    public int[] GridCellBounds(int row, int column)
    {
        int[] result = null;
        form.Invoke(new Action(() => {
            var cell = grid.GetCellDisplayRectangle(column, row, false);
            var point = grid.PointToScreen(cell.Location);
            result = new[] { point.X, point.Y, cell.Width, cell.Height };
        }));
        return result;
    }
}
