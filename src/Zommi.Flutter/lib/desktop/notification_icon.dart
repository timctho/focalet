import 'dart:io';

import 'package:crypto/crypto.dart';

/// Windows caches notification artwork by URI across application upgrades.
/// Keep each version at an immutable path so new notifications use new pixels.
Future<Uri> prepareNotificationIcon(File source, Directory cache) async {
  final bytes = await source.readAsBytes();
  final digest = sha256.convert(bytes).toString();
  await cache.create(recursive: true);
  final icon = File('${cache.path}${Platform.pathSeparator}$digest.png');
  if (!await icon.exists()) {
    final temporary = File('${icon.path}.$pid.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(icon.path);
  }
  return icon.uri;
}
