import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/gnome_integration.dart';
import 'package:zommi_flutter/widgets/gnome_integration_setup.dart';

class _Settings implements GnomeDesktopSettings {
  bool fail = true;
  int enables = 0;
  Map<String, Object?>? status;
  @override
  bool get supportsGnomeIntegration => true;
  @override
  Future<Map<String, Object?>> gnomeIntegrationStatus({
    bool enable = false,
  }) async {
    if (status != null) return status!;
    if (enable) {
      enables++;
      if (fail) throw StateError('Sign out and sign in, then retry.');
    }
    return {
      'ready': enable,
      'message': enable
          ? 'Desktop integration is ready.'
          : 'Enable integration.',
    };
  }
}

void main() {
  testWidgets('unsupported desktop does not offer an ineffective enable loop', (
    tester,
  ) async {
    final settings = _Settings()
      ..status = {
        'ready': false,
        'canEnable': false,
        'reason': 'x11-session',
        'message': 'GNOME is running on Xorg (X11).',
        'diagnostics': {'compositorSession': 'x11'},
      };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GnomeIntegrationSetup(bridge: settings)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('GNOME is running on Xorg (X11).'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('enable-gnome-integration')),
      findsNothing,
    );
    expect(find.byTooltip('Copy desktop diagnostics'), findsOneWidget);
    expect(find.byTooltip('Check desktop integration'), findsOneWidget);
  });

  testWidgets(
    'extension enable failure remains actionable and retry succeeds',
    (tester) async {
      final settings = _Settings();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GnomeIntegrationSetup(bridge: settings)),
        ),
      );
      await tester.pumpAndSettle();
      final enable = find.byKey(const ValueKey('enable-gnome-integration'));
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(find.text('Sign out and sign in, then retry.'), findsOneWidget);
      expect(enable, findsOneWidget);
      settings.fail = false;
      await tester.tap(enable);
      await tester.pumpAndSettle();
      expect(settings.enables, 2);
      expect(find.text('Desktop integration is ready.'), findsOneWidget);
      expect(enable, findsNothing);
    },
  );

  test(
    'shortcut helper reconnects after exit and still delivers activation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zommi-shortcut-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/helper.py');
      await script.writeAsString('''
from pathlib import Path
import sys
state=Path(__file__).with_suffix('.started')
if not state.exists():
    state.touch()
    sys.exit(1)
print('{"event":"ready","contextShortcut":true}',flush=True)
print('{"event":"activated","shortcutId":"context"}',flush=True)
sys.stdin.read()
''');
      final errors = <Object>[];
      final activated = Completer<String>();
      final client = ProcessGnomeShortcutClient(
        Platform.isWindows ? 'python' : 'python3',
        argumentsBeforeCommand: [script.path],
        retryDelay: const Duration(milliseconds: 20),
      );
      final subscription = client.activations.listen(
        activated.complete,
        onError: errors.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await client.close();
      });
      expect((await client.initialize()).contextShortcut, isFalse);
      expect(
        await activated.future.timeout(const Duration(seconds: 10)),
        'context',
      );
      expect(errors, hasLength(1));
    },
  );
}
