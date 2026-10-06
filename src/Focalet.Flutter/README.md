# Focalet Flutter UI

The cross-platform Focalet desktop UI communicates with
the Rust `focalet-core-host` over versioned JSONL on stdio. The host must be built
before process integration tests run:

```sh
cargo build --workspace --bins
(cd src/Focalet.Flutter && dart format --output=none --set-exit-if-changed lib test && flutter analyze && flutter test)
```

Native packages place `focalet-core-host` beside the Flutter executable (inside
`Contents/MacOS` on macOS), and the client resolves that path before `PATH`.
During development, set `FOCALET_CORE_HOST` to an explicit build or put the host
on `PATH`.

Windows also packages `native/Focalet.CaptureHost.exe`, a capture-only UIA/region
helper. macOS and Linux use platform capture providers directly.

See [contributing](../../CONTRIBUTING.md) for prerequisites and the check runner.
