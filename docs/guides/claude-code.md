# Share screen context with Claude Code

Focalet lets you send a selected screenshot, annotations, and available source
context to Claude Code from a desktop app on Windows, macOS and Ubuntu GNOME Wayland.

## Connect and capture

1. Install and sign in to Claude Code using its own setup flow.
2. In Focalet, choose **Configure runtime → Add runtime** if Claude Code is not
   already listed, then connect it and open a chat.
3. Press **Alt+A** (**⌥ A** on Mac). Select the screen region you want to discuss.
4. On Windows and Mac, use the drawing toolbar if needed, then **Attach**.
5. Review the attachment and ask a concrete question, such as “Explain this error
   and find the relevant code in my workspace.”

Focalet connects through Claude Code's stream-json protocol. Claude Code controls
authentication, tools and canonical conversation history. Full access is on by
default; disable it in App settings to use the runtime's approval policy.

## What the agent receives

The attachment includes the selected image and any reliably aligned text, links
or element structure. Browser DOM requires a compatible authorized browser
connection. Image-only fallback still provides the selected pixels and explains
why structured context is unavailable.

Results depend on the model and tools available to your Claude Code installation.
Focalet does not add database, browsing or workspace access that the runtime lacks.
Review the [privacy policy](../privacy.md) before sharing sensitive content.

See [runtime setup and known limits](../install.md#2-choose-the-agent-you-already-have)
and [Chrome and Edge setup](chrome-edge.md).
