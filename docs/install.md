# Install Zommi

Download the package for your computer from the public Zommi Releases page.
Zommi needs an agent runtime such as Codex or Pi installed separately. Sign in
through that runtime, then select it in Zommi's first-launch setup.

## Windows

Run **Zommi-Setup-x64.exe** on Windows 10 or 11 (64-bit). It installs for your
account and adds Zommi to the Start menu; administrator access is not required.
The installer includes the required runtime libraries. You do not need Flutter,
Rust, Visual Studio, or .NET installed.

Preview builds are unsigned. Windows may show SmartScreen; verify the download
and publisher before choosing **More info > Run anyway**.
Use **Settings > Apps > Installed apps > Zommi > Uninstall** to remove the app.
Close Zommi before installing an update or uninstalling it.
Uninstalling preserves your settings and agent-owned accounts/history.

## Mac

On macOS 12 or later, open the DMG for **Apple Silicon (arm64)** or **Intel
(x64)** and drag **Zommi.app** into **Applications**. Launch it from Applications
before granting Accessibility and Screen Recording permissions during setup.

Preview builds are ad-hoc signed and are not notarized. If macOS blocks this
trusted download, use **System Settings > Privacy & Security > Open Anyway**.
Permission changes may require restarting Zommi. Remove Zommi.app from
Applications to uninstall it; agent accounts and history remain with the agent.

## Verify a download

Each release includes `SHA256SUMS.txt` and `zommi-release.json`, recording the
source revision and installer hashes. On Mac use `shasum -a 256 <file>`; on
Windows PowerShell use `Get-FileHash <file> -Algorithm SHA256` and compare the
result with `SHA256SUMS.txt`.
