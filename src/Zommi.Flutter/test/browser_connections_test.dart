import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/browser_connections.dart';
import 'package:zommi_flutter/widgets/browser_connections_setting.dart';

BrowserConnectionStatus status(CaptureBrowser browser, String state) =>
    BrowserConnectionStatus(
      browser: browser,
      state: state,
      message: state == 'connected'
          ? 'Ready to include webpage text and links where available.'
          : 'Enable browser access to include webpage text and links.',
    );

class Connections implements BrowserConnectionSettings {
  @override
  bool get supportsBrowserConnections => true;
  int checks = 0;
  bool failStatus = false;
  final reconnects = <CaptureBrowser>[];
  Completer<BrowserConnectionStatus>? pending;
  List<BrowserConnectionStatus> statuses = [
    status(CaptureBrowser.edge, 'setup-required'),
    status(CaptureBrowser.chrome, 'connected'),
  ];
  @override
  Future<List<BrowserConnectionStatus>> browserConnections() async {
    checks++;
    if (failStatus) throw StateError('helper unavailable');
    return statuses;
  }

  @override
  Future<BrowserConnectionStatus> reconnectBrowser(CaptureBrowser browser) {
    reconnects.add(browser);
    return (pending ??= Completer<BrowserConnectionStatus>()).future;
  }
}

Widget panel(Connections connections, {bool enabled = true, Key? captureKey}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: captureKey,
            child: Material(
              color: Colors.white,
              child: SizedBox(
                width: 278,
                child: BrowserConnectionsSetting(
                  settings: connections,
                  enabled: enabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'settings reads status without connecting and reconnects only the chosen browser',
    (tester) async {
      final connections = Connections();
      await tester.pumpWidget(panel(connections));
      await tester.pumpAndSettle();
      expect(connections.checks, 1);
      expect(connections.reconnects, isEmpty);
      expect(find.text('Setup needed'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reconnect-browser-edge')));
      await tester.pump();
      expect(connections.reconnects, [CaptureBrowser.edge]);
      expect(
        find.text('Connecting… Check your browser for permission.'),
        findsOneWidget,
      );
      expect(find.text('Connected'), findsOneWidget);
      connections.pending!.complete(status(CaptureBrowser.edge, 'connected'));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabling details ignores a late connection result', (
    tester,
  ) async {
    final connections = Connections();
    await tester.pumpWidget(panel(connections));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reconnect-browser-edge')));
    await tester.pump();
    connections.statuses = [
      for (final browser in CaptureBrowser.values) status(browser, 'disabled'),
    ];
    await tester.pumpWidget(panel(connections, enabled: false));
    await tester.pumpAndSettle();
    connections.pending!.complete(status(CaptureBrowser.edge, 'connected'));
    await tester.pumpAndSettle();
    expect(find.text('Off'), findsNWidgets(2));
    expect(find.text('Connected'), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('reconnect-browser-chrome')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'browser-specific setup explains automatic discovery and override limits',
    (tester) async {
      final connections = Connections();
      connections.statuses = [
        const BrowserConnectionStatus(
          browser: CaptureBrowser.chrome,
          state: 'connected',
          message: 'Browser access is connected.',
          explicitEndpoint: true,
        ),
        status(CaptureBrowser.edge, 'other-browser'),
      ];
      await tester.pumpWidget(panel(connections));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('browser-endpoint-override')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('setup-browser-chrome')));
      await tester.pumpAndSettle();
      expect(find.text('chrome://inspect/#remote-debugging'), findsOneWidget);
      expect(connections.reconnects, isEmpty);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('setup-browser-edge')));
      await tester.pumpAndSettle();
      expect(find.text('--remote-debugging-port=0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed refresh cannot leave a stale connected label', (
    tester,
  ) async {
    final connections = Connections();
    await tester.pumpWidget(panel(connections));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    connections.failStatus = true;
    await tester.tap(find.byKey(const ValueKey('refresh-browser-connections')));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsNothing);
    expect(find.text('Status unavailable'), findsNWidgets(2));
    expect(
      find.text('Could not check browser access. Try refreshing.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser settings render at the app settings width', (
    tester,
  ) async {
    final connections = Connections();
    final key = GlobalKey();
    final output = Platform.environment['ZOMMI_BROWSER_SETTINGS_PREVIEW'];
    if (output != null) {
      await tester.runAsync(() async {
        await (FontLoader('MaterialIcons')..addFont(
              File(Platform.environment['ZOMMI_BROWSER_SETTINGS_ICONS']!)
                  .readAsBytes()
                  .then(ByteData.sublistView),
            ))
            .load();
        await (FontLoader('Roboto')..addFont(
              File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
                  .readAsBytes()
                  .then(ByteData.sublistView),
            ))
            .load();
      });
    }
    await tester.pumpWidget(panel(connections, captureKey: key));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (output != null) {
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
