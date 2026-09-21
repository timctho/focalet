part of 'desktop_bridge.dart';

abstract interface class CaptureProvider {
  Future<void> initialize();

  Future<CaptureResult> capture({Offset? point, void Function()? onReady});

  Future<List<CaptureResult>> selectContext();

  Future<ImageSelection?> selectImage();

  Future<void> close();
}

final class CaptureResult {
  const CaptureResult({this.snapshot, this.previewText = '', this.image});

  final ImageSelection? image;

  final Map<String, Object?>? snapshot;
  final String previewText;
}

final class ImageSelection {
  const ImageSelection({
    required this.dataUrl,
    this.bounds,
    this.snapshot,
    this.alignment,
    this.previewText,
  });

  final String dataUrl;
  final Map<String, Object?>? bounds;
  final Map<String, Object?>? snapshot;
  final Map<String, Object?>? alignment;
  final String? previewText;
}

ContextAttachment imageAttachmentFromSelection(
  ImageSelection selected,
  String id,
) {
  final capturedRegion = _nullableMap(selected.snapshot?['region']);
  final dimensions = _pngSize(selected.dataUrl);
  bool matchesImage(Object? value) {
    final mapping = _nullableMap(value);
    final image = _nullableMap(mapping?['imageBounds']);
    return dimensions == null ||
        (image?['x'] == 0 &&
            image?['y'] == 0 &&
            image?['width'] == dimensions['width'] &&
            image?['height'] == dimensions['height']);
  }

  bool sameBounds(Object? value) {
    final bounds = _nullableMap(value);
    return bounds != null &&
        selected.bounds != null &&
        ['x', 'y', 'width', 'height'].every(
          (key) => bounds[key] is num && bounds[key] == selected.bounds![key],
        );
  }

  final hasMapping =
      sameBounds(capturedRegion?['screenBounds']) &&
      sameBounds(selected.alignment?['screenBounds']) &&
      selected.alignment?['mapping'] is Map &&
      matchesImage(selected.alignment?['mapping']) &&
      matchesImage(capturedRegion?['mapping']);
  final aligned =
      hasMapping &&
      selected.snapshot?['source'] is Map &&
      selected.alignment?['status'] == 'aligned' &&
      capturedRegion?['status'] == 'aligned';
  final imageOnlyGeometry =
      hasMapping &&
      selected.alignment?['status'] == 'image-only' &&
      capturedRegion?['status'] == 'image-only';
  final knownImageSource =
      imageOnlyGeometry && selected.snapshot?['source'] is Map;
  final reason =
      selected.alignment?['reason']?.toString() ??
      'No aligned text was exposed for this region.';
  final region = aligned || imageOnlyGeometry
      ? selected.alignment!
      : <String, Object?>{
          'status': 'image-only',
          'reason': reason,
          if (selected.bounds != null) 'screenBounds': selected.bounds,
        };
  final now = DateTime.now().toUtc();
  final metadata = imageOnlyGeometry
      ? (selected.snapshot ?? const <String, Object?>{})
      : const <String, Object?>{};
  final snapshot = aligned
      ? selected.snapshot!
      : <String, Object?>{
          'snapshotId': metadata['snapshotId'] ?? id,
          'observedAtUtc': metadata['observedAtUtc'] ?? now.toIso8601String(),
          'expiresAtUtc':
              metadata['expiresAtUtc'] ??
              now.add(const Duration(seconds: 30)).toIso8601String(),
          'surfaceKind': 'Image region',
          'application': knownImageSource
              ? (metadata['application'] ?? 'Screen')
              : 'Screen',
          'region': region,
          'limitation': reason,
          if (metadata['imageAnnotations'] is Map)
            'imageAnnotations': metadata['imageAnnotations'],
          if (knownImageSource)
            for (final field in [
              'source',
              'locator',
              'windowTitle',
              'processName',
              'spatialContext',
            ])
              if (selected.snapshot!.containsKey(field))
                field: selected.snapshot![field],
        };
  final captureSnapshot = <String, Object?>{
    ...snapshot,
    'selectionKind': 'bbox',
    'capturePlatform':
        _nullableMap(snapshot['source'])?['platform'] ??
        Platform.operatingSystem,
    'captureHostName':
        _nullableMap(snapshot['source'])?['hostName'] ?? Platform.localHostname,
    'imageSize': ?dimensions,
  };
  return ContextAttachment(
    id: id,
    token: '',
    snapshot: captureSnapshot,
    previewText: aligned || imageOnlyGeometry
        ? selected.previewText ??
              (aligned
                  ? 'Image with text from the selected region'
                  : 'Image with screen location — $reason')
        : 'Image only — $reason',
    imageDataUrl: selected.dataUrl,
    bounds: selected.bounds,
  );
}

