import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  test('Pi resolves legacy IDs then reopens both files across broker restarts', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zommi-pi-recovery-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const a = '01a0ab97-dbe9-72e5-8de3-7d4b6e10ed7f';
    const b = '01a0ab45-843c-76b9-84fe-f0e0afb914c6';
    const bad = '01a0ab45-843c-76b9-84fe-f0e0afb914c7';
    final log = File('${directory.path}/requests.jsonl');
    final environment = {
      'ZOMMI_PI_COMMAND': Platform.isWindows ? 'python' : 'python3',
      'ZOMMI_PI_ARGS_JSON': jsonEncode([
        File('../../crates/zommi-core-host/tests/fake_pi_rpc.py').absolute.path,
      ]),
      'ZOMMI_CORE_STATE_PATH': '${directory.path}/binding.json',
      'ZOMMI_RUNTIME_OVERRIDES_PATH': '${directory.path}/overrides.json',
      'ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH': '${directory.path}/discovery.json',
      'ZOMMI_FAKE_REQUEST_LOG': log.path,
      'ZOMMI_FAKE_PI_SESSIONS': jsonEncode({
        a: '/sessions/legacy-a.jsonl',
        b: '/sessions/legacy-b.jsonl',
        bad: '/sessions/wrong.jsonl',
      }),
      'ZOMMI_FAKE_PI_WRONG_FILE': '/sessions/wrong.jsonl',
    };
    ProcessCoreBridge create() => ProcessCoreBridge(
      executablePath: File(
        '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
      ).absolute.path,
      environment: environment,
    );
    final first = create();
    addTearDown(first.close);
    await first.initialize();
    final targets = await first.discoverRuntimeTargets();
    final target = targets.targets.firstWhere(
      (t) => t.adapterId == 'pi-rpc' && t.executionHost['kind'] == 'native',
    );
    expect(
      (await first.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: a,
        cwd: directory.path,
      )).sessionId,
      a,
    );
    expect(
      (await first.openSession(
        runtimeTargetId: target.id,
        sessionId: b,
        cwd: directory.path,
      )).sessionId,
      b,
    );
    await first.close();
    final second = create();
    addTearDown(second.close);
    await second.initialize();
    await second.discoverRuntimeTargets();
    // The previous active binding is B; it must not supply B's file for A.
    expect(
      (await second.connectRuntime(
        runtimeTargetId: target.id,
        preferredSessionId: a,
        cwd: directory.path,
      )).sessionId,
      a,
    );
    expect(
      (await second.openSession(
        runtimeTargetId: target.id,
        sessionId: b,
      )).sessionId,
      b,
    );
    await expectLater(
      second.openSession(
        runtimeTargetId: target.id,
        sessionId: bad,
        cwd: directory.path,
      ),
      throwsA(isA<CoreProtocolException>()),
    );
    // A mismatched switch restores the exact previous native selection.
    expect(
      (await second.readSession(
        runtimeTargetId: target.id,
        sessionId: b,
      ))['thread'],
      containsPair('id', b),
    );
    await expectLater(
      second.openSession(
        runtimeTargetId: target.id,
        sessionId: '01a0ab45-843c-76b9-84fe-000000000000',
        cwd: directory.path,
      ),
      throwsA(isA<CoreProtocolException>()),
    );
    final requests = (await log.readAsLines())
        .map(jsonDecode)
        .cast<Map>()
        .toList();
    final startups = requests
        .where((r) => r.containsKey('startupSession'))
        .toList();
    expect(startups.take(3).map((r) => r['startupArgs']), [
      ['--session', a],
      ['--session', b],
      ['--session', '/sessions/legacy-a.jsonl'],
    ]);
    expect(startups.every((r) => r['cwd'] == directory.path), isTrue);
    expect(
      requests.where(
        (r) => ['prompt', 'new_session', 'fork'].contains(r['type']),
      ),
      isEmpty,
    );
  });
}
