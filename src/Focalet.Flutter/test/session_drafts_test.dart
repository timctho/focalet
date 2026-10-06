import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/core/core_bridge.dart';
import 'package:focalet_flutter/state/session_catalog_store.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/widgets/inline_attachment_composer.dart';
import 'package:focalet_flutter/focalet_app.dart';

import 'content_selection_test.dart' show selected;
import 'session_catalog_cache_test.dart' show MemoryCatalogStore;
import 'session_runtime_test.dart' show hermes, multiRuntimeCore;
import 'test_support.dart';

void main() {
  testWidgets(
    'switching chats restores text, selection and inline attachment order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge()
        ..nextSelections = [selected('first', 'First source')];
      final core = multiRuntimeCore();
      await tester.pumpWidget(FocaletApp(core: core, desktop: desktop));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('focalet-composer'));
      final composer =
          tester.widget<TextField>(field).controller!
              as InlineAttachmentTextController;
      await tester.enterText(field, 'Codex draft');
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      composer.selection = const TextSelection.collapsed(offset: 0);
      desktop.nextSelections = [selected('second', 'Second source')];
      await tester.tap(find.byKey(const ValueKey('select-content')));
      await tester.pumpAndSettle();
      final original = composer.value;
      expect(composer.inlineAttachments.map((a) => a.id), ['second', 'first']);

      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('new-session')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('create-session-runtime-hermes')),
      );
      await tester.pumpAndSettle();
      expect(composer.text, isEmpty);
      expect(composer.inlineAttachments, isEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        composer.text,
        isEmpty,
        reason: 'Undo cannot restore another chat draft',
      );
      await tester.enterText(field, 'Hermes draft');
      await tester.tap(
        find.byKey(const ValueKey('session-runtime-codex-session-1')),
      );
      await tester.pumpAndSettle();
      expect(composer.text, original.text);
      expect(composer.selection, original.selection);
      expect(composer.inlineAttachments.map((a) => a.id), ['second', 'first']);
      expect(composer.inlineAttachments.map((a) => a.token), ['[B]', '[A]']);

      await tester.tap(
        find.byKey(const ValueKey('session-runtime-hermes-created-session')),
      );
      await tester.pumpAndSettle();
      expect(composer.text, 'Hermes draft');
      expect(composer.inlineAttachments, isEmpty);
      await tester.tap(find.byKey(const ValueKey('send-message')));
      await tester.pump();
      core.emit(
        const CoreEvent(
          name: 'turn.completed',
          sequence: 1,
          runtimeTargetId: 'runtime-hermes',
          sessionId: 'created-session',
          turnId: 'created-session-live-turn',
          payload: {'status': 'completed'},
        ),
      );
      await tester.pumpAndSettle();
      expect(core.lastMessage, 'Hermes draft');
      expect(core.lastSnapshots, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('session-runtime-codex-session-1')),
      );
      await tester.pumpAndSettle();
      expect(composer.text, original.text);
      await tester.tap(
        find.byKey(const ValueKey('session-runtime-hermes-created-session')),
      );
      await tester.pumpAndSettle();
      expect(composer.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'drafts use runtime plus session ID and failed navigation keeps the draft',
    () async {
      final core = multiRuntimeCore();
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
      );
      addTearDown(controller.close);
      await controller.initialize();
      controller.updateComposerValue(const TextEditingValue(text: 'Codex'));
      core.connectErrorCode = 'authentication-required';
      await controller.selectRuntime(hermes.id);
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.composerValue.text, 'Codex');
      core.connectErrorCode = null;
      await controller.switchSession('session-1', runtimeTargetId: hermes.id);
      expect(controller.composerValue.text, isEmpty);
      controller.updateComposerValue(const TextEditingValue(text: 'Hermes'));
      core.openSessionFails = true;
      await controller.switchSession(
        'session-1',
        runtimeTargetId: 'runtime-codex',
      );
      expect(controller.composerValue.text, 'Hermes');
      core.openSessionFails = false;
      await controller.switchSession(
        'session-1',
        runtimeTargetId: 'runtime-codex',
      );
      expect(controller.composerValue.text, 'Codex');
      await controller.switchSession('session-1', runtimeTargetId: hermes.id);
      expect(controller.composerValue.text, 'Hermes');
    },
  );

  test(
    'abandoned empty chats stay dismissed through catalog refresh and restart',
    () async {
      final store = MemoryCatalogStore(const SessionCatalogSnapshot());
      final core = multiRuntimeCore();
      final controller = FocaletController(
        core: core,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
      );
      await controller.initialize();
      await controller.createSession(runtimeTargetId: hermes.id);
      core.sessionsByRuntime[hermes.id] = [
        {'id': 'created-session', 'title': 'New chat'},
      ];
      await controller.switchSession(
        'session-1',
        runtimeTargetId: 'runtime-codex',
      );
      await controller.refreshSessionCatalog(force: true);
      expect(
        controller.sessions.where((s) => s.id == 'created-session'),
        isEmpty,
      );
      await controller.close();
      expect(
        store.snapshot.dismissedSessions,
        contains((hermes.id, 'created-session')),
      );
      final restartedCore = multiRuntimeCore()
        ..sessionsByRuntime[hermes.id] = core.sessionsByRuntime[hermes.id]!;
      final restarted = FocaletController(
        core: restartedCore,
        desktop: FakeDesktopBridge(),
        sessionCatalogStore: store,
      );
      addTearDown(restarted.close);
      await restarted.initialize();
      await restarted.refreshSessionCatalog(force: true);
      expect(
        restarted.sessions.where((s) => s.id == 'created-session'),
        isEmpty,
      );
    },
  );

  test(
    'new chats with a draft, attachment or sent message survive leaving',
    () async {
      for (final content in ['text', 'attachment', 'sent']) {
        final controller = FocaletController(
          core: multiRuntimeCore(),
          desktop: FakeDesktopBridge(),
        );
        await controller.initialize();
        await controller.createSession(runtimeTargetId: hermes.id);
        switch (content) {
          case 'text':
            controller.updateComposerValue(
              const TextEditingValue(text: 'Keep this'),
            );
          case 'attachment':
            controller.addAttachment(selected('source', 'Keep this source'));
          case 'sent':
            await controller.submit('Keep this conversation');
        }
        await controller.switchSession(
          'session-1',
          runtimeTargetId: 'runtime-codex',
        );
        expect(
          controller.sessions.any(
            (s) => s.runtimeTargetId == hermes.id && s.id == 'created-session',
          ),
          isTrue,
          reason: content,
        );
        await controller.close();
      }
    },
  );
}
