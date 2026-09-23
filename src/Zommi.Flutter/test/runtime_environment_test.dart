import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/runtime_environment.dart';

void main() {
  test('Finder runtime children can find Homebrew and user-installed CLI interpreters', () {
    final result = coreRuntimeEnvironment(
      operatingSystem: 'macos',
      inherited: {'PATH': '/usr/bin:/bin', 'HOME': '/Users/test'},
      overrides: {'CODEX_HOME': '/Users/test/agent-data'},
    );
    final path = result['PATH']!.split(':');
    expect(path.take(2), ['/usr/bin', '/bin']);
    expect(
      path,
      containsAll([
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/Users/test/.local/bin',
        '/Users/test/.npm-global/bin',
        '/Users/test/.bun/bin',
        '/Users/test/.opencode/bin',
      ]),
    );
    expect(path.where((value) => value == '/usr/bin').length, 1);
    expect(result['CODEX_HOME'], '/Users/test/agent-data');
    expect(result.containsKey('HOME'), isFalse);
  });

  test('explicit runtime path has precedence and other platforms retain their environment', () {
    const overrides = {'PATH': '/custom/bin', 'CODEX_HOME': '/agent'};
    final result = coreRuntimeEnvironment(
      operatingSystem: 'macos',
      inherited: {'PATH': '/usr/bin'},
      overrides: overrides,
    );
    expect(result['PATH']!.split(':').first, '/custom/bin');
    for (final platform in ['linux']) {
      expect(
        coreRuntimeEnvironment(operatingSystem: platform, overrides: overrides),
        same(overrides),
      );
    }
  });

  test('Windows includes user CLIs and their Node interpreter with case-insensitive keys', () {
    final result = coreRuntimeEnvironment(
      operatingSystem: 'windows',
      inherited: {
        'Path': r'C:\Windows;C:\TOOLS',
        'AppData': r'C:\Users\Test User\AppData\Roaming',
        'UserProfile': r'C:\Users\Test User',
        'ProgramFiles': r'C:\Program Files',
        'NVM_SYMLINK': r'C:\tools',
      },
      overrides: {'CODEX_HOME': r'C:\agent'},
    );
    final path = result['PATH']!.split(';');
    expect(path.take(2), [r'C:\Windows', r'C:\TOOLS']);
    expect(
      path,
      containsAll([
        r'C:\Users\Test User\AppData\Roaming\npm',
        r'C:\Users\Test User\.local\bin',
        r'C:\Users\Test User\.bun\bin',
        r'C:\Users\Test User\scoop\shims',
        r'C:\Program Files\nodejs',
      ]),
    );
    expect(path.where((p) => p.toLowerCase() == r'c:\tools'), hasLength(1));
    expect(result['CODEX_HOME'], r'C:\agent');
    final overridden = coreRuntimeEnvironment(
      operatingSystem: 'windows',
      inherited: {'Path': r'C:\stale'},
      overrides: {'PATH': r'C:\current'},
    );
    expect(overridden['PATH'], r'C:\current');
  });
}
