# Windows acceptance walkthrough

Use this walkthrough on a real Windows 10 or 11 desktop. A clean build and unit
tests are implementation evidence; this controlled run is the acceptance proof
for desktop capture and Codex CLI handoff.

Record the Windows version, `codex --version`, `Zommi.exe` SHA-256, browser
version, and the two Codex session UUIDs with the observations below.

## Setup

1. Extract `zommi-win-x64.zip` and verify `Zommi.exe` against
   `SHA256SUMS.txt`.
2. Start Zommi. Verify it opens a fresh Codex CLI in the default WSL
   distribution and automatically displays that exact session UUID and WSL home
   directory. Call it session A.
3. Separately start session B with
   `codex --dangerously-bypass-hook-trust` and keep it running. Do not use
   **New Codex in WSL**, because that action deliberately creates and binds a
   replacement session.

## Browser handoff

1. In a supported browser, open a harmless unique URL and point at a named
   control. Confirm Zommi displays the URL and accessible target without a
   screenshot.
2. Return to session A and ask, "What page and control am I pointing at?"
3. Verify Zommi's **Last handoff** uses session A's prefix and that session A's
   response refers to the unique URL/control.
4. Ask a prompt in session B. Verify Zommi records no handoff to B and B does
   not receive the snapshot.

## Explorer handoff

1. Open File Explorer to a unique temporary folder and select one harmless
   file. Confirm Zommi displays the exact folder path and selected item.
2. Ask session A, "Which folder and file do I mean?" Verify both values.

## Control and failure checks

1. Choose **Pause**, change browser/Explorer context, and prompt session A.
   Verify no new handoff occurs.
2. Resume, obtain a snapshot, choose **Freeze**, wait more than 30 seconds but
   less than 15 minutes, and prompt session A. Verify the frozen snapshot is
   handed off.
3. Choose **Detach** and prompt both sessions. Verify neither receives context.
4. Choose **New Codex in WSL**, verify the newly launched session becomes the
   exact binding, obtain a snapshot, then terminate Zommi. Verify Codex
   continues normally and receives no Zommi context.
5. Inspect `%LOCALAPPDATA%\Zommi`. Verify it contains no snapshot, prompt,
   transcript, screenshot, URL, path, selection, or pointer-target history.

Acceptance requires all checks above. Record any browser accessibility failure,
elevation mismatch, stale context, wrong-session delivery, or Codex hook error
as a failed check rather than inferring success from the overlay alone.

For repeatable implementation checks, build the package and run:

```powershell
.\scripts\test-windows-runtime.ps1 `
  -ExecutablePath .\artifacts\zommi-win-x64\Zommi.exe
```

This automates native GUI startup, WSL hook discovery, exact-session routing,
shared-memory cleanup, Explorer path/selection capture, and isolated Edge
URL/pointer capture. It complements rather than replaces the visible control
walkthrough above.
