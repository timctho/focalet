import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zommi_flutter/desktop/capture_shortcut.dart';

enum WindowSizeSetting { standard, wide, maximized }

enum ZommiThemeColor {
  ocean('ocean', 'Ocean', Color(0xff387da8)),
  mist('mist', 'Macaron grey', Color(0xffb4b8c1)),
  cream('cream', 'Macaron cream', Color(0xffe8dcc9)),
  custom('custom', 'Custom color', Color(0xff8178c9));

  const ZommiThemeColor(this.id, this.label, this.seed);

  final String id;
  final String label;
  final Color seed;

  static ZommiThemeColor fromId(String? id) => values.firstWhere(
    (value) => value.id == id,
    orElse: () => ZommiThemeColor.ocean,
  );
}

@immutable
final class AppPreferences {
  const AppPreferences({
    this.chatFontSize = 14,
    this.browserPageDetails = true,
    this.themeColor = ZommiThemeColor.ocean,
    this.themeMode = ThemeMode.system,
    this.customThemeColor = const Color(0xff8178c9),
    this.windowSize = WindowSizeSetting.standard,
    this.runtimeSetupCompleted = true,
    this.selectionShortcut = CaptureShortcut.standard,
  });

  final bool browserPageDetails;
  final double chatFontSize;
  final ZommiThemeColor themeColor;
  final ThemeMode themeMode;
  final Color customThemeColor;

  Color get seedColor =>
      themeColor == ZommiThemeColor.custom ? customThemeColor : themeColor.seed;
  final WindowSizeSetting windowSize;
  final bool runtimeSetupCompleted;
  final CaptureShortcut selectionShortcut;

  AppPreferences copyWith({
    bool? browserPageDetails,
    double? chatFontSize,
    ZommiThemeColor? themeColor,
    ThemeMode? themeMode,
    Color? customThemeColor,
    WindowSizeSetting? windowSize,
    bool? runtimeSetupCompleted,
    CaptureShortcut? selectionShortcut,
  }) => AppPreferences(
    browserPageDetails: browserPageDetails ?? this.browserPageDetails,
    chatFontSize: chatFontSize ?? this.chatFontSize,
    themeColor: themeColor ?? this.themeColor,
    themeMode: themeMode ?? this.themeMode,
    customThemeColor: customThemeColor ?? this.customThemeColor,
    windowSize: windowSize ?? this.windowSize,
    runtimeSetupCompleted: runtimeSetupCompleted ?? this.runtimeSetupCompleted,
    selectionShortcut: selectionShortcut ?? this.selectionShortcut,
  );

  Map<String, Object?> toJson() => {
    'browserPageDetails': browserPageDetails,
    'chatFontSize': chatFontSize,
    'themeColor': themeColor.id,
    'themeMode': themeMode.name,
    'customThemeColor': customThemeColor.toARGB32(),
    'windowSize': windowSize.name,
    'runtimeSetupCompleted': runtimeSetupCompleted,
    'selectionShortcut': selectionShortcut.toJson(),
  };

  static AppPreferences fromJson(Map<String, Object?> value) {
    final rawFontSize = value['chatFontSize'];
    final fontSize = rawFontSize is num ? rawFontSize.toDouble() : 14.0;
    return AppPreferences(
      selectionShortcut: CaptureShortcut.fromJson(value['selectionShortcut']),
      // Settings written before the welcome flow belong to an existing install.
      runtimeSetupCompleted:
          !value.containsKey('runtimeSetupCompleted') ||
          value['runtimeSetupCompleted'] == true,
      browserPageDetails: value['browserPageDetails'] != false,
      // The retired Medium preset follows Default on existing installs.
      chatFontSize: fontSize == 13 ? 14 : fontSize.clamp(12, 17).toDouble(),
      themeColor:
          const ['violet', 'forest', 'ember'].contains(value['themeColor'])
          ? ZommiThemeColor.custom
          : ZommiThemeColor.fromId(value['themeColor']?.toString()),
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == value['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      customThemeColor: Color(switch (value['customThemeColor']) {
        final int color when color >= 0 && color <= 0xffffffff =>
          color | 0xff000000,
        _ => switch (value['themeColor']) {
          'forest' => 0xff468267,
          'ember' => 0xffb26a4b,
          _ => 0xff8178c9,
        },
      }),
      windowSize: WindowSizeSetting.values.firstWhere(
        (setting) => setting.name == value['windowSize'],
        orElse: () => value['largeWindow'] == true
            ? WindowSizeSetting.wide
            : WindowSizeSetting.standard,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.browserPageDetails == browserPageDetails &&
      other.chatFontSize == chatFontSize &&
      other.themeColor == themeColor &&
      other.themeMode == themeMode &&
      other.customThemeColor == customThemeColor &&
      other.windowSize == windowSize &&
      other.runtimeSetupCompleted == runtimeSetupCompleted &&
      other.selectionShortcut == selectionShortcut;

  @override
  int get hashCode => Object.hash(
    browserPageDetails,
    chatFontSize,
    themeColor,
    themeMode,
    customThemeColor,
    windowSize,
    runtimeSetupCompleted,
    selectionShortcut,
  );
}

abstract interface class AppPreferencesStore {
  Future<AppPreferences> load();

  Future<void> save(AppPreferences preferences);
}

final class NoopAppPreferencesStore implements AppPreferencesStore {
  const NoopAppPreferencesStore();

  @override
  Future<AppPreferences> load() async => const AppPreferences();

  @override
  Future<void> save(AppPreferences preferences) async {}
}

final class FileAppPreferencesStore implements AppPreferencesStore {
  FileAppPreferencesStore(this.path);

  factory FileAppPreferencesStore.platform() =>
      FileAppPreferencesStore(defaultAppPreferencesPath());

  final String path;

  @override
  Future<AppPreferences> load() async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return const AppPreferences(runtimeSetupCompleted: false);
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return const AppPreferences(runtimeSetupCompleted: false);
      }
      return AppPreferences.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return const AppPreferences(runtimeSetupCompleted: false);
    }
  }

  @override
  Future<void> save(AppPreferences preferences) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(preferences.toJson()), flush: true);
  }
}

String defaultAppPreferencesPath({
  String? operatingSystem,
  Map<String, String>? environment,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final env = environment ?? Platform.environment;
  if (os == 'windows') {
    final base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '.';
    return '$base\\Zommi\\settings.json';
  }
  if (os == 'macos') {
    final home = env['HOME'] ?? '.';
    return '$home/Library/Application Support/Zommi/settings.json';
  }
  final base = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
  return '$base/zommi/settings.json';
}

@immutable
final class ZommiVisualSettings extends ThemeExtension<ZommiVisualSettings> {
  const ZommiVisualSettings({
    required this.chatFontSize,
    required this.themeColor,
  });

  final double chatFontSize;
  final ZommiThemeColor themeColor;

  @override
  ZommiVisualSettings copyWith({
    double? chatFontSize,
    ZommiThemeColor? themeColor,
  }) => ZommiVisualSettings(
    chatFontSize: chatFontSize ?? this.chatFontSize,
    themeColor: themeColor ?? this.themeColor,
  );

  @override
  ZommiVisualSettings lerp(
    covariant ThemeExtension<ZommiVisualSettings>? other,
    double t,
  ) {
    if (other is! ZommiVisualSettings) return this;
    return ZommiVisualSettings(
      chatFontSize: lerpDouble(chatFontSize, other.chatFontSize, t),
      themeColor: t < 0.5 ? themeColor : other.themeColor,
    );
  }
}

double lerpDouble(double first, double second, double t) =>
    first + (second - first) * t;
