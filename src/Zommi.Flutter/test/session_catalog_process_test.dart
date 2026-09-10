import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

void main() {
  for (final (foreground, cancel) in [
    ('codex', false),
    ('hermes', false),
    ('codex', true),
  ]) {
    test(
      cancel
          ? 'closing cancels a slow background catalog and its runtime'
          : 'cold catalog keeps $foreground active without creating background chats',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'zommi-catalog-',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final python = await _findPython();
        final log = File('${temporary.path}/requests.jsonl');
        final binding = File('${temporary.path}/binding.json');
        final bridge = ProcessCoreBridge(
          executablePath: File(
            '../../target/debug/zommi-core-host${Platform.isWindows ? '.exe' : ''}',
          ).absolute.path,
          environment: {
            'ZOMMI_CODEX_COMMAND': python,
            'ZOMMI_CODEX_ARGS_JSON': jsonEncode([
              File(
                '../../crates/zommi-core-host/tests/fake_codex_app_server.py',
              ).absolute.path,
            ]),
            'ZOMMI_HERMES_COMMAND': python,
            'ZOMMI_HERMES_GATEWAY_ARGS_JSON': jsonEncode([
              File('../../crates/zommi-core-host/tests/fake_gateway_runtime.py')
                  .absolute
                  .path,
              '--mode',
              'hermes',
            ]),
            'ZOMMI_CORE_STATE_PATH': binding.path,
            'ZOMMI_RUNTIME_OVERRIDES_PATH': '${temporary.path}/overrides.json',
            'ZOMMI_FAKE_REQUEST_LOG': log.path,
            if (foreground == 'codex')
              'ZOMMI_FAKE_CATALOG_DELAY': cancel ? '30' : '3',
          },
        );
        addTearDown(bridge.close);
        await bridge.initialize();
        final discovery = await bridge.discoverRuntimeTargets();
        final codex = discovery.targets.firstWhere(
          (target) => target.adapterId == 'codex-app-server',
        );
        final hermes = discovery.targets.firstWhere(
          (target) => target.adapterId == 'hermes-gateway',
        );
        final primary = foreground == 'codex' ? codex : hermes;
        final background = foreground == 'codex' ? hermes : codex;
        await bridge.connectRuntime(runtimeTargetId: primary.id);
        final originalBinding = await binding.readAsString();
        final initialRequests = (await log.readAsLines()).length;
        final listing = bridge.listSessionCatalog(
          runtimeTargetId: background.id,
        );
        if (foreground == 'codex') {
          await _waitForRequest(log, 'http.sessions');
          if (cancel) {
            final completion = expectLater(
              listing,
              throwsA(isA<CoreProtocolException>()),
            );
            final requests = (await log.readAsLines()).map(
              (line) => jsonDecode(line) as Map,
            );
            final gatewayPid = requests.firstWhere(
              (request) => request['method'] == 'http.sessions',
            )['pid'];
            await bridge.close().timeout(const Duration(seconds: 5));
            await completion;
            expect(await binding.readAsString(), originalBinding);
            if (Platform.isLinux) {
              final process = Directory('/proc/$gatewayPid');
              final deadline = DateTime.now().add(const Duration(seconds: 3));
              while (await process.exists() &&
                  DateTime.now().isBefore(deadline)) {
                await Future<void>.delayed(const Duration(milliseconds: 30));
              }
              expect(
                await process.exists(),
                isFalse,
                reason: 'Catalog gateway must exit with its listing host',
              );
            }
            return;
          }

          // The Hermes fixture is still waiting. Foreground requests must use
          // another host queue rather than waiting for that slow provider.
          final handoff = await bridge
              .buildContextHandoff(message: 'Foreground still usable')
              .timeout(const Duration(seconds: 2));
          expect(handoff, contains('Foreground still usable'));
        }
        final sessions = await listing.timeout(const Duration(seconds: 30));
        expect(sessions, isNotEmpty);
        if (foreground == 'codex') {
          expect(
            sessions.map((session) => session['id']),
            contains('hermes-stored-session'),
          );
        }
        expect(await binding.readAsString(), originalBinding);
        final requests = (await log.readAsLines())
            .skip(initialRequests)
            .map((line) => jsonDecode(line) as Map)
            .toList();
        expect(
          requests.where(
            (request) => [
              'session.create',
              'session.resume',
              'prompt.submit',
              'thread/start',
              'thread/resume',
              'turn/start',
            ].contains(request['method']),
          ),
          isEmpty,
        );
        final selected = await bridge.discoverRuntimeTargets();
        expect(selected.selectedTargetId, primary.id);
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}

Future<void> _waitForRequest(File log, String method) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if ((await log.readAsLines()).any((line) {
      try {
        return (jsonDecode(line) as Map)['method'] == method;
      } on FormatException {
        return false;
      }
    })) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  throw StateError('The catalog did not reach $method');
}

Future<String> _findPython() async {
  for (final candidate in ['python3', 'python']) {
    try {
      if ((await Process.run(candidate, ['--version'])).exitCode == 0) {
        return candidate;
      }
    } on ProcessException {
      /* Try the other standard Python name. */
    }
  }
  throw StateError('Python is required for runtime fixtures.');
}
