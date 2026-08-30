import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test('packaged Rust core is resolved beside the Flutter executable', () {
    expect(
      resolveCoreHostExecutable(
        applicationDirectory: '/opt/zommi',
        pathSeparator: '/',
        operatingSystem: 'linux',
        environment: const {},
        exists: (path) => path == '/opt/zommi/zommi-core-host',
      ),
      '/opt/zommi/zommi-core-host',
    );
    expect(
      resolveCoreHostExecutable(
        applicationDirectory: r'C:\Apps\Zommi',
        pathSeparator: r'\',
        operatingSystem: 'windows',
        environment: const {},
        exists: (path) => path.endsWith('zommi-core-host.exe'),
      ),
      r'C:\Apps\Zommi\zommi-core-host.exe',
    );
  });

  test('explicit core configuration stays authoritative', () {
    expect(
      resolveCoreHostExecutable(
        configured: ' /custom/core ',
        environment: const {'ZOMMI_CORE_HOST': '/ignored'},
        exists: (_) => false,
      ),
      '/custom/core',
    );
    expect(
      resolveCoreHostExecutable(
        environment: const {'ZOMMI_CORE_HOST': '/environment/core'},
        exists: (_) => false,
      ),
      '/environment/core',
    );
  });
}
