import 'package:flutter/services.dart';

class CodexComposerCommand {
  const CodexComposerCommand(this.text, this.description);

  final String text;
  final String description;
  String get completion => text == '/goal' ? '/goal ' : text;
}

const codexComposerCommands = [
  CodexComposerCommand(
    '/clear',
    'Start a fresh chat and keep the previous history',
  ),
  CodexComposerCommand('/goal', 'Set an objective, or view the current goal'),
  CodexComposerCommand('/new', 'Start a fresh chat'),
  CodexComposerCommand('/help', 'Show supported commands'),
  CodexComposerCommand('/goal pause', 'Pause work toward the goal'),
  CodexComposerCommand('/goal resume', 'Continue work toward the goal'),
  CodexComposerCommand('/goal edit', 'Edit the current objective'),
  CodexComposerCommand('/goal clear', 'Remove the goal from this chat'),
];

List<CodexComposerCommand> matchingCodexCommands(String text) {
  final query = text.trimLeft();
  if (!query.startsWith('/') || query.contains('\n')) return const [];
  return codexComposerCommands
      .where(
        (command) =>
            command.text.startsWith(query) &&
            (query.startsWith('/goal') || !command.text.contains(' ')),
      )
      .toList(growable: false);
}

TextRange codexCommandEmphasis(String text) {
  final match = RegExp(r'^\s*(/(?:clear|new|goal|help))(?=\s|$)')
      .firstMatch(text);
  if (match == null) return TextRange.empty;
  return TextRange(start: match.end - match.group(1)!.length, end: match.end);
}
