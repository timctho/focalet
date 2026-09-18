import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/runtime_command_catalog.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/widgets/runtime_command_menu.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'golden_support.dart';
import 'test_support.dart';

class CommandCore extends RichFakeCore implements RuntimeCommandBridge {
  final reads = <(String, String, bool)>[];
  final commands = <String>[];
  Completer<Map<String, Object?>>? catalogGate;
  bool failDiscovery = false;

  @override
  Future<Map<String, Object?>> listCommands({
    required String runtimeTargetId,
    required String sessionId,
    bool force = false,
  }) async {
    reads.add((runtimeTargetId, sessionId, force));
    if (catalogGate case final gate?) return gate.future;
    if (failDiscovery) {
      throw const CoreProtocolException('unsupported-method', 'Old runtime');
    }
    return {
      'commands': [
        {
          'name': 'inspect',
          'description': 'Inspect the current project',
          'inputHint': 'target',
        },
        {
          'name': 'terminal',
          'description': 'Terminal settings',
          'disabledReason': 'Available in the runtime terminal',
        },
      ],
    };
  }

  @override
  Future<TurnReceipt> startCommand({
    required String runtimeTargetId,
    required String sessionId,
    required String message,
    required String clientOperationId,
    String? model,
    String? effort,
    String? cwd,
    String? profile,
  }) async {
    commands.add(message);
    emit(
      CoreEvent(
        name: 'turn.started',
        sequence: 10,
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        turnId: 'command-turn',
        clientOperationId: clientOperationId,
        payload: const {},
      ),
    );
    emit(
      CoreEvent(
        name: 'turn.completed',
        sequence: 11,
        runtimeTargetId: runtimeTargetId,
        sessionId: sessionId,
        turnId: 'command-turn',
        clientOperationId: clientOperationId,
        payload: const {'status': 'completed'},
      ),
    );
    return TurnReceipt(
      accepted: true,
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      turnId: 'command-turn',
      clientOperationId: clientOperationId,
    );
  }
}

