import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test(
    'Claude compatible PTY streams with explicit degraded semantics',
    () async {
      if (Platform.isWindows) return;
      final fixture = File(
        '${Directory.current.path}/../../crates/zommi-core-host/tests/'
        'fake_terminal_cli.py',
      ).absolute;
      final temporary = await Directory.systemTemp.createTemp(
        'zommi-pty-rust-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final inputLog = File('${temporary.path}/input.txt');
      final bridge = ProcessCoreBridge(
        executablePath: _coreHostPath(),
        environment: <String, String>{
          'ZOMMI_CLAUDE_COMMAND': await _findPython(),
          'ZOMMI_CLAUDE_ARGS_JSON': jsonEncode(<String>[fixture.path]),
          'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
          'ZOMMI_FAKE_REQUEST_LOG': inputLog.path,
        },
      );
      addTearDown(bridge.close);
      final streamed = Completer<CoreEvent>();
      final completed = Completer<CoreEvent>();
      final subscription = bridge.events.listen((event) {
        if (event.name == 'item.update' &&
            event.payload['text'].toString().contains(
              'fixture terminal answer',
            ) &&
            !streamed.isCompleted) {
          streamed.complete(event);
        }
        if (event.name == 'turn.completed' && !completed.isCompleted) {
          completed.complete(event);
        }
      });
      addTearDown(subscription.cancel);

      await bridge.initialize();
      final discovery = await bridge.discoverRuntimeTargets();
      final target = discovery.targets.singleWhere(
        (target) => target.adapterId == 'pty-compatibility',
      );
      final connection = await bridge.connectRuntime(
        runtimeTargetId: target.id,
        cwd: temporary.path,
      );
      expect(connection.capabilities, <String>['turn.stream.v1']);
      final receipt = await bridge.startTurn(
        runtimeTargetId: target.id,
        sessionId: connection.sessionId,
        message: 'inspect selected terminal context',
        snapshots: const <Map<String, Object?>>[
          <String, Object?>{
            'surfaceKind': 'Window',
            'application': 'Fixture',
            'selection': <String>['selected terminal value'],
          },
        ],
        clientOperationId: 'client:rust-pty-turn',
      );
      expect((await streamed.future).turnId, receipt.turnId);
      final terminal = await completed.future;
      expect(terminal.turnId, receipt.turnId);
      expect(terminal.payload['status'], 'completed');
      expect(terminal.payload['evidence'], 'terminal-prompt-heuristic');
      expect(
        await inputLog.readAsString(),
        contains('PRIMARY SURFACE SELECTION'),
      );

      await expectLater(
        bridge.startTurn(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
          message: 'image is unsupported',
          images: const <String>['data:image/png;base64,aGVsbG8='],
          clientOperationId: 'client:rust-pty-image',
        ),
        throwsA(
          isA<CoreProtocolException>().having(
            (error) => error.code,
            'code',
            'capability-unavailable',
          ),
        ),
      );
      await expectLater(
        bridge.interruptTurn(
          runtimeTargetId: target.id,
          sessionId: connection.sessionId,
          turnId: receipt.turnId,
        ),
        throwsA(
          isA<CoreProtocolException>().having(
            (error) => error.code,
            'code',
            'capability-unavailable',
          ),
        ),
      );
    },
  );

  test('Claude compatible PTY never accepts workspace trust prompts', () async {
    if (Platform.isWindows) return;
    final fixture = File(
      '${Directory.current.path}/../../crates/zommi-core-host/tests/'
      'fake_terminal_cli.py',
    ).absolute;
    final temporary = await Directory.systemTemp.createTemp(
      'zommi-pty-trust-rust-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final inputLog = File('${temporary.path}/input.txt');
    final bridge = ProcessCoreBridge(
      executablePath: _coreHostPath(),
      environment: <String, String>{
        'ZOMMI_CLAUDE_COMMAND': await _findPython(),
        'ZOMMI_CLAUDE_ARGS_JSON': jsonEncode(<String>[fixture.path]),
        'ZOMMI_CORE_STATE_PATH': '${temporary.path}/binding.json',
        'ZOMMI_FAKE_REQUEST_LOG': inputLog.path,
        'ZOMMI_FAKE_TRUST_PROMPT': '1',
      },
    );
    addTearDown(bridge.close);

    await bridge.initialize();
    final target = (await bridge.discoverRuntimeTargets()).targets.singleWhere(
      (target) => target.adapterId == 'pty-compatibility',
    );
    await expectLater(
      bridge.connectRuntime(runtimeTargetId: target.id, cwd: temporary.path),
      throwsA(
        isA<CoreProtocolException>().having(
          (error) => error.code,
          'code',
          'runtime-setup-required',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(inputLog.existsSync(), isFalse);
  });
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
  throw StateError('Python is required for the deterministic PTY fixture.');
}