Map<String, int>? _pngSize(String dataUrl) {
  if (!dataUrl.startsWith('data:image/png;base64,')) return null;
  try {
    final bytes = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));
    if (bytes.length < 24 ||
        bytes[0] != 137 ||
        bytes[1] != 80 ||
        bytes[2] != 78 ||
        bytes[3] != 71) {
      return null;
    }
    final data = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.length);
    final width = data.getUint32(16);
    final height = data.getUint32(20);
    return width > 0 && height > 0 ? {'width': width, 'height': height} : null;
  } on FormatException {
    return null;
  }
}

CaptureProvider platformCaptureProvider() => Platform.isWindows
    ? WindowsCaptureProvider()
    : Platform.isLinux
    ? LinuxCaptureProvider(
        useWaylandPortals: shouldUseWaylandPortals(Platform.environment),
      )
    : PortableCaptureProvider();

final class WindowsCaptureProvider
    implements CaptureProvider, BrowserCaptureSettings {
  bool _browserPageDetails = true;
  @override
  bool get supportsBrowserPageDetails => true;
  @override
  void setBrowserPageDetails(bool enabled) => _browserPageDetails = enabled;

  factory WindowsCaptureProvider({
    String? executablePath,
    NativeCaptureClient? captureClient,
    NativeCaptureClient? selectorClient,
  }) {
    final shared =
        captureClient ??
        selectorClient ??
        ProcessNativeCaptureClient(executablePath ?? _nativeHostPath());
    return WindowsCaptureProvider._(
      captureClient ?? shared,
      selectorClient ?? shared,
    );
  }

  WindowsCaptureProvider._(this._captureClient, this._selectorClient);

  final NativeCaptureClient _captureClient;
  final NativeCaptureClient _selectorClient;

  @override
  Future<void> initialize() async {
    // The shared host has independent UI and accessibility workers.
    // One process keeps one browser authorization across both entry points.
    await Future.wait([
      _captureClient.request('ping'),
      if (!identical(_captureClient, _selectorClient))
        _selectorClient.request('ping'),
    ]);
  }

  @override
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    final response = await _captureClient.request(
      'capture',
      parameters: {
        'browserPageDetails': _browserPageDetails,
        if (point != null)
          'point': {'x': point.dx.round(), 'y': point.dy.round()},
      },
      onReady: onReady,
    );
    return CaptureResult(
      snapshot: _nullableMap(response['snapshot']),
      previewText: response['previewText']?.toString() ?? '',
    );
  }

  @override
  Future<List<CaptureResult>> selectContext() async {
    final response = await _selectorClient.request(
      'selectContent',
      parameters: {
        'returnProcessId': pid,
        'browserPageDetails': _browserPageDetails,
      },
    );
    if (response['errorMessage'] case final String message
        when message.isNotEmpty) {
      throw StateError(message);
    }
    if (response['cancelled'] == true) return const [];
    final selections = response['selections'];
    return [
      for (final item in selections is List ? selections : [response])
        _contentSelectionResult(
          _nullableMap(item) ??
              (throw const FormatException('Invalid content selection')),
        ),
    ];
  }

  CaptureResult _contentSelectionResult(Map<String, Object?> response) {
    final dataUrl = response['dataUrl']?.toString() ?? '';
    return CaptureResult(
      snapshot: _nullableMap(response['snapshot']),
      previewText: response['previewText']?.toString() ?? '',
      image: dataUrl.isNotEmpty
          ? ImageSelection(
              dataUrl: dataUrl,
              bounds: _nullableMap(response['bounds']),
              snapshot: _nullableMap(response['snapshot']),
              alignment: _nullableMap(response['alignment']),
              previewText: response['previewText']?.toString(),
            )
          : null,
    );
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final response = await _selectorClient.request(
      'selectImage',
      parameters: {
        'returnProcessId': pid,
        'browserPageDetails': _browserPageDetails,
      },
    );
    if (response['cancelled'] == true) return null;
    final dataUrl = response['dataUrl']?.toString() ?? '';
    if (dataUrl.isEmpty) return null;
    return ImageSelection(
      dataUrl: dataUrl,
      bounds: _nullableMap(response['bounds']),
      snapshot: _nullableMap(response['snapshot']),
      alignment: _nullableMap(response['alignment']),
      previewText: response['previewText']?.toString(),
    );
  }

  @override
  Future<void> close() async {
    await Future.wait([
      _captureClient.close(),
      if (!identical(_captureClient, _selectorClient)) _selectorClient.close(),
    ]);
  }
}

