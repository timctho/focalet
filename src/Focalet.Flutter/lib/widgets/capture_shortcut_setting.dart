import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:focalet_flutter/desktop/capture_shortcut.dart';

class CaptureShortcutSetting extends StatelessWidget {
  const CaptureShortcutSetting({
    required this.settings,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final CaptureShortcutSettings settings;
  final CaptureShortcut value;
  final ValueChanged<CaptureShortcut> onChanged;

  Future<void> _edit(BuildContext context) async {
    try {
      await settings.suspendSelectionShortcut();
      if (!context.mounted) return;
      final shortcut = await showDialog<CaptureShortcut>(
        context: context,
        builder: (_) => _ShortcutDialog(settings: settings, value: value),
      );
      if (shortcut != null) onChanged(shortcut);
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not change shortcut: $error')),
        );
      }
    } finally {
      await settings.resumeSelectionShortcut();
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: Row(
      children: [
        const Expanded(
          child: Text(
            'Select content shortcut',
            style: TextStyle(fontSize: 11.5),
          ),
        ),
        if (settings.canCustomizeSelectionShortcut)
          OutlinedButton(
            key: const ValueKey('selection-shortcut-setting'),
            onPressed: () => _edit(context),
            child: Text(value.label, style: const TextStyle(fontSize: 11)),
          )
        else
          const Text('System settings', style: TextStyle(fontSize: 11)),
      ],
    ),
  );
}

class _ShortcutDialog extends StatefulWidget {
  const _ShortcutDialog({required this.settings, required this.value});
  final CaptureShortcutSettings settings;
  final CaptureShortcut value;
  @override
  State<_ShortcutDialog> createState() => _ShortcutDialogState();
}

class _ShortcutDialogState extends State<_ShortcutDialog> {
  late CaptureShortcut _value = widget.value;
  final _focus = FocusNode();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.settings.configureSelectionShortcut(_value);
      if (mounted) Navigator.pop(context, _value);
    } on Object {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'That shortcut is unavailable. Try another combination.';
        });
      }
      _focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Select content shortcut'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              Theme.of(context).platform == TargetPlatform.macOS
                  ? 'Press Control (⌃), Option (⌥) or Command (⌘) with a letter, number or F1–F12.'
                  : 'Press Ctrl, Alt or Meta with a letter, number or F1–F12.',
            ),
            const SizedBox(height: 16),
            Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: (_, event) {
                if (_saving ||
                    event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.tab) {
                  return KeyEventResult.ignored;
                }
                if (event is KeyDownEvent) {
                  final value = CaptureShortcut.fromEvent(event);
                  if (value != null) {
                    setState(() {
                      _value = value;
                      _error = null;
                    });
                  }
                }
                return KeyEventResult.handled;
              },
              child: GestureDetector(
                onTap: _focus.requestFocus,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                  ),
                  child: Text(
                    _value.label,
                    key: const ValueKey('shortcut-recording'),
                  ),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() {
                  _value = CaptureShortcut.standard;
                  _error = null;
                }),
          child: Text('Reset to ${CaptureShortcut.standard.label}'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}
