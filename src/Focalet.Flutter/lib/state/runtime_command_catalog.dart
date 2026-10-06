import 'package:flutter/services.dart';

class ComposerCommand {
  const ComposerCommand(
    this.text,
    this.description, {
    this.inputHint = '',
    this.disabledReason,
    this.native = true,
  });

  factory ComposerCommand.fromJson(Map<String, Object?> value) =>
      ComposerCommand(
        '/${value['name']}',
        value['description']?.toString() ?? '',
        inputHint: value['inputHint']?.toString() ?? '',
        disabledReason: value['disabledReason']?.toString(),
        native: false,
      );

  final String text;
  final String description;
  final String inputHint;
  final String? disabledReason;
  final bool native;
  bool get enabled => disabledReason == null;
  String get completion =>
      text == '/goal' || inputHint.isNotEmpty ? '$text ' : text;
  ComposerCommand disabled(String reason) => ComposerCommand(
    text,
    description,
    inputHint: inputHint,
    disabledReason: reason,
    native: native,
  );
}

const codexComposerCommands = [
  ComposerCommand('/clear', 'Start a fresh chat and keep the previous history'),
  ComposerCommand('/goal', 'Set an objective, or view the current goal'),
  ComposerCommand('/new', 'Start a fresh chat'),
  ComposerCommand('/status', 'Show session, context usage and account limits'),
  ComposerCommand('/help', 'Show supported commands'),
  ComposerCommand('/goal pause', 'Pause work toward the goal'),
  ComposerCommand('/goal resume', 'Continue work toward the goal'),
  ComposerCommand('/goal edit', 'Edit the current objective'),
  ComposerCommand('/goal clear', 'Remove the goal from this chat'),
];

List<ComposerCommand> matchingCommands(
  String text,
  List<ComposerCommand> commands,
) {
  final query = text.trimLeft();
  if (!query.startsWith('/') || query.contains('\n')) return const [];
  return commands
      .where(
        (command) =>
            command.text.startsWith(query) &&
            (!command.text.contains(' ') ||
                query.startsWith(command.text.split(' ').first)),
      )
      .toList(growable: false);
}

TextRange commandEmphasis(String text, List<ComposerCommand> commands) {
  final query = text.trimLeft();
  final matching =
      commands
          .where(
            (command) =>
                query == command.text || query.startsWith('${command.text} '),
          )
          .toList()
        ..sort((a, b) => b.text.length.compareTo(a.text.length));
  if (matching.isEmpty) return TextRange.empty;
  return TextRange(
    start: text.length - query.length,
    end: text.length - query.length + matching.first.text.length,
  );
}
