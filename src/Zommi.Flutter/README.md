# Zommi Flutter UI

This is the cross-platform replacement for `Zommi.Electron`. It communicates
with the Rust `zommi-core-host` over versioned JSONL on stdio. The host must be
built before process integration tests run:

```sh
cargo build --workspace --bins
(cd src/Zommi.Flutter && dart format --output=none --set-exit-if-changed lib test && flutter analyze && flutter test)
```

During development, put `zommi-core-host` on `PATH` or set
`ZOMMI_CORE_HOST` to its absolute path before launching the Flutter app.

The UI is not the default packaged entrypoint until the migration's complete UX
parity gate passes. This is a rollout boundary, not a compatibility promise for
the legacy Electron implementation.