typedef CaptureCommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  Duration timeout,
);

final class LinuxCaptureProvider implements CaptureProvider {
  LinuxCaptureProvider({
    String? executablePath,
    CaptureCommandRunner? runCommand,
    bool? useWaylandPortals,
  }) : _executablePath = executablePath ?? resolveLinuxCaptureExecutable(),
       _runCommand = runCommand ?? _runProcess,
       _useWaylandPortals =
           useWaylandPortals ?? shouldUseWaylandPortals(Platform.environment);

  final String _executablePath;
  final CaptureCommandRunner _runCommand;
  final bool _useWaylandPortals;

  @override
  Future<void> initialize() async {}

  @override
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    final response = await _request([
      _useWaylandPortals ? 'portal-context' : 'context',
    ], const Duration(seconds: 5));
    return _portableResultFromLinuxResponse(response);
  }

  CaptureResult _portableResultFromLinuxResponse(
    Map<String, Object?> response,
  ) => portableCaptureResult(
    application:
        response['application']?.toString() ??
        (_useWaylandPortals ? 'Linux desktop' : 'X11 application'),
    processName: response['processName']?.toString(),
    windowTitle: response['windowTitle']?.toString() ?? '',
    url: '',
    limitation:
        response['limitation']?.toString() ??
        'X11 semantic enrichment depends on AT-SPI.',
  );

  @override
  Future<List<CaptureResult>> selectContext() async {
    final image = await selectImage();
    return image == null ? const [] : [CaptureResult(image: image)];
  }

  @override
  Future<ImageSelection?> selectImage() async {
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'zommi-region-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      final response = await _request([
        _useWaylandPortals ? 'portal-region' : 'region',
        '--output',
        temporary.path,
      ], const Duration(minutes: 5));
      if (response['cancelled'] == true) return null;
      if (!await temporary.exists()) {
        throw StateError('The Linux selector did not produce an image.');
      }
      final bytes = await temporary.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('The Linux selector produced an empty image.');
      }
      return ImageSelection(
        dataUrl: 'data:image/png;base64,${base64Encode(bytes)}',
        bounds: _nullableMap(response['bounds']),
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<Map<String, Object?>> _request(
    List<String> arguments,
    Duration timeout,
  ) async {
    final result = await _runCommand(_executablePath, arguments, timeout);
    if (result.exitCode != 0) {
      throw StateError(
        'Linux capture failed: ${result.stderr.toString().trim()}',
      );
    }
    for (final line in result.stdout.toString().split('\n').reversed) {
      if (line.trim().isEmpty) continue;
      try {
        final value = jsonDecode(line);
        final mapped = _nullableMap(value);
        if (mapped != null) return mapped;
      } on FormatException {
        continue;
      }
    }
    throw StateError('Linux capture returned no JSON result.');
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) => Process.run(executable, arguments).timeout(timeout);

  @override
  Future<void> close() async {}
}

Future<void> hideDesktopForCapture() => Platform.isMacOS
    ? MacCapturePermissions.channel.invokeMethod<void>('hideForCapture')
    : windowManager.hide();

