part of 'desktop_bridge.dart';

/// A shared editor with native pixels/accessibility and the Windows DOM core.
final class UnixCaptureProvider
    implements CaptureProvider, BrowserCaptureSettings {
  UnixCaptureProvider({
    UnixRegionBackend? backend,
    NativeCaptureClient? browser,
    Future<List<SelectedRegion>> Function(List<CapturedDisplay>)? editor,
  }) : _backend = backend ?? NativeUnixRegionBackend(),
       _editor = editor ?? showRegionSelectionEditor,
       _browser =
           browser ??
           ProcessNativeCaptureClient(
             Platform.environment['ZOMMI_BROWSER_CAPTURE_HOST'] ??
                 '${File(Platform.resolvedExecutable).parent.path}/browser-capture/zommi-browser-capture',
           );
  final UnixRegionBackend _backend;
  final Future<List<SelectedRegion>> Function(List<CapturedDisplay>) _editor;
  final NativeCaptureClient _browser;
  bool _browserPageDetails = true;
  bool _closed = false;
  @override
  bool get supportsBrowserPageDetails => true;
  @override
  void setBrowserPageDetails(bool enabled) {
    _browserPageDetails = enabled;
    if (!enabled) unawaited(_browser.close());
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async => Platform.isMacOS
      ? PortableCaptureProvider().capture(point: point, onReady: onReady)
      : portableCaptureResult(
          application: 'Ubuntu desktop',
          windowTitle: '',
          url: '',
          limitation: 'Use Select to capture a region with its app context.',
        );

  @override
  Future<List<CaptureResult>> selectContext() async {
    if (_closed) return const [];
    final displays = <CapturedDisplay>[];
    try {
      displays.addAll(await _backend.captureDisplays());
      if (displays.isEmpty) return const [];
      final selected = await _editor(displays);
      final results = <CaptureResult>[];
      for (final region in selected) {
        if (_closed) break;
        results.add(
          CaptureResult(
            image: await enrichSelectedRegion(
              region,
              _backend.observe,
              browser: _browserPageDetails ? _browser : null,
            ),
          ),
        );
      }
      return results;
    } finally {
      try {
        if (_backend case final UnixCaptureSession session) {
          await session.release();
        }
      } finally {
        for (final display in displays) {
          display.image.dispose();
        }
      }
    }
  }

  @override
  Future<ImageSelection?> selectImage() async =>
      (await selectContext()).firstOrNull?.image;
  @override
  Future<void> close() async {
    _closed = true;
    activeRegionSelection.value?.finish(cancel: true);
    await _browser.close();
    await _backend.close();
  }
}

Future<List<SelectedRegion>> showRegionSelectionEditor(
  List<CapturedDisplay> displays,
) async {
  if (activeRegionSelection.value != null) {
    throw StateError('A content selection is already open.');
  }
  final previousBounds = await windowManager.getBounds();
  final wasMaximized = await windowManager.isMaximized();
  final wasOnTop = await windowManager.isAlwaysOnTop();
  final session = RegionSelectionSession(displays);
  activeRegionSelection.value = session;
  try {
    if (Platform.isLinux) {
      try {
        await LinuxDocumentRenderer.suspend(true);
      } on MissingPluginException {
        // Older development runners do not embed a native document surface.
      }
    }
    if (!wasMaximized) await windowManager.maximize();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.show();
    await windowManager.focus();
    if (Platform.isLinux) await presentGnomeWindow();
    return await session.result.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        session.finish(cancel: true);
        throw TimeoutException(
          'Content selection timed out. Open Select to try again.',
        );
      },
    );
  } finally {
    try {
      await hideDesktopForCapture();
    } finally {
      // A window-manager failure must not leave a stale selection session or
      // prevent the remaining state from being restored.
      for (final restore in <Future<void> Function()>[
        if (!wasMaximized) windowManager.unmaximize,
        if (!wasMaximized) () => windowManager.setBounds(previousBounds),
        () => windowManager.setAlwaysOnTop(wasOnTop),
        if (Platform.isLinux) () => LinuxDocumentRenderer.suspend(false),
      ]) {
        try {
          await restore();
        } on Object catch (error) {
          debugPrint('Could not restore a capture window setting: $error');
        }
      }
      activeRegionSelection.value = null;
      session.dispose();
    }
    // The native readers must see the source application, never the editor.
    await Future<void>.delayed(const Duration(milliseconds: 180));
  }
}

