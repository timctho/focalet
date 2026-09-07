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
                form.Controls.Add(panel);
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
    }

    public void Dispose()
    {
        if (form != null && !form.IsDisposed) form.BeginInvoke(new Action(() => form.Close()));
        if (!thread.Join(5000)) throw new TimeoutException("The native context fixture did not stop.");
        ready.Dispose();
    }
}