final class PortableCaptureProvider implements CaptureProvider {
  PortableCaptureProvider({
    CaptureCommandRunner? runCommand,
    Future<bool> Function()? screenAccessAllowed,
    Future<ImageSelection?> Function()? selectRegion,
    Future<List<ImageSelection>> Function()? selectRegions,
  }) : _runCommand = runCommand ?? _runProcess,
       _screenAccessAllowed = screenAccessAllowed ?? _macScreenAccessAllowed,
       _selectRegion = selectRegion ?? _captureRegion,
       _selectRegions = selectRegions ?? _captureRegions;

  final CaptureCommandRunner _runCommand;
  final Future<bool> Function() _screenAccessAllowed;
  final Future<ImageSelection?> Function() _selectRegion;
  final Future<List<ImageSelection>> Function() _selectRegions;

  static Future<bool> _macScreenAccessAllowed() async =>
      (await MacCapturePermissions().capturePermissions()).screenRecording;

  @override
  Future<void> initialize() async {}

  @override
  Future<CaptureResult> capture({
    Offset? point,
    void Function()? onReady,
  }) async {
    return _captureMac();
  }

  @override
  Future<List<CaptureResult>> selectContext() async {
    await _ensureScreenAccess();
    CaptureResult? context;
    try {
      // Read the foreground app before the system selector takes activation.
      context = await _captureMac();
    } on Object {
      // Missing Accessibility/Automation must not discard permitted pixels.
    }
    final images = await _selectRegions();
    return [
      for (final image in images)
        CaptureResult(
          image: ImageSelection(
            dataUrl: image.dataUrl,
            bounds: image.bounds,
            alignment: image.alignment,
            snapshot: image.snapshot ?? context?.snapshot,
            previewText: image.previewText ?? context?.previewText,
          ),
        ),
    ];
  }

  static Future<List<ImageSelection>> _captureRegions() async {
    final selections = await MacCapturePermissions.channel
        .invokeListMethod<Object?>('selectRegions');
    return [
      for (final selection in selections ?? const [])
        if (_nullableMap(selection) case final item?)
          ImageSelection(
            dataUrl: item['dataUrl'] as String,
            bounds: _nullableMap(item['bounds']),
            alignment: _nullableMap(item['alignment']),
            snapshot: _nullableMap(item['snapshot']),
            previewText: item['previewText'] as String?,
          ),
    ];
  }

