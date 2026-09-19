part of 'zommi_controller.dart';

List<ComposerCommand> _parseRuntimeCommands(Object? value) {
  final commands = <ComposerCommand>[];
  for (final item in mapList(value)) {
    final command = ComposerCommand.fromJson(item);
    commands.add(command);
    for (final subcommand
        in (item['subcommands'] as List<Object?>? ?? const [])) {
      if (subcommand is String && subcommand.isNotEmpty) {
        commands.add(
          ComposerCommand(
            '${command.text} $subcommand',
            command.description,
            native: false,
            disabledReason: command.disabledReason,
          ),
        );
      }
    }
  }
  return commands;
}

extension RuntimeCommands on ZommiController {
  List<ComposerCommand> get composerCommands {
    final commands = <ComposerCommand>[
      if (activeRuntime?.adapterId == 'codex-app-server')
        ...codexComposerCommands,
      ...?_commandCatalogs[_activeSessionKey],
    ];
    return commands
        .map((command) {
          if (!command.enabled) return command;
          if (sessionReadOnly &&
              !(command.native &&
                  const ['/status', '/help'].contains(command.text))) {
            return command.disabled('This chat is open elsewhere.');
          }
          if (!command.native && (turnActive || submitting)) {
            return command.disabled('Available when this chat is idle.');
          }
          return command;
        })
        .toList(growable: false);
  }

  ComposerCommand? commandFor(String text) {
    final query = text.trim();
    final matches =
        composerCommands
            .where(
              (command) =>
                  query == command.text ||
                  query.startsWith('${command.text} ') ||
                  query.startsWith('${command.text}\n'),
            )
            .toList()
          ..sort((a, b) => b.text.length.compareTo(a.text.length));
    return matches.firstOrNull;
  }

  bool isRuntimeCommand(String text) {
    if (isCodexCommand(text) || commandFor(text) != null) return true;
    if (activeRuntime == null ||
        activeRuntime?.adapterId == 'pty-compatibility') {
      return false;
    }
    return text.trim() == '/' ||
        RegExp(r'^/[^/\s]+(?:\s|$)').hasMatch(text.trim());
  }

  /// Catalog failures are optional: chat remains available and native Codex
  /// controls still work. Push updates take precedence over in-flight reads.
  Future<void> refreshCommands({bool force = false}) async {
    final target = activeRuntime;
    final sessionId = activeSessionId;
    if (_closed ||
        target == null ||
        sessionId == null ||
        core is! RuntimeCommandBridge ||
        target.adapterId == 'pty-compatibility') {
      return;
    }
    final key = ZommiController._sessionKey(target.id, sessionId);
    final context = '$selectedWorkspace\n$selectedProfile';
    if (!force && _commandContexts[key] == context) return;
    final changedContext =
        _commandContexts[key] != null && _commandContexts[key] != context;
    _commandContexts[key] = context;
    if (changedContext) _commandCatalogs.remove(key);
    final revision = _commandRevisions[key] ?? 0;
    final request = (_commandRequests[key] ?? 0) + 1;
    _commandRequests[key] = request;
    try {
      final result = await (core as RuntimeCommandBridge).listCommands(
        runtimeTargetId: target.id,
        sessionId: sessionId,
        force: force || changedContext,
      );
      if (_closed ||
          _commandRequests[key] != request ||
          (_commandRevisions[key] ?? 0) != revision) {
        return;
      }
      _commandCatalogs[key] = _parseRuntimeCommands(result['commands']);
      _commandErrors.remove(key);
    } on Object catch (error) {
      if (_closed ||
          _commandRequests[key] != request ||
          (_commandRevisions[key] ?? 0) != revision) {
        return;
      }
      _commandErrors[key] = 'Command discovery is unavailable · $error';
      _commandContexts.remove(key);
      if (force) _commandCatalogs.remove(key);
    }
    if (!_closed) _notify();
  }
}
