# Contributing to Zommi

Zommi connects a desktop selection to an existing agent. Keep credentials,
canonical history, tools and permissions with that agent. See the
[desktop reference](docs/desktop-reference.md) for the source layout.

## Set up

Clone the repository and install:

- Rust **1.93.0** (`rustup` reads `rust-toolchain.toml`).
- Flutter **3.47.2**, including its Dart SDK, on `PATH`.
- Python **3.10+**, Node.js **22+**, .NET SDK **8**, and FFmpeg (including
  `ffprobe`, for reviewed demo metadata).
- Chromium, Chrome or Edge for browser capture tests. Set `ZOMMI_TEST_CHROMIUM`
  to the executable if it is not on `PATH`.
- Ubuntu 24.04 LTS x64 (the supported Linux target): SQLite, GTK and Chromium's runtime dependencies:
  `sudo apt-get install libsqlite3-dev libgtk-3-0t64 libasound2t64 ffmpeg`.
- Windows: Visual Studio 2022 or later C++ tools for Rust and native builds;
  ATL is also needed for Flutter packaging. Use PowerShell 7 for native checks.

Install the Python test dependencies in a virtual environment (required for
Ubuntu's OS-managed Python):

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r tests/requirements.txt
```

In PowerShell, activate it with `.\.venv\Scripts\Activate.ps1` instead.

You do **not** need an agent account, model credentials, or a running gateway to
run contract tests. Process tests launch the Rust broker with local protocol
fixtures. Do not replace those fixtures with your personal agent installation.
The check runner enables `ZOMMI_RUNTIME_DISCOVERY_MODE=configured-only` and
temporary binding/discovery/override stores for its child processes. This
disables automatic native/WSL discovery only in that test invocation. Individual
fixtures supply explicit commands; ordinary app launches still discover agents.

## Run checks

From the repository root on Ubuntu:

```sh
python3 scripts/check.py
```

This checks Rust formatting/lints/tests, builds the broker, restores the locked
Flutter dependencies, checks Dart formatting/analysis, runs every Flutter test,
then runs Python, relay, managed capture and real headless-browser tests.
It stops on the first failure. SQLite's linker alias is prepared in a temporary
directory if the system only provides its versioned library.

Run just the affected suites during development:

```sh
python3 scripts/check.py --suite rust --suite flutter
python3 scripts/check.py --suite contracts
python3 scripts/check.py --suite capture --suite browser
```

Build the broker before Python or Dart process tests (`--suite rust`). Do not
skip a failing process test because no real agent is installed.

On Windows:

```powershell
python scripts/check.py --suite windows
```

This checks the core, all Dart process fixtures, Windows paths/SQLite/desktop
contracts, the capture helper and deployment retry logic. Linux runs the full
widget suite and its pixel baselines. The macOS PR job runs the full Flutter
suite with its own baselines and native selection geometry tests. All three PR
jobs compile and verify a native desktop package. The manual **Build and publish
release** workflow builds installers on GitHub-hosted runners and optionally
publishes them. **Native acceptance** retains additional interactive desktop
checks. See [release preparation](docs/public-releases.md).

To build a native package locally or run interactive acceptance:

```sh
bash scripts/package-unix.sh linux
# macOS: bash scripts/package-unix.sh macos
```

```powershell
./scripts/package-windows.ps1 -Runtime win-x64
```

Native Linux builds additionally need Clang, Ninja, pkg-config, GTK development
headers, X11 and Ayatana AppIndicator. See [Ubuntu testing](docs/ubuntu-testing.md),
[Windows acceptance](docs/windows-acceptance.md),
[Mac testing](docs/macos-testing.md) and [release preparation](docs/public-releases.md).

## Choose the right regression test

| Change | Tests to extend |
| --- | --- |
| Runtime protocol, identity, history or recovery | Rust adapter tests; Dart `*_process_test.dart` against `crates/zommi-core-host/tests` fixtures |
| Session switches, late replies, drafts or edit/resend | `session_*`, `background_runtime_*`, `message_rewind_*`, `chat_switch_recovery_*` |
| Capture fidelity and privacy | `tests/Zommi.Capture.Tests`, `tests/Zommi.Browser.Tests`, Rust `context_handoff` tests and `core_bridge_process_test.dart` |
| UI layout, streaming, hotkeys or notification behavior | Flutter widget/desktop tests; packaged native acceptance when the OS is involved |
| Packaging, installers or publishing | Python `test_release_package.py` and `test_public_release.py` |
| Contributor workflows | `test_contributor_checks.py` |

Test observable behavior and failure cases. A fake should reproduce a protocol
boundary, including delayed, malformed, duplicate or out-of-order responses.
Verify the exact runtime **and** session when IDs collide. An accepted turn
must not be automatically sent again after an uncertain transport failure.

Use temporary data and loopback-only fixtures. Close child processes before
deleting their temporary directories. Use bounded waits for events; avoid
`pumpAndSettle` while an animation or stream intentionally remains active.
Screenshot baselines are OS-specific: [golden guidance](src/Zommi.Flutter/test/goldens/README.md).
Inspect changed images before committing them; updating goldens is not a fix for
an unexplained regression.

## Pull requests

The **PR checks** workflow runs for every PR, including forks, on disposable
GitHub-hosted Linux, Windows and macOS runners. It uses read-only repository access,
no deployment secrets and pinned action revisions. It does not run fork code on
maintainers' self-hosted machines. **PR checks passed** succeeds only when all three
platform jobs succeed; a skipped or cancelled dependency fails the gate.

Repository maintainers should require **PR checks passed** in the `main` branch
rules and require review for workflow changes. This file does not enable GitHub
branch protection by itself.
The **Native acceptance** workflow is manual and reserved for reviewed source.
Do not dispatch unreviewed fork code onto a persistent runner.

Keep changes focused and describe the user-visible result, validation and any
native checks still needed. Include a regression for a behavior change. Never
upload personal transcripts, settings, session catalogs, tokens, or raw desktop
logs. Public demos must use synthetic content and pass the
[recording review](scripts/demo/README.md).

## License

Contributions are provided under the repository's [Apache 2.0 license](LICENSE).
Preserve third-party copyright and license notices when updating dependencies
or assets; see [third-party notices](THIRD_PARTY_NOTICES.md).
