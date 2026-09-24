import 'dart:convert';
import 'dart:io';

abstract interface class GnomeDesktopSettings {
  bool get supportsGnomeIntegration;
  Future<Map<String, Object?>> gnomeIntegrationStatus({bool enable = false});
}

Future<Map<String, Object?>> runGnomeIntegration(
  String executable, {
  bool enable = false,
}) async {
  final process = await Process.start(executable, [
    enable ? 'enable-extension' : 'status',
  ]);
  final output = process.stdout.transform(utf8.decoder).join();
  final error = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    final text = await output;
    if (code != 0) throw StateError((await error).trim());
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  } finally {
    process.kill();
  }
}