  Future<CaptureResult> _captureMac() async {
    const script = macosForegroundScript;
    final result = await _runCommand('osascript', const [
      '-e',
      script,
    ], const Duration(seconds: 5));
    if (result.exitCode != 0) {
      throw StateError(
        'Allow Zommi in System Settings > Privacy & Security > Accessibility and Automation, then try capture again. ${result.stderr}',
      );
    }
    final fields = result.stdout.toString().trimRight().split('\n');
    final application = fields.isEmpty ? 'macOS application' : fields[0];
    if (application == 'Zommi') {
      throw StateError('Focus an external application and try capture again.');
    }
    var url = '';
    final browserScript = macosBrowserUrlScripts[application];
    if (browserScript != null) {
      try {
        final browser = await _runCommand('osascript', [
          '-e',
          browserScript,
        ], const Duration(seconds: 5));
        if (browser.exitCode == 0) url = browser.stdout.toString().trim();
      } on Object {
        // Browser Automation may be denied or time out. Keep the app context.
      }
    }
    return portableCaptureResult(
      application: application,
      windowTitle: fields.length > 1 ? fields[1] : '',
      url: url,
      limitation: 'macOS captures the front application, title, and supported browser URL. Accessibility and Automation permissions control which details are available.',
    );
  }

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) => Process.run(executable, arguments).timeout(timeout);

  @override
  Future<ImageSelection?> selectImage() async {
    await _ensureScreenAccess();
    return _selectRegion();
  }

  Future<void> _ensureScreenAccess() async {
    if (!await _screenAccessAllowed()) {
      // The permission guide owns explicit requests. Permission can change
      // between that guide and capture; never reopen Settings from this layer.
      throw StateError(
        'Screen Recording is unavailable for this copy of Zommi. Open capture permissions in Settings to check access.',
      );
    }
  }

  static Future<ImageSelection?> _captureRegion() async {
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'zommi-region-${DateTime.now().microsecondsSinceEpoch}.png',
    );
    try {
      final captured = await screenCapturer.capture(
        mode: CaptureMode.region,
        imagePath: temporary.path,
        copyToClipboard: false,
        silent: true,
      );
      final imageBytes = captured?.imageBytes;
      if (captured == null || imageBytes == null || imageBytes.isEmpty) {
        return null;
      }
      return ImageSelection(
        dataUrl: 'data:image/png;base64,${base64Encode(imageBytes)}',
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> close() async {}
}

const macosForegroundScript = '''
tell application "System Events"
  set frontProcess to first application process whose frontmost is true
  set appName to name of frontProcess
  set windowTitle to ""
  try
    set windowTitle to name of front window of frontProcess
  end try
end tell
return appName & linefeed & windowTitle
''';

// Browser dictionaries must be selected before AppleScript compiles the query.
// A dynamic `tell application appName` cannot resolve Chromium's tab terms.
const macosBrowserUrlScripts = <String, String>{
  'Safari': 'tell application "Safari" to return URL of front document',
  'Google Chrome': 'tell application "Google Chrome" to return URL of active tab of front window',
  'Microsoft Edge': 'tell application "Microsoft Edge" to return URL of active tab of front window',
  'Brave Browser': 'tell application "Brave Browser" to return URL of active tab of front window',
};

CaptureResult portableCaptureResult({
  required String application,
  String? processName,
  required String windowTitle,
  required String url,
  required String limitation,
}) {
  final now = DateTime.now().toUtc();
  final snapshot = <String, Object?>{
    'snapshotId': _nextAttachmentId(),
    'observedAtUtc': now.toIso8601String(),
    'expiresAtUtc': now.add(const Duration(seconds: 30)).toIso8601String(),
    'surfaceKind': url.isEmpty ? 'Window' : 'Browser',
    'application': application,
    'processName':
        processName ?? application.toLowerCase().replaceAll(' ', '-'),
    'windowTitle': windowTitle.isEmpty ? null : windowTitle,
    'locator': url.isEmpty ? null : {'kind': 'URL', 'value': url},
    'selection': <Object?>[],
    'visibleText': <Object?>[],
    'accessibilityTree': null,
    'indicatedTarget': null,
    'confidence': url.isNotEmpty || windowTitle.isNotEmpty
        ? 'medium'
        : 'limited',
    'limitation': limitation,
  };
  final preview = [
    'Surface: ${snapshot['surfaceKind']} in $application',
    if (windowTitle.isNotEmpty) 'Window: $windowTitle',
    if (url.isNotEmpty) 'URL: $url',
    'Limitation: $limitation',
  ].join('\n');
  return CaptureResult(snapshot: snapshot, previewText: preview);
}

String resolveLinuxCaptureExecutable({
  String? configured,
  Map<String, String>? environment,
  String? resolvedExecutable,
  String? applicationDirectory,
  String? pathSeparator,
  bool Function(String path)? exists,
}) {
  if (configured?.trim().isNotEmpty == true) return configured!.trim();
  final processEnvironment = environment ?? Platform.environment;
  final environmentPath = processEnvironment['ZOMMI_X11_CAPTURE_HOST']?.trim();
  if (environmentPath?.isNotEmpty == true) return environmentPath!;
  final separator = pathSeparator ?? Platform.pathSeparator;
  final executableDirectory =
      applicationDirectory ??
      File(resolvedExecutable ?? Platform.resolvedExecutable).parent.path;
  final candidate = '$executableDirectory${separator}zommi-x11-capture';
  if (exists?.call(candidate) ?? File(candidate).existsSync()) return candidate;
  return 'zommi-x11-capture';
}

abstract interface class NativeCaptureClient {
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  });

  Future<void> close();
}

final class ProcessNativeCaptureClient implements NativeCaptureClient {
  ProcessNativeCaptureClient(
    this.executablePath, {
    this.captureTimeout = const Duration(seconds: 30),
    this.selectionTimeout = const Duration(minutes: 5),
  });

