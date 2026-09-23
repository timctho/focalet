import 'dart:io';

/// Desktop launchers may not inherit a terminal's PATH. The broker and the runtimes it
/// launches need the same search path, including interpreters used by CLI shims.
Map<String, String> coreRuntimeEnvironment({
  required Map<String, String> overrides,
  String? operatingSystem,
  Map<String, String>? inherited,
}) {
  final platform = operatingSystem ?? Platform.operatingSystem;
  if (platform != 'macos' && platform != 'windows') return overrides;
  final environment = <String, String>{
    for (final entry in {
      ...(inherited ?? Platform.environment),
      ...overrides,
    }.entries)
      (platform == 'windows' ? entry.key.toUpperCase() : entry.key):
          entry.value,
  };
  if (platform == 'windows') {
    final directories = <String>[];
    final seen = <String>{};
    void add(String? value) {
      if (value == null || value.isEmpty) return;
      if (seen.add(value.toLowerCase())) directories.add(value);
    }

    for (final value in environment['PATH']?.split(';') ?? <String>[]) {
      add(value);
    }
    for (final (variable, suffix) in [
      ('APPDATA', r'\npm'),
      ('LOCALAPPDATA', r'\Microsoft\WinGet\Links'),
      ('LOCALAPPDATA', r'\Programs\nodejs'),
      ('LOCALAPPDATA', r'\agy\bin'),
      ('USERPROFILE', r'\.local\bin'),
      ('USERPROFILE', r'\.bun\bin'),
      ('USERPROFILE', r'\.opencode\bin'),
      ('USERPROFILE', r'\scoop\shims'),
      ('PROGRAMFILES', r'\nodejs'),
      ('NVM_SYMLINK', ''),
    ]) {
      final root = environment[variable];
      if (root != null && root.isNotEmpty) add('$root$suffix');
    }
    return {
      for (final entry in overrides.entries)
        if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
      'PATH': directories.join(';'),
    };
  }
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
