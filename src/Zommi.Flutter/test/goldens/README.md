The root PNGs are the existing Linux baselines. `macos/` contains the macOS
baselines captured with Flutter 3.47.2 on Apple Silicon. Text and icon edges
rasterize differently on these hosts; both use exact pixel comparisons.
`platformGoldenPath` selects `macos/` on macOS; other hosts keep using the root
PNGs. The macOS CI job runs all four affected capture/UI test files.

From `src/Zommi.Flutter`, update on the matching OS with:

```sh
flutter test --update-goldens test/flutter_ux_parity_test.dart test/runtime_commands_test.dart test/zommi_app_test.dart
```

Inspect the images before accepting a baseline change, then rerun without
`--update-goldens` to verify exact comparisons. Keep the baselines current when
UI layout changes; do not replace another OS's PNGs to resolve host rendering
differences.
