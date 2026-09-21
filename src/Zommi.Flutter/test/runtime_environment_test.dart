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
    for (final platform in ['windows', 'linux']) {
      expect(
        coreRuntimeEnvironment(operatingSystem: platform, overrides: overrides),
        same(overrides),
      );
    }
  });
}
