# Zommi Flutter UI

This is the authoritative cross-platform Zommi desktop UI. It communicates with
the Rust `zommi-core-host` over versioned JSONL on stdio. The host must be built
before process integration tests run:

```sh
cargo build --workspace --bins
(cd src/Zommi.Flutter && dart format --output=none --set-exit-if-changed lib test && flutter analyze && flutter test)
```

Native packages place `zommi-core-host` beside the Flutter executable (inside
`Contents/MacOS` on macOS), and the client resolves that path before `PATH`.
During development, set `ZOMMI_CORE_HOST` to an explicit build or put the host
on `PATH`.

Windows also packages `native/Zommi.Capture.exe`, a capture-only UIA/region
helper. macOS and Linux use platform capture providers directly. The old
Electron and hook-relay implementations are not release fallbacks.
