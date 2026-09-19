import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/response_notifications.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('response completion', () {
    late RichFakeCore core;
    late FakeDesktopBridge desktop;
    late ZommiController controller;
    var sequence = 0;

    setUp(() async {
      core = RichFakeCore()..uniqueTurnIds = true;
      desktop = FakeDesktopBridge();
      controller = ZommiController(core: core, desktop: desktop);
      await controller.initialize();
      sequence = 0;
    });
    tearDown(() => controller.close());

    void complete({
      String runtime = 'runtime-codex',
      String? session = 'session-1',
      String? turn = 'response',
      String? operation,
      String status = 'completed',
    }) => core.emit(
      CoreEvent(
        name: 'turn.completed',
        sequence: ++sequence,
        runtimeTargetId: runtime,
        sessionId: session,
        turnId: turn,
        clientOperationId: operation,
        payload: {'status': status},
      ),
    );

    test('history and session switches are silent', () async {
      await controller.switchSession('session-2');
      await controller.switchSession('session-1');
      expect(desktop.responseNotifications, isEmpty);
    });

    test('all runtimes notify once without changing the selected chat', () {
      const draft = TextEditingValue(text: 'keep my draft');
      controller.updateComposerValue(draft);
      final calls = [...desktop.calls];
      for (final target in RichFakeCore.targets) {
        complete(runtime: target.id, session: 'background');
        complete(runtime: target.id, session: 'background');
      }
      expect(desktop.responseNotifications, hasLength(3));
      expect(
        desktop.responseNotifications.map((value) => value['runtimeName']),
        ['Codex', 'Pi', 'Claude CLI'],
      );
      expect(
        desktop.responseNotifications.every(
          (value) => value['sessionId'] == 'background',
        ),
        isTrue,
      );
      expect(controller.activeRuntime?.id, 'runtime-codex');
      expect(controller.activeSessionId, 'session-1');
      expect(controller.composerValue, draft);
      expect(desktop.calls, calls);
    });

    test('failure, interruption and incomplete identities are silent', () {
      for (final status in ['failed', 'interrupted', 'unknown']) {
        complete(turn: status, status: status);
      }
      complete(session: null, turn: 'no-session');
      complete(turn: null);
      expect(desktop.responseNotifications, isEmpty);
      complete(turn: null, operation: 'operation-only');
      complete(turn: null, operation: 'operation-only');
      expect(desktop.responseNotifications, hasLength(1));
    });

    for (final fails in [false, true]) {
      test(
        'slow notification (fails=$fails) does not block the queue',
        () async {
          final gate = Completer<void>();
          desktop
            ..notificationGate = gate.future
            ..notificationFails = fails;
          await controller.submit('first');
          await controller.submit('second');
          complete(turn: core.startedTurns.first['turnId']! as String);
          await Future<void>.delayed(Duration.zero);
          expect(core.startedTurns, hasLength(2));
          expect(controller.turnActive, isTrue);
          final status = controller.status;
          gate.complete();
          await Future<void>.delayed(Duration.zero);
          expect(controller.status, status);
          expect(controller.statusWarning, isFalse);
        },
      );
    }

    test(
      'notification click opens exact runtime/session and saves draft',
      () async {
        const draft = TextEditingValue(
          text: 'unsent',
          selection: TextSelection(baseOffset: 1, extentOffset: 4),
        );
        controller.updateComposerValue(draft);
        desktop.emit(
          const DesktopInvocation(
            kind: DesktopInvocationKind.openSession,
            runtimeTargetId: 'runtime-pi',
            sessionId: 'session-1',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.activeRuntime?.id, 'runtime-pi');
        expect(controller.activeSessionId, 'session-1');
        expect(controller.composerValue.text, isEmpty);
        await controller.switchSession(
          'session-1',
          runtimeTargetId: 'runtime-codex',
        );
        expect(controller.composerValue, draft);
        expect(core.startedTurns, isEmpty);
      },
    );
  });

  test('a notification clicked during discovery opens after startup', () async {
    final gate = Completer<void>();
    final core = RichFakeCore()..discoveryGate = gate.future;
    final desktop = FakeDesktopBridge();
    final controller = ZommiController(core: core, desktop: desktop);
    addTearDown(controller.close);
    final startup = controller.initialize();
    desktop.emit(
      const DesktopInvocation(
        kind: DesktopInvocationKind.openSession,
        runtimeTargetId: 'runtime-pi',
        sessionId: 'session-2',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(core.openedSessions, isEmpty);
    gate.complete();
    await startup;
    await Future<void>.delayed(Duration.zero);
    expect(controller.activeRuntime?.id, 'runtime-pi');
    expect(controller.activeSessionId, 'session-2');
    expect(core.startedTurns, isEmpty);
  });

  group('native notification service', () {
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late ResponseNotifications notifications;
    late List<MethodCall> calls;
    late List<(String, String)> opened;
    late List<String> events;
    Map<String, Object?>? launch;
    var available = true;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      MacOSFlutterLocalNotificationsPlugin.registerWith();
      calls = [];
      opened = [];
      events = [];
      launch = null;
      available = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'initialize') return available;
        if (call.method == 'getNotificationAppLaunchDetails') return launch;
        return null;
      });
      notifications = ResponseNotifications(
        onOpen: (runtime, session) => opened.add((runtime, session)),
        record: (event, details) async => events.add(event),
      );
    });
    tearDown(() {
      notifications.close();
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> show() => notifications.show(
      runtimeTargetId: 'runtime-pi',
      sessionId: 'saved-session',
      turnId: 'turn-1',
      runtimeName: 'Pi',
      sessionTitle: 'My chat',
    );

    Future<void> activate(String payload) async {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('didReceiveNotificationResponse', {
            'notificationResponseType': 0,
            'payload': payload,
          }),
        ),
        (_) {},
      );
    }

    test('uses native alert/sound, one initialization and exact activation payload', () async {
      await Future.wait([show(), show()]);
      expect(calls.where((call) => call.method == 'initialize'), hasLength(1));
      final shows = calls.where((call) => call.method == 'show').toList();
      final details = shows.first.arguments as Map;
      expect(details['title'], 'Pi response ready');
      expect(details['body'], 'My chat');
      expect(details['platformSpecifics']['presentSound'], isTrue);
      expect(details['platformSpecifics']['presentBanner'], isTrue);
      expect(details['id'], isNot(shows.last.arguments['id']));
      await activate(details['payload'] as String);
      expect(opened, [('runtime-pi', 'saved-session')]);
      await activate('not json');
      await activate(jsonEncode({'sessionId': 'unrelated'}));
      notifications.close();
      await activate(details['payload'] as String);
      await show();
      expect(opened, hasLength(1));
      expect(
        events.where((event) => event == 'notification.requested'),
        hasLength(2),
      );
    });

    test('opens the notification that launched the app', () async {
      launch = {
        'notificationLaunchedApp': true,
        'notificationResponse': {
          'notificationResponseType': 0,
          'payload': jsonEncode({
            'runtimeTargetId': 'runtime-pi',
            'sessionId': 'saved-session',
          }),
        },
      };
      await notifications.initialize();
      expect(opened, [('runtime-pi', 'saved-session')]);
    });

    test('unavailable notifications do not try to show', () async {
      available = false;
      await show();
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      expect(events, ['notification.unavailable']);
    });
  });
}
