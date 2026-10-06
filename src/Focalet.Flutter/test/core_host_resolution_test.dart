import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';

void main() {
  test('packaged Rust core is resolved beside the Flutter executable', () {
    expect(
      resolveCoreHostExecutable(
        applicationDirectory: '/opt/focalet',
        pathSeparator: '/',
        operatingSystem: 'linux',
        environment: const {},
        exists: (path) => path == '/opt/focalet/focalet-core-host',
      ),
      '/opt/focalet/focalet-core-host',
    );
    expect(
      resolveCoreHostExecutable(
        applicationDirectory: r'C:\Apps\Focalet',
        pathSeparator: r'\',
        operatingSystem: 'windows',
        environment: const {},
        exists: (path) => path.endsWith('focalet-core-host.exe'),
      ),
      r'C:\Apps\Focalet\focalet-core-host.exe',
    );
  });

  test('explicit core configuration stays authoritative', () {
    expect(
      resolveCoreHostExecutable(
        configured: ' /custom/core ',
        environment: const {'FOCALET_CORE_HOST': '/ignored'},
        exists: (_) => false,
      ),
      '/custom/core',
    );
    expect(
      resolveCoreHostExecutable(
        environment: const {'FOCALET_CORE_HOST': '/environment/core'},
        exists: (_) => false,
      ),
      '/environment/core',
    );
  });
}