  final String executablePath;
  final Duration captureTimeout;
  final Duration selectionTimeout;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Map<String, void Function()> _ready = {};
  Future<void>? _starting;
  Future<void> _writes = Future.value();
  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int _nextId = 0;
  String _recentError = '';

  @override
  Future<Map<String, Object?>> request(
    String method, {
    Map<String, Object?> parameters = const {},
    void Function()? onReady,
  }) async {
    await _ensureStarted();
    final process = _process;
    if (process == null) {
      throw StateError('Windows capture host is unavailable.');
    }
    final id = (++_nextId).toString();
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    if (onReady != null) _ready[id] = onReady;
    final response = completer.future.timeout(
      method == 'selectContent' ||
              method == 'selectContext' ||
              method == 'selectImage'
          ? selectionTimeout
          : captureTimeout,
      onTimeout: () {
        _pending.remove(id);
        _ready.remove(id);
        // A timed-out modal selector must not remain above the user's apps.
        if (identical(_process, process)) process.kill();
        throw TimeoutException(
          'Windows capture host timed out during $method.',
        );
      },
    );
    _writes = _writes
        .then((_) async {
          if (!identical(_process, process)) {
            throw StateError('Windows capture host stopped before $method.');
          }
          process.stdin.writeln(
            jsonEncode({
              'id': id,
              'method': method,
              'params': {
                ...parameters,
                if (onReady != null) 'reportReady': true,
              },
            }),
          );
          await process.stdin.flush();
        })
        .catchError((Object error, StackTrace stackTrace) {
          _ready.remove(id);
          _pending.remove(id)?.completeError(error, stackTrace);
        });
    return response;
  }

  Future<void> _ensureStarted() {
    if (_process != null) return Future.value();
    return _starting ??= _startProcess().whenComplete(() => _starting = null);
  }

  Future<void> _startProcess() async {
    if (!await File(executablePath).exists()) {
      throw StateError(
        'Windows capture host was not found at $executablePath.',
      );
    }
    final process = await Process.start(executablePath, const [
      '--capture-host',
    ], runInShell: false);
    _process = process;
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleLine);
    _stderr = process.stderr.transform(utf8.decoder).listen((chunk) {
      _recentError = '$_recentError$chunk';
      if (_recentError.length > 2000) {
        _recentError = _recentError.substring(_recentError.length - 2000);
      }
    });
    unawaited(
      process.exitCode.then((code) {
        if (identical(_process, process)) _process = null;
        final error = StateError(
          'Windows capture host exited with code $code.'
          '${_recentError.trim().isEmpty ? '' : ' ${_recentError.trim()}'}',
        );
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        _ready.clear();
      }),
    );
  }

  void _handleLine(String line) {
    try {
      final value = jsonDecode(line);
      if (value is! Map) return;
      final json = value.map((key, value) => MapEntry(key.toString(), value));
      final id = json['id']?.toString();
      if (json['type'] == 'captureReady') {
        _ready.remove(id)?.call();
        return;
      }
      _ready.remove(id);
      final completer = id == null ? null : _pending.remove(id);
      if (completer == null) return;
      if (json['ok'] == true) {
        completer.complete(_nullableMap(json['result']) ?? <String, Object?>{});
      } else {
        completer.completeError(
          StateError(json['error']?.toString() ?? 'Capture request failed.'),
        );
      }
    } on Object catch (error, stackTrace) {
      for (final pending in _pending.values) {
        pending.completeError(error, stackTrace);
      }
      _pending.clear();
    }
  }

  @override
  Future<void> close() async {
    final process = _process;
    if (process != null) {
      try {
        await request('shutdown').timeout(const Duration(seconds: 2));
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object {
        process.kill();
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
    _process = null;
  }
}

String _nativeHostPath() {
  final configured = Platform.environment['ZOMMI_NATIVE_HOST_PATH'];
  if (configured != null && configured.trim().isNotEmpty) return configured;
  final root = File(Platform.resolvedExecutable).parent.path;
  return '$root${Platform.pathSeparator}native'
      '${Platform.pathSeparator}Zommi.Capture.exe';
}

Map<String, Object?>? _nullableMap(Object? value) {
  if (value == null) return null;
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}
