import 'dart:io';

// macOS and Linux rasterize glyph edges differently, even with the test font.
// Keep exact pixel comparisons against each host's reviewed baseline.
String platformGoldenPath(String filename) =>
    'goldens/${Platform.isMacOS ? 'macos/' : ''}$filename';
