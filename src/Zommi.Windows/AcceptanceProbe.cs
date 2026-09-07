using System.Text.Json;

namespace Zommi.Windows;

internal static class AcceptanceProbe
{
    public static int BrowserBinding(string value)
    {
        ApplicationConfiguration.Initialize();
        if (!long.TryParse(value, out var handle)) return 2;
        var diagnostics = new List<string>();
        try
        {
            using var browser = BrowserObservationBridge.TryOpen((nint)handle, diagnostics.Add);
            if (browser is null)
            {
                Console.WriteLine(JsonSerializer.Serialize(new { matched = false, diagnostics }));
                return 3;
            }
            var viewport = browser.Viewport;
            var observation = browser.Read(new Point((int)(viewport.X + viewport.Width / 2), (int)(viewport.Y + viewport.Height / 2)));
            var snapshot = browser.Snapshot(observation);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                matched = true, source = snapshot.Source, viewport, elementCount = snapshot.Dom?.Elements.Count,
                selectionCount = snapshot.Selection.Count, diagnostics,
            }));
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.Message);
            return 1;
        }
    }

    public static int CaptureOnce()
    {
        try
        {
            using var capture = new ForegroundContextCapture();
            var result = capture.Capture(DateTimeOffset.UtcNow);
            Console.Out.Write(JsonSerializer.Serialize(result, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            }));
            return result.Snapshot is null ? 3 : 0;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int SelectedTextCapture()
    {
        const string marker = "SELECTED_TEXT_CAPTURE_7391";
        try
        {
            using var form = new Form
            {
                Text = "Zommi selected-text acceptance",
                ClientSize = new Size(700, 160),
                StartPosition = FormStartPosition.Manual,
                Location = new Point(40, 40),
                ShowInTaskbar = false,
            };
            using var editor = new RichTextBox
            {
                Dock = DockStyle.Fill,
                Text = $"prefix {marker} suffix",
            };
            form.Controls.Add(editor);
            form.Show();
            editor.Select(editor.Text.IndexOf(marker, StringComparison.Ordinal), marker.Length);
            editor.Focus();
            Application.DoEvents();

            using var capture = new ForegroundContextCapture();
            var selection = capture.TryReadSelectedText(form.Handle);
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                marker,
                selection,
            }));
            return selection.Any(value => value.Contains(marker, StringComparison.Ordinal)) ? 0 : 3;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }

    public static int WindowOwnership()
    {
        try
        {
            using var first = new Form
            {
                Text = "Zommi ownership first",
                ClientSize = new Size(320, 180),
                StartPosition = FormStartPosition.Manual,
                Location = new Point(60, 60),
                ShowInTaskbar = false,
            };
            using var second = new Form
            {
                Text = "Zommi ownership second",
                ClientSize = new Size(320, 180),
                StartPosition = FormStartPosition.Manual,
                Location = new Point(90, 90),
                ShowInTaskbar = false,
            };
            first.Show();
            second.Show();
            Application.DoEvents();

            using var capture = new ForegroundContextCapture();
            var ownWindowAccepted = capture.IsWithinWindowForAcceptance(
                second.Handle,
                second.Handle);
            var siblingWindowRejected = !capture.IsWithinWindowForAcceptance(
                first.Handle,
                second.Handle);
            var matchingBrowserDocumentAccepted =
                ForegroundContextCapture.BrowserDocumentUrlMatches(
                    "https://www.amazon.com/s?k=drum+stick+holder",
                    new Zommi.Capture.LocatorInfo
                    {
                        Kind = "URL",
                        Value = "https://amazon.com/s?k=drum+stick+holder",
                    });
            var siblingBrowserDocumentRejected =
                !ForegroundContextCapture.BrowserDocumentUrlMatches(
                    "https://github.com/timctho/zommi/actions",
                    new Zommi.Capture.LocatorInfo
                    {
                        Kind = "URL",
                        Value = "https://amazon.com/s?k=drum+stick+holder",
                    });
            Console.Out.Write(JsonSerializer.Serialize(new
            {
                ownWindowAccepted,
                siblingWindowRejected,
                matchingBrowserDocumentAccepted,
                siblingBrowserDocumentRejected,
                sameProcess = Environment.ProcessId,
            }));
            return ownWindowAccepted &&
                siblingWindowRejected &&
                matchingBrowserDocumentAccepted &&
                siblingBrowserDocumentRejected
                    ? 0
                    : 3;
        }
        catch (Exception exception)
        {
            Console.Error.Write(exception);
            return 1;
        }
    }
}
