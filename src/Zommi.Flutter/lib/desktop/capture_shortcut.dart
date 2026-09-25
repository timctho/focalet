import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

/// A portable global shortcut: a letter, digit or function key with modifiers.
final class CaptureShortcut {
  const CaptureShortcut({this.usage = 0x70004, this.modifiers = 1});

  final int usage;
  // Win32 modifier bits also give preferences a stable, platform-neutral format.
  final int modifiers;
  static const standard = CaptureShortcut();

  int? get virtualKey => switch (usage) {
    >= 0x70004 && <= 0x7001d => usage - 0x70004 + 65,
    >= 0x7001e && <= 0x70026 => usage - 0x7001e + 49,
    0x70027 => 48,
    >= 0x7003a && <= 0x70045 => usage - 0x7003a + 112,
    _ => null,
  };

  bool get valid =>
      virtualKey != null &&
      modifiers > 0 &&
      modifiers < 16 &&
      (modifiers & 11) != 0;

  String get label => labelForPlatform(defaultTargetPlatform);

  String labelForPlatform(TargetPlatform platform) {
    final mac = platform == TargetPlatform.macOS;
    return [
      if ((modifiers & 2) != 0) mac ? '⌃' : 'Ctrl',
      if ((modifiers & 1) != 0) mac ? '⌥' : 'Alt',
      if ((modifiers & 4) != 0) mac ? '⇧' : 'Shift',
      if ((modifiers & 8) != 0) mac ? '⌘' : 'Meta',
      if (virtualKey case final key?)
        key >= 112 ? 'F${key - 111}' : String.fromCharCode(key),
    ].join(mac ? ' ' : '+');
  }

  HotKey toHotKey() => HotKey(
    key: PhysicalKeyboardKey.findKeyByCode(usage)!,
    modifiers: [
      if ((modifiers & 1) != 0) HotKeyModifier.alt,
      if ((modifiers & 2) != 0) HotKeyModifier.control,
      if ((modifiers & 4) != 0) HotKeyModifier.shift,
      if ((modifiers & 8) != 0) HotKeyModifier.meta,
    ],
    scope: HotKeyScope.system,
  );

  static CaptureShortcut? fromEvent(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final value = CaptureShortcut(
      usage: event.physicalKey.usbHidUsage,
      modifiers:
          (keyboard.isAltPressed ? 1 : 0) |
          (keyboard.isControlPressed ? 2 : 0) |
          (keyboard.isShiftPressed ? 4 : 0) |
          (keyboard.isMetaPressed ? 8 : 0),
    );
    return value.valid ? value : null;
  }

  Map<String, int> toJson() => {'usage': usage, 'modifiers': modifiers};

  static CaptureShortcut fromJson(Object? json) {
    if (json is Map && json['usage'] is int && json['modifiers'] is int) {
      final shortcut = CaptureShortcut(
        usage: json['usage'] as int,
        modifiers: json['modifiers'] as int,
      );
      if (shortcut.valid) return shortcut;
    }
    return standard;
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureShortcut &&
      usage == other.usage &&
      modifiers == other.modifiers;
  @override
  int get hashCode => Object.hash(usage, modifiers);
}

abstract interface class CaptureShortcutSettings {
  bool get canCustomizeSelectionShortcut;
  Future<void> configureSelectionShortcut(CaptureShortcut shortcut);
  Future<void> suspendSelectionShortcut();
  Future<void> resumeSelectionShortcut();
}
