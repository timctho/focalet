The root PNGs are the existing Linux baselines. `macos/` contains the shared
macOS baselines captured with Flutter 3.47.2. Text and icon edges can rasterize
differently across hosts and CPU architectures; comparisons remain pixel-exact.
`platformGoldenPath` prefers a reviewed `macos/arm64/` or `macos/x64/` override
when present, then uses the shared `macos/` image. Other hosts use the root PNGs.
Both macOS CI jobs run the full Flutter suite.

The Intel runtime setup panel has one icon-edge channel differing by one value
from Apple Silicon. Its `macos/x64/` override preserves exact comparisons on both
architectures. The command menu baseline is identical on both Mac architectures.

From `src/Focalet.Flutter`, update on the matching OS with:

```sh
flutter test --update-goldens test/flutter_ux_parity_test.dart test/runtime_commands_test.dart test/focalet_app_test.dart
```

Inspect the images before accepting a baseline change, then rerun without
`--update-goldens` to verify exact comparisons. Keep the baselines current when
UI layout changes; do not replace another OS's PNGs to resolve host rendering
differences.
