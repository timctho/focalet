# Working on Focalet

Focalet has a standalone Windows Capture tool and a Flutter Desktop app with a
Rust agent broker. They share capture libraries; existing paths retain Zommi names.
Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup and validation, and the
[component map](docs/desktop-reference.md) for source locations.

## Find the right component

- Desktop UI, sessions, drafts and attachments: `src/Zommi.Flutter/lib`.
- Runtime discovery, adapters and context handoff: `crates/zommi-core`.
- JSONL broker and protocol fixtures: `crates/zommi-core-host`.
- Capture tray, hotkeys and ordered paste: `src/Zommi.CaptureTool`.
- Shared Windows capture: `src/Zommi.Capture.Windows` and `src/Zommi.Capture.Core`.
- Desktop Windows JSONL adapter: `src/Zommi.Windows`.
- Ubuntu capture: `crates/zommi-linux-capture` and `src/Zommi.Gnome`.
- macOS capture: `src/Zommi.Flutter/macos/Runner`.
- Packaging and publication: `scripts/`; workflows: `.github/workflows/`.

## Validate a change

Run commands from the repository root with the toolchains in CONTRIBUTING.md.

```sh
python3 scripts/check.py --suite rust --suite flutter
python3 scripts/check.py --suite contracts
python3 scripts/check.py --suite capture --suite browser
```

Build the broker with the Rust suite before running process tests. Windows uses
`python scripts/check.py --suite windows`. Documentation uses
`python -m pip install -r requirements-docs.txt` then `python scripts/check_docs.py`.
The full check runner is `python3 scripts/check.py`; CI also verifies native packages.
Choose tests by the behavior affected, using the regression-test table in CONTRIBUTING.md.

## Preserve product boundaries

- Capture must build without Flutter or the Rust broker. Both Windows apps
  reference shared capture libraries, never each other's executable.

- Keep authentication, canonical history and tools with the selected agent.
- Match both runtime and session identity. Never replay an accepted or uncertain turn.
- Capture only after invocation; retain the selected pixels and report unavailable
  structure or unreliable alignment as image-only. See [capture rules](docs/browser-context.md).
- Use temporary state and local protocol fixtures in tests, never personal accounts,
  browser profiles, session databases or transcripts.
- Do not hand-edit generated packages, Flutter build output or screenshot baselines
  to hide a regression. Review intentional golden changes visually.
- Public examples and assets must follow the [demo review](scripts/demo/README.md).

## Repository workflow

Preserve unrelated working changes and use a dedicated branch for focused work.
Describe the resulting behavior and validation in the PR. Source, dependency,
workflow and build changes require native CI; documentation-only changes use the
documentation gate. Publishing requires successful checks for the same source SHA.
See [release policy](docs/public-releases.md) and [code signing policy](docs/code-signing.md).
