import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test('Flutter reports a missing Rust host without pending work', () async {
    final bridge = ProcessCoreBridge(
      executablePath:
          '${Directory.systemTemp.path}/zommi-core-host-does-not-exist',
    );
    await expectLater(bridge.initialize(), throwsA(isA<ProcessException>()));
    await bridge.close();
  });

  test(
    'Flutter exchanges versioned requests with the Rust core host',
    () async {
      final executableName = Platform.isWindows
          ? 'zommi-core-host.exe'
          : 'zommi-core-host';
      final executable = File(
        '${Directory.current.path}/../../target/debug/$executableName',
      ).absolute;
      expect(
        executable.existsSync(),
        isTrue,
        reason: 'Build the Rust workspace before running Flutter tests.',
      );

      final bridge = ProcessCoreBridge(executablePath: executable.path);
      addTearDown(bridge.close);
      final status = await bridge.initialize();
      expect(status.version, '0.1.0');
      expect(status.protocolVersion, coreProtocolVersion);
      expect(status.capabilities, contains('context.handoff.v1'));

      final handoff = await bridge.buildContextHandoff(
        message: 'compare this',
        snapshots: const [
          <String, Object?>{
            'surfaceKind': 'Browser',
            'application': 'Edge',
            'selection': <String>['selected value'],
            'locator': <String, Object?>{
              'kind': 'URL',
              'value': 'https://example.test/report',
            },
          },
        ],
        imageCount: 1,
      );
      expect(handoff, contains('<user_message>\ncompare this'));
      expect(handoff, contains('PRIMARY SURFACE SELECTION'));
      expect(handoff, contains('URL: https://example.test/report'));
      expect(handoff, contains('User-selected image regions attached: 1'));
    },
  );
}
