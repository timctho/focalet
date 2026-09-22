import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Uses the OS notification sound so volume and Do Not Disturb remain native.
final class ResponseNotifications {
  ResponseNotifications({
    required this.onOpen,
    required this.record,
    required this.isForeground,
  });

  final Future<bool> Function() isForeground;

  final void Function(String runtimeTargetId, String sessionId) onOpen;
  final Future<void> Function(String event, Map<String, Object?> details)
  record;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  Future<bool>? _initialization;
  int _nextId = DateTime.now().millisecondsSinceEpoch % 0x7fffffff;
  bool _closed = false;

  Uri? get _windowsIconUri => Platform.isWindows
      ? File(Platform.resolvedExecutable).parent.uri
            .resolve('data/flutter_assets/assets/branding/app-icon.png')
      : null;

  Future<bool> initialize() => _initialization ??= _initialize();

  Future<bool> _initialize() async {
    try {
      final initialized =
          await _plugin.initialize(
            settings: InitializationSettings(
              windows: WindowsInitializationSettings(
                appName: 'Zommi',
                appUserModelId: 'Zommi.Desktop',
                guid: 'f67d24b5-b13b-4b5e-aa39-88a40caec356',
                iconPath: _windowsIconUri?.toFilePath(windows: true),
              ),
              macOS: const DarwinInitializationSettings(
                requestBadgePermission: false,
                defaultPresentBadge: false,
              ),
              linux: LinuxInitializationSettings(
                defaultActionName: 'Open chat',
                defaultIcon: AssetsLinuxIcon('assets/branding/app-icon.png'),
                defaultSound: ThemeLinuxSound('message-new-instant'),
              ),
            ),
            onDidReceiveNotificationResponse: _open,
          ) ??
          false;
      if (!initialized) {
        await record('notification.unavailable', const {});
        return false;
      }
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final response = launch?.notificationResponse;
        if (response != null) _open(response);
      }
      return true;
    } on Object {
      await record('notification.unavailable', const {});
      return false;
    }
  }

  void _open(NotificationResponse response) {
    if (_closed || response.payload == null) return;
    try {
      final payload = jsonDecode(response.payload!);
      if (payload is! Map) return;
      final runtime = payload['runtimeTargetId'];
      final session = payload['sessionId'];
      if (runtime is String &&
          runtime.isNotEmpty &&
          session is String &&
          session.isNotEmpty) {
        onOpen(runtime, session);
      }
    } on FormatException {
      // Ignore stale or unrelated OS notifications.
    }
  }

  Future<void> show({
    required String runtimeTargetId,
    required String sessionId,
    required String turnId,
    required String runtimeName,
    required String sessionTitle,
  }) async {
    if (_closed || await isForeground()) return;
    if (!await initialize() || _closed || await isForeground()) return;
    final id = _nextId = (_nextId + 1) % 0x7fffffff;
    await _plugin.show(
      id: id,
      title: '$runtimeName response ready',
      body: sessionTitle.trim().isEmpty
          ? 'Your response is ready.'
          : sessionTitle,
      payload: jsonEncode({
        'runtimeTargetId': runtimeTargetId,
        'sessionId': sessionId,
      }),
      notificationDetails: NotificationDetails(
        windows: WindowsNotificationDetails(
          images: [
            if (_windowsIconUri case final icon?)
              WindowsImage(
                icon,
                altText: 'Zommi',
                placement: WindowsImagePlacement.appLogoOverride,
              ),
          ],
          audio: WindowsNotificationAudio.preset(
            sound: WindowsNotificationSound.defaultSound,
          ),
        ),
        macOS: const DarwinNotificationDetails(
          presentSound: true,
          presentAlert: true,
          presentBanner: true,
        ),
        linux: LinuxNotificationDetails(
          sound: ThemeLinuxSound('message-new-instant'),
        ),
      ),
    );
    await record('notification.requested', {
      'runtimeTargetId': runtimeTargetId,
      'sessionId': sessionId,
      'turnId': turnId,
      'sound': true,
    });
  }

  void close() => _closed = true;
}
