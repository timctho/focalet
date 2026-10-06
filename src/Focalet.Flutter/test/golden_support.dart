import 'dart:ffi';
import 'dart:io';

// macOS and Linux rasterize glyph edges differently, even with the test font.
// Keep exact pixel comparisons against each host's reviewed baseline.
String platformGoldenPath(String filename) {
  if (!Platform.isMacOS) return 'goldens/$filename';
  final architecture = Abi.current() == Abi.macosX64 ? 'x64' : 'arm64';
  final specific = 'goldens/macos/$architecture/$filename';
  return File('test/$specific').existsSync()
      ? specific
      : 'goldens/macos/$filename';
}
