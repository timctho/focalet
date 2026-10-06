import 'dart:io';

import 'package:flutter/services.dart';

enum CapturePermission { accessibility, screenRecording }

final class CapturePermissionStatus {
  const CapturePermissionStatus({
    required this.accessibility,
    required this.screenRecording,
  });

  final bool accessibility;
  final bool screenRecording;

  bool granted(CapturePermission permission) => switch (permission) {
    CapturePermission.accessibility => accessibility,
    CapturePermission.screenRecording => screenRecording,
  };
}

abstract interface class CapturePermissionBridge {
  bool get supportsCapturePermissions;
  Future<CapturePermissionStatus> capturePermissions();
  Future<CapturePermissionStatus> requestCapturePermission(
    CapturePermission permission,
  );
}

final class MacCapturePermissions implements CapturePermissionBridge {
  MacCapturePermissions({bool? supported})
    : supportsCapturePermissions = supported ?? Platform.isMacOS;

  static const channel = MethodChannel('focalet/capture_permissions');

  @override
  final bool supportsCapturePermissions;

  Future<CapturePermissionStatus> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final value = await channel.invokeMapMethod<String, Object?>(
      method,
      arguments,
    );
    return CapturePermissionStatus(
      accessibility: value?['accessibility'] == true,
      screenRecording: value?['screenRecording'] == true,
    );
  }

  @override
  Future<CapturePermissionStatus> capturePermissions() => _invoke('status');

  @override
  Future<CapturePermissionStatus> requestCapturePermission(
    CapturePermission permission,
  ) => _invoke('request', {'permission': permission.name});
}
