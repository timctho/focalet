part of 'desktop_bridge.dart';

Future<void> presentPanelWithoutResizing({
  required Future<void> Function() show,
  required Future<void> Function() focus,
  required Future<void> Function() keepOnTop,
}) async {
  await show();
  await focus();
  await keepOnTop();
}

Future<({Rect bounds, Rect workArea, double scale, bool maximized})>
readNativeSurfaceGeometry(MethodChannel channel) async {
  final values = await channel.invokeMapMethod<String, Object?>(
    'getSurfaceGeometry',
  );
  if (values == null) {
    throw StateError('Native window geometry is unavailable.');
  }
  Rect rectangle(String name) {
    final parts = (values[name] as List<Object?>).cast<num>();
    return Rect.fromLTWH(
      parts[0].toDouble(),
      parts[1].toDouble(),
      parts[2].toDouble(),
      parts[3].toDouble(),
    );
  }

  return (
    bounds: rectangle('bounds'),
    workArea: rectangle('workArea'),
    scale: (values['scale'] as num).toDouble(),
    maximized: values['maximized'] == true,
  );
}

Future<bool?> presentNativePanel({
  bool focus = true,
  bool? platformIsWindows,
}) async {
  if (!(platformIsWindows ?? Platform.isWindows)) return null;
  try {
    return await _windowAnimationChannel.invokeMethod<bool>('presentPanel', {
      'focus': focus,
    });
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Offset initialSurfaceAnchor(Rect workArea, Size size) => Offset(
  workArea.center.dx,
  workArea.center.dy + size.height.clamp(0, workArea.height) / 2,
);

Rect anchoredSurfaceBounds({
  required Offset anchor,
  required Rect workArea,
  required Size size,
}) {
  final maxLeft = math.max(workArea.left, workArea.right - size.width);
  final maxTop = math.max(workArea.top, workArea.bottom - size.height);
  final left = (anchor.dx - size.width / 2).clamp(workArea.left, maxLeft);
  final top = (anchor.dy - size.height).clamp(workArea.top, maxTop);
  return Rect.fromLTWH(left, top, size.width, size.height);
}

Future<void> setNativeSurfaceBounds({
  required Rect bounds,
  required double scaleFactor,
  bool maximized = false,
}) async {
  await _windowAnimationChannel.invokeMethod<bool>('setSurfaceBounds', {
    'toX': bounds.left,
    'toY': bounds.top,
    'toWidth': bounds.width,
    'toHeight': bounds.height,
    'scaleFactor': scaleFactor,
    'maximized': maximized,
  });
}

Future<bool?> isPointerWithinNativeSurface({bool? platformIsWindows}) async {
  if (!(platformIsWindows ?? Platform.isWindows)) return null;
  try {
    return await _windowAnimationChannel.invokeMethod<bool>(
      'isPointerWithinWindow',
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<void> configureNativeSurfaceWindow() async {
  if (!Platform.isWindows) return;
  try {
    await _windowAnimationChannel.invokeMethod<void>('configureSurfaceWindow');
  } on MissingPluginException {
    // Non-Windows and test runners do not install the custom Win32 host.
  } on PlatformException {
    // The app still remains usable; packaged acceptance verifies the exact
    // frameless endpoint so release builds cannot silently keep this fallback.
  }
}

Future<void> animateSurfaceBounds({
  required Rect from,
  required Rect to,
  required Future<void> Function(Rect value) setBounds,
  required bool Function() cancelled,
  Duration duration = surfaceTransitionDuration,
  int frames = surfaceTransitionFrameCount,
}) async {
  if (from == to || duration == Duration.zero || frames <= 1) {
    if (!cancelled()) await setBounds(to);
    return;
  }
  final stopwatch = Stopwatch()..start();
  for (var frame = 1; frame <= frames; frame++) {
    if (cancelled()) return;
    final deadline = duration * (frame / frames);
    final remaining = deadline - stopwatch.elapsed;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    if (cancelled()) return;
    final linear = frame / frames;
    final eased = symmetricSurfaceEase(linear);
    await setBounds(Rect.lerp(from, to, eased)!);
  }
}

bool supportsNativeWindowShadow(String operatingSystem) =>
    operatingSystem == 'windows' || operatingSystem == 'macos';

bool supportsExplicitTrayContextMenu(String operatingSystem) =>
    operatingSystem == 'windows' || operatingSystem == 'linux';

Future<void> showExplicitTrayContextMenu({
  required String operatingSystem,
  required Future<void> Function() show,
}) async {
  if (supportsExplicitTrayContextMenu(operatingSystem)) await show();
}
