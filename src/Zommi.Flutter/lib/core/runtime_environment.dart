import 'dart:io';

/// Finder does not inherit a terminal's PATH. The broker and the runtimes it
/// launches need the same search path, including interpreters used by CLI shims.
Map<String, String> coreRuntimeEnvironment({
  required Map<String, String> overrides,
  String? operatingSystem,
  Map<String, String>? inherited,
}) {
  if ((operatingSystem ?? Platform.operatingSystem) != 'macos') {
    return overrides;
  }
  final environment = {...(inherited ?? Platform.environment), ...overrides};
  final home = environment['HOME'];
  final directories = <String>{
    ...?environment['PATH']?.split(':').where((path) => path.isNotEmpty),
    if (home != null && home.isNotEmpty) ...[
      '$home/.local/bin',
      '$home/.npm-global/bin',
      '$home/.bun/bin',
      '$home/.opencode/bin',
    ],
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
    '/usr/sbin',
    '/sbin',
  };
  return {...overrides, 'PATH': directories.join(':')};
}
