import 'package:flutter/services.dart';

/// Recall starts only in an empty composer. Editing a recalled message exits
/// navigation so arrow keys continue to work normally in multiline drafts.
final class MessageHistoryNavigation {
  List<String>? _entries;
  int _index = -1;
  String? _recalled;
  TextEditingValue _draft = TextEditingValue.empty;

  void reset() {
    _entries = null;
    _index = -1;
    _recalled = null;
  }

  void textChanged(String text) {
    if (_entries != null && text != _recalled) reset();
  }

  TextEditingValue? navigate({
    required bool older,
    required TextEditingValue value,
    required List<String> history,
  }) {
    if (value.composing.isValid && !value.composing.isCollapsed) return null;
    if (_entries == null) {
      if (!older || value.text.isNotEmpty || history.isEmpty) return null;
      _entries = List.of(history);
      _draft = value;
    }
    final next = _index + (older ? 1 : -1);
    if (next >= _entries!.length) return value;
    if (next < 0) {
      final draft = _draft;
      reset();
      return draft;
    }
    _index = next;
    _recalled = _entries![next];
    return TextEditingValue(
      text: _recalled!,
      selection: TextSelection.collapsed(offset: _recalled!.length),
    );
  }
}
