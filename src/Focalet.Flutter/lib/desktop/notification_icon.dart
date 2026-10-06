import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:win32_registry/win32_registry.dart';

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

String notificationApplicationId(Uri icon) {
  final digest = icon.pathSegments.last.split('.').first;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const FormatException('Notification icon has no content digest.');
  }
  return 'Focalet.Desktop.${digest.substring(0, 16)}';
}

/// Windows also caches the small notification header by application identity.
/// Carry forward notification preferences when branding changes, leaving old
/// notification history and activation registrations available.
Future<String> prepareNotificationIdentity(Uri icon, Directory cache) async {
  final current = notificationApplicationId(icon);
  final marker = File('${cache.path}${Platform.pathSeparator}application-id');
  var previous = 'Focalet.Desktop';
  if (await marker.exists()) {
    final saved = (await marker.readAsString()).trim();
    if (RegExp(r'^Focalet\.Desktop(?:\.[0-9a-f]{16})?$').hasMatch(saved)) {
      previous = saved;
    }
  }
  if (previous != current) {
    final user = Registry.openPath(
      RegistryHive.currentUser,
      desiredAccessRights: AccessRights.allAccess,
    );
    try {
      final settings = user.createKey(
        r'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings',
      );
      try {
        copyNotificationPreferences(settings, previous, current);
      } finally {
        settings.close();
      }
    } finally {
      user.close();
    }
    await marker.writeAsString(current, flush: true);
  }
  return current;
}

void copyNotificationPreferences(
  RegistryKey settings,
  String previous,
  String current,
) {
  final keys = settings.subkeyNames.map((name) => name.toLowerCase()).toSet();
  if (keys.contains(current.toLowerCase()) ||
      !keys.contains(previous.toLowerCase())) {
    return;
  }
  final source = settings.createKey(previous);
  try {
    final target = settings.createKey(current);
    try {
      for (final value in source.values) {
        if (value.name != 'LastNotificationAddedTime') {
          target.createValue(value);
        }
      }
    } finally {
      target.close();
    }
  } finally {
    source.close();
  }
}