void main() {
  Future<(ZommiController, CommandCore)> setup([CommandCore? value]) async {
    final core = value ?? CommandCore();
    final controller = ZommiController(
      core: core,
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    return (controller, core);
  }

  test(
    'catalogs cache until refresh and pushed replacements win over stale reads',
    () async {
      final core = CommandCore()..catalogGate = Completer();
      final (controller, _) = await setup(core);
      core.emit(
        const CoreEvent(
          name: 'commands.updated',
          sequence: 1,
          runtimeTargetId: 'runtime-codex',
          sessionId: 'session-1',
          payload: {
            'commands': [
              {'name': 'new-command', 'description': 'New'},
            ],
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      core.catalogGate!.complete({
        'commands': [
          {'name': 'stale'},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.composerCommands.map((c) => c.text),
        contains('/new-command'),
      );
      expect(
        controller.composerCommands.map((c) => c.text),
        isNot(contains('/stale')),
      );
      await controller.refreshCommands();
      expect(core.reads, hasLength(1));
      core.catalogGate = null;
      await controller.refreshCommands(force: true);
      expect(core.reads.last.$3, isTrue);
      expect(
        controller.composerCommands.map((c) => c.text),
        contains('/inspect'),
      );
    },
  );

  test('catalog changes stay scoped to runtime and session, including empty replacements', () async {
    final (controller, core) = await setup();
    core.emit(
      const CoreEvent(
        name: 'commands.updated',
        sequence: 1,
        runtimeTargetId: 'runtime-pi',
        sessionId: 'session-1',
        payload: {
          'commands': [
            {'name': 'other-runtime'},
          ],
        },
      ),
    );
    core.emit(
      const CoreEvent(
        name: 'commands.updated',
        sequence: 1,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-2',
        payload: {
          'commands': [
            {'name': 'other-session'},
          ],
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      controller.composerCommands.map((c) => c.text),
      isNot(anyOf(contains('/other-runtime'), contains('/other-session'))),
    );
    core.emit(
      const CoreEvent(
        name: 'commands.updated',
        sequence: 2,
        runtimeTargetId: 'runtime-codex',
        sessionId: 'session-1',
        payload: {'commands': []},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.composerCommands.map((c) => c.text), contains('/goal'));
    expect(
      controller.composerCommands.map((c) => c.text),
      isNot(contains('/inspect')),
    );
  });

  test('discovered commands use explicit execution; disabled and unknown commands keep their drafts', () async {
    final (controller, core) = await setup();
    await controller.selectRuntime('runtime-pi');
    await Future<void>.delayed(Duration.zero);
    controller.updateComposerValue(const TextEditingValue(text: '/terminal'));
    await controller.submit('/terminal');
    expect(controller.composerValue.text, '/terminal');
    expect(core.commands, isEmpty);
    expect(controller.commandResult, contains('runtime terminal'));
    await controller.submit('/missing');
    expect(core.lastMessage, isNull);
    controller.updateComposerValue(
      const TextEditingValue(text: '/inspect src'),
    );
    await controller.submit('/inspect src');
    await Future<void>.delayed(Duration.zero);
    expect(core.commands, ['/inspect src']);
    expect(core.lastMessage, isNull);
    expect(controller.composerValue.text, isEmpty);
    expect(controller.turnActive, isFalse);
  });

  test(
    'failed discovery preserves native commands and ordinary chat',
    () async {
      final (controller, core) = await setup(
        CommandCore()..failDiscovery = true,
      );
      expect(
        controller.composerCommands.map((c) => c.text),
        contains('/clear'),
      );
      await controller.submit('/help');
      expect(controller.commandResult, contains('/goal'));
      await controller.submit('hello');
      expect(core.lastMessage, 'hello');
    },
  );

  testWidgets('runtime menu renders metadata, unavailable commands and refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(680, 350));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      final fontDirectory =
          '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';
      for (final (family, file) in [
        ('CommandPreview', 'Roboto-Regular.ttf'),
        ('MaterialIcons', 'MaterialIcons-Regular.otf'),
      ]) {
        final loader = FontLoader(family)
          ..addFont(
            File('$fontDirectory/$file')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await loader.load();
      }
    });
    var refreshed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'CommandPreview'),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('command-golden'),
              child: RuntimeCommandMenu(
                commands: const [
                  ComposerCommand(
                    '/inspect',
                    'Inspect the current project',
                    native: false,
                    inputHint: 'target',
                  ),
                  ComposerCommand(
                    '/terminal',
                    'Terminal settings',
                    native: false,
                    disabledReason: 'Available in the runtime terminal',
                  ),
                ],
                selectedIndex: 0,
                onSelected: (_) {},
                onRefresh: () {
                  refreshed = true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Available in the runtime terminal'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey('command-golden')),
      matchesGoldenFile(platformGoldenPath('runtime_command_menu.png')),
    );
    await tester.tap(find.byTooltip('Refresh commands'));
    expect(refreshed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pi composer discovers and completes commands from the runtime', (
    tester,
  ) async {
    final core = CommandCore()
      ..activeTargetId = 'runtime-pi'
      ..historyCount = 0;
    await tester.binding.setSurfaceSize(const Size(960, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ZommiApp(core: core, desktop: FakeDesktopBridge()));
    await tester.pumpAndSettle();
    final field = find.byType(TextField).last;
    await tester.tap(field);
    await tester.enterText(field, '/ins');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('runtime-command-/inspect')),
      findsOneWidget,
    );
    for (final width in [960.0, 1600.0]) {
      await tester.binding.setSurfaceSize(Size(width, 760));
      await tester.pumpAndSettle();
      final panel = tester.getRect(
        find
            .descendant(
              of: find.byKey(const ValueKey('runtime-command-menu')),
              matching: find.byType(Material),
            )
            .first,
      );
      final composer = tester.getRect(
        find.byKey(const ValueKey('message-composer-shell')),
      );
      expect(panel.left, closeTo(composer.left, .1));
      expect(panel.right, closeTo(composer.right, .1));
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '/inspect ');
    expect(tester.takeException(), isNull);
  });
}
