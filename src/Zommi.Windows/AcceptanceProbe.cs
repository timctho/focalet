using System.Text.Json;

namespace Zommi.Windows;

internal static class AcceptanceProbe
{
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
}
