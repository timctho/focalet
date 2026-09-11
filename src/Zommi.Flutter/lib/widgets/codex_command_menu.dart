import 'package:flutter/material.dart';
import 'package:zommi_flutter/state/codex_command_catalog.dart';

class CodexCommandMenu extends StatefulWidget {
  const CodexCommandMenu({
    required this.commands,
    required this.selectedIndex,
    required this.onSelected,
    super.key,
  });

  final List<CodexComposerCommand> commands;
  final int selectedIndex;
  final ValueChanged<CodexComposerCommand> onSelected;

  @override
  State<CodexCommandMenu> createState() => _CodexCommandMenuState();
}

class _CodexCommandMenuState extends State<CodexCommandMenu> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(CodexCommandMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final top = widget.selectedIndex * 48.0;
      final bottom = top + 48;
      final position = _scroll.position;
      if (top < position.pixels) {
        _scroll.jumpTo(top.clamp(0, position.maxScrollExtent));
      } else if (bottom > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(
          (bottom - position.viewportDimension).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 4, 22, 2),
    child: Material(
      elevation: 5,
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.builder(
          controller: _scroll,
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemExtent: 48,
          itemCount: widget.commands.length,
          itemBuilder: (context, index) {
            final command = widget.commands[index];
            final selected = index == widget.selectedIndex;
            return Semantics(
              selected: selected,
              button: true,
              child: InkWell(
                key: ValueKey('codex-command-${command.text}'),
                canRequestFocus: false,
                onTap: () => widget.onSelected(command),
                child: ColoredBox(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                            .withValues(alpha: 0.09)
                      : Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 128,
                          child: Text(
                            command.text,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            command.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (selected)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: Icon(Icons.keyboard_tab_rounded, size: 16),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}
