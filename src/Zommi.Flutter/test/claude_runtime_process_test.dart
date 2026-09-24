import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test(
    'Claude stream-json supports images, approval and exact streamed identity',
    () async {
      final directory = await Directory.systemTemp.createTemp('zommi-claude-');
      addTearDown(() => directory.delete(recursive: true));
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: {
          'ZOMMI_CLAUDE_COMMAND': await _findPython(),
          'ZOMMI_CLAUDE_ARGS_JSON': jsonEncode([
            File('../../crates/zommi-core-host/tests/fake_claude_runtime.py')
                .absolute
                .path,
          ]),
          'ZOMMI_FAKE_CLAUDE_STORE': '${directory.path}/sessions',
          'ZOMMI_CORE_STATE_PATH': '${directory.path}/binding.json',
        },
      );
      addTearDown(bridge.close);
      final approval = Completer<CoreEvent>();
      final completed = Completer<CoreEvent>();
      final events = <CoreEvent>[];
      final subscription = bridge.events.listen((event) {
        events.add(event);
        if (event.name == 'approval.requested' && !approval.isCompleted) {
          approval.complete(event);
        }
        if (event.name == 'turn.completed' && !completed.isCompleted) {
          completed.complete(event);
        }
      });
      addTearDown(subscription.cancel);
      await bridge.initialize();
      final target = (await bridge.discoverRuntimeTargets()).targets
          .singleWhere((t) => t.runtimeId == 'claude');
      expect(target.adapterId, 'claude-stream-json');
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: directory.path,
      );
      expect(
        connection.capabilities,
        containsAll([
          'input.image.v1',
          'session.resume.v1',
          'approval.resolve.v1',
          'model.select.v1',
        ]),
      );
      final receipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'approve-now',
        model: 'fixture-b',
        images: ['data:image/png;base64,aGVsbG8='],
        clientOperationId: 'flutter:claude-test',
      );
      final request = await approval.future;
      await bridge.resolveApproval(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        approvalId: request.payload['approvalId']!.toString(),
        optionId: 'allow_once',
      );
      expect((await completed.future).payload['status'], 'completed');
      final updates = events.where((e) => e.name == 'item.update').toList();
      expect(updates.map((e) => e.payload['itemId']).toSet(), hasLength(1));
      expect(updates.last.payload['text'], 'ALLOWED');
      expect(
        updates.every(
          (e) =>
              e.sessionId == connection.sessionId && e.turnId == receipt.turnId,
        ),
        isTrue,
      );
    },
  );
}

String _coreHostPath() {
  final executableName = Platform.isWindows
      ? 'zommi-core-host.exe'
      : 'zommi-core-host';
  final executable = File(
    '${Directory.current.path}/../../target/debug/$executableName',
  ).absolute;
  if (!executable.existsSync()) {
    throw StateError('Build the Rust workspace before running Flutter tests.');
  }
  return executable.path;
}

Future<String> _findPython() async {
  for (final candidate in <String>['python3', 'python']) {
    try {
      final result = await Process.run(candidate, const ['--version']);
      if (result.exitCode == 0) return candidate;
    } on ProcessException {
      // Try the next common executable name.
    }
  }
  throw StateError('Python is required for the Claude protocol fixture.');
}