abstract interface class UnixRegionBackend {
  Future<List<CapturedDisplay>> captureDisplays();
  Future<Map<String, Object?>> observe(Rect bounds);
  Future<void> close();
}

abstract interface class UnixCaptureSession {
  Future<void> release();
}

final class NativeUnixRegionBackend
    implements UnixRegionBackend, UnixCaptureSession {
  NativeUnixRegionBackend({NativeCaptureClient? linuxClient})
    : _linuxClient =
          linuxClient ??
          ProcessNativeCaptureClient(
            resolveLinuxCaptureExecutable(),
            captureTimeout: const Duration(seconds: 20),
          );
  final NativeCaptureClient _linuxClient;

  @override
  Future<List<CapturedDisplay>> captureDisplays() async {
    Map<String, Object?> response;
    if (Platform.isMacOS) {
      if (!(await MacCapturePermissions().capturePermissions())
          .screenRecording) {
        throw StateError(
          'Screen Recording is unavailable. Open capture permissions in Settings to check access.',
        );
      }
      response =
          await MacCapturePermissions.channel.invokeMapMethod<String, Object?>(
            'captureDisplays',
          ) ??
          const {};
    } else {
      response = await _linuxClient.request('selectContent');
    }
    final displays = <CapturedDisplay>[];
    try {
      for (final item in (response['frames'] as List? ?? const []).take(8)) {
        final frame = _nullableMap(item)!;
        final url = frame['dataUrl'] as String;
        final size = _pngSize(url);
        if (size == null || size['width']! * size['height']! > 64000000) {
          throw StateError('The captured display is too large.');
        }
        final bytes = base64Decode(url.substring(url.indexOf(',') + 1));
        final codec = await ui.instantiateImageCodec(bytes);
        try {
          final image = (await codec.getNextFrame()).image;
          displays.add(
            CapturedDisplay(
              image: image,
              bounds: regionRect(frame['bounds']),
              windows: [
                for (final window in frame['windows'] as List? ?? const [])
                  ?_nullableMap(window),
              ],
              observedAt: DateTime.now().toUtc(),
              label:
                  frame['label']?.toString() ??
                  'Display ${displays.length + 1}',
              screenCoordinatesKnown: frame['screenCoordinatesKnown'] != false,
            ),
          );
        } finally {
          codec.dispose();
        }
      }
      return displays;
    } catch (_) {
      for (final display in displays) {
        display.image.dispose();
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> observe(Rect bounds) async => Platform.isMacOS
      ? await MacCapturePermissions.channel.invokeMapMethod<String, Object?>(
              'observeRegion',
              {'bounds': regionRectJson(bounds)},
            ) ??
            const {}
      : _linuxClient.request(
          'observe',
          parameters: {'bounds': regionRectJson(bounds)},
        );
  @override
  Future<void> release() async {
    if (Platform.isMacOS) return;
    try {
      await _linuxClient.request('release');
    } on Object {
      await _linuxClient.close();
    }
  }

  @override
  Future<void> close() => _linuxClient.close();
}

Future<bool> sameCapturedPixels(
  String original,
  String current, {
  bool allowRoundingNoise = false,
}) async {
  Future<ui.Image> decode(String url) async {
    final codec = await ui.instantiateImageCodec(
      base64Decode(url.substring(url.indexOf(',') + 1)),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  final a = await decode(original);
  try {
    final b = await decode(current);
    try {
      if (a.width != b.width || a.height != b.height) return false;
      final bytesA = await a.toByteData();
      final bytesB = await b.toByteData();
      if (bytesA == null || bytesB == null) return false;
      final pixelsA = bytesA.buffer.asUint8List(
        bytesA.offsetInBytes,
        bytesA.lengthInBytes,
      );
      final pixelsB = bytesB.buffer.asUint8List(
        bytesB.offsetInBytes,
        bytesB.lengthInBytes,
      );
      if (listEquals(pixelsA, pixelsB)) return true;
      if (!allowRoundingNoise || pixelsA.length != pixelsB.length) return false;
      // GNOME can redraw an unchanged checkbox with up to two RGB levels of
      // rounding, including after the capture editor returns focus.
      // Accept only sparse rounding noise: never alpha, geometry, larger colour
      // changes or a changed area exceeding 0.25% (capped at 1024 pixels).
      final budget = math.min(1024, (a.width * a.height * .0025).floor());
      var changed = 0;
      for (var i = 0; i < pixelsA.length; i += 4) {
        if (pixelsA[i + 3] != pixelsB[i + 3]) return false;
        var different = false;
        for (var channel = 0; channel < 3; channel++) {
          final delta = (pixelsA[i + channel] - pixelsB[i + channel]).abs();
          if (delta > 2) return false;
          different |= delta != 0;
        }
        if (different && ++changed > budget) return false;
      }
      return true;
    } finally {
      b.dispose();
    }
  } finally {
    a.dispose();
  }
}

bool sameNativeRegionSource(Map<String, Object?>? a, Map<String, Object?>? b) =>
    a != null &&
    b != null &&
    a['processId'] != null &&
    a['processStartToken'] != null &&
    [
      'nativeWindowId',
      'processId',
      'processStartToken',
      'windowTitle',
    ].every((key) => a[key] == b[key]) &&
    regionRect(a['bounds']) == regionRect(b['bounds']);

bool _sameRegionContext(Object? a, Object? b) {
  // Platform-channel dictionaries have no stable insertion order. Lists do:
  // changing the element order or any nested value invalidates the snapshot.
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (key) => b.containsKey(key) && _sameRegionContext(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length)
            .every((index) => _sameRegionContext(a[index], b[index]));
  }
  return a == b;
}

Future<ImageSelection> enrichSelectedRegion(
  SelectedRegion selected,
  Future<Map<String, Object?>> Function(Rect bounds) observe, {
  NativeCaptureClient? browser,
}) async {
  final display = selected.display;
  final bounds = display.screenRect(selected.pixels);
  final original =
      'data:image/png;base64,${base64Encode(await selected.render(annotated: false))}';
  final rendered = selected.strokes.isEmpty
      ? original
      : 'data:image/png;base64,${base64Encode(await selected.render())}';
  final source = display.sourceAt(selected.pixels);
  String? reason;
  Map<String, Object?>? content;
  Map<String, Object?>? dom;
  Map<String, Object?>? locator;
  var browserRequested = false;
  Map<String, Object?> retainedSource =
      source ??
      {
        'platform': Platform.operatingSystem,
        'hostName': Platform.localHostname,
      };
  try {
    if (!display.screenCoordinatesKnown) {
      throw StateError(
        'The screenshot portal did not provide a screen origin. This capture contains an image only.',
      );
    }
    if (source == null) {
      throw StateError(
        'The selection does not have one unobscured source window.',
      );
    }
    final before = await observe(bounds);
    Future<bool> valid(Map<String, Object?> observation) async =>
        observation['stable'] == true &&
        sameNativeRegionSource(source, _nullableMap(observation['source'])) &&
        observation['dataUrl'] is String &&
        await sameCapturedPixels(
          original,
          observation['dataUrl'] as String,
          allowRoundingNoise: Platform.isLinux,
        );
    if (!await valid(before)) {
      throw StateError(
        'The source or selected pixels changed. The original image and drawings were kept.',
      );
    }
    var browserStarted = false;
    var browserFailed = false;
    if (browser != null && before['browserViewport'] is Map) {
      try {
        browserRequested = true;
        final response = await browser.request(
          'observe',
          parameters: {
            'source': before['source'],
            'windows': before['windows'],
            'viewport': before['browserViewport'],
            'bounds': regionRectJson(bounds),
            'imageWidth': selected.pixels.width.round(),
            'imageHeight': selected.pixels.height.round(),
          },
        );
        browserStarted = response['available'] == true;
        reason = response['limitation']?.toString();
      } on Object {
        browserFailed = true;
        reason = 'Browser DOM is unavailable. Native accessibility was tried instead.';
      }
    }
    final after = await observe(bounds);
    if (!await valid(after) ||
        regionRect(before['browserViewport']) !=
            regionRect(after['browserViewport']) ||
        !_sameRegionContext(before['regionContext'], after['regionContext'])) {
      throw StateError(
        'The selected content changed during capture. The original image and drawings were kept.',
      );
    }
    if (browserStarted) {
      // A failed confirmation is a changed observation, not a reason to attach
      // different metadata. The original frozen image always wins.
      final response = await browser!.request('confirm');
      if (response['available'] != true) {
        throw StateError(
          response['limitation']?.toString() ?? 'Browser content changed during capture. The original image was kept.',
        );
      }
      if (response['available'] == true) {
        content = _nullableMap(response['regionContext']);
        dom = _nullableMap(response['dom']);
        locator = _nullableMap(response['locator']);
        reason = response['limitation']?.toString();
        retainedSource = {
          ...retainedSource,
          ...?_nullableMap(response['source']),
          'provider': 'browser-dom',
        };
      }
    }
    content ??= _nullableMap(after['regionContext']);
    if (!browserFailed && dom == null) {
      reason ??= after['limitation']?.toString();
    }
  } on Object catch (error) {
    content = null;
    dom = null;
    locator = null;
    reason = '$error'.replaceFirst(RegExp(r'^Bad state: '), '');
  } finally {
    if (browser != null && browserRequested) {
      try {
        await browser.request('release');
      } on Object {
        /* The next capture can restart its provider. */
      }
    }
  }
  final aligned = (content?['elements'] as List?)?.isNotEmpty == true;
  final region = <String, Object?>{
    'status': aligned ? 'aligned' : 'image-only',
    'reason': aligned
        ? null
        : reason ?? 'No accessible content was exposed inside this region.',
    if (display.screenCoordinatesKnown) 'screenBounds': regionRectJson(bounds),
    if (display.screenCoordinatesKnown)
      'mapping': {
        'coordinateSpace': Platform.isMacOS
            ? 'screen-points'
            : 'screen-logical',
        'screenBounds': regionRectJson(bounds),
        'imageBounds': {
          'x': 0,
          'y': 0,
          'width': selected.pixels.width.round(),
          'height': selected.pixels.height.round(),
        },
      },
  };
  final snapshot = <String, Object?>{
    'snapshotId': _nextAttachmentId(),
    'observedAtUtc': display.observedAt.toIso8601String(),
    'expiresAtUtc': display.observedAt
        .add(const Duration(seconds: 30))
        .toIso8601String(),
    'surfaceKind': dom == null ? 'Image region' : 'Browser',
    'application': source?['application'] ?? 'Screen',
    'windowTitle': source?['windowTitle'],
    'processName': source?['processName'],
    'source': retainedSource,
    'region': region,
    if (aligned) 'regionContext': content,
    'dom': ?dom,
    'locator': ?locator,
    'confidence': aligned ? (dom == null ? 'medium' : 'high') : 'limited',
    'limitation': reason,
    if (selected.strokes.isNotEmpty)
      'imageAnnotations': selected.annotationInfo,
  };
  return ImageSelection(
    dataUrl: rendered,
    bounds: display.screenCoordinatesKnown ? regionRectJson(bounds) : null,
    alignment: region,
    snapshot: snapshot,
    previewText: aligned
        ? 'Image with ${dom == null ? 'accessibility' : 'DOM'} context from the selected region'
        : 'Image only — ${region['reason']}',
  );
}
