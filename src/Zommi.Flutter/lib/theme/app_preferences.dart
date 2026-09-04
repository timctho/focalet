import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

enum ZommiThemeColor {
  violet('violet', 'Violet', Color(0xff8178c9)),
  ocean('ocean', 'Ocean', Color(0xff387da8)),
  forest('forest', 'Forest', Color(0xff468267)),
  ember('ember', 'Ember', Color(0xffb26a4b));

  const ZommiThemeColor(this.id, this.label, this.seed);

  final String id;
  final String label;
  final Color seed;

  static ZommiThemeColor fromId(String? id) => values.firstWhere(
    (value) => value.id == id,
    orElse: () => ZommiThemeColor.violet,
  );
}

@immutable
final class AppPreferences {
  const AppPreferences({
    this.chatFontSize = 13,
    this.themeColor = ZommiThemeColor.violet,
    this.largeWindow = false,
  });

  final double chatFontSize;
  final ZommiThemeColor themeColor;
  final bool largeWindow;

  AppPreferences copyWith({
    double? chatFontSize,
    ZommiThemeColor? themeColor,
    bool? largeWindow,
  }) => AppPreferences(
    chatFontSize: chatFontSize ?? this.chatFontSize,
    themeColor: themeColor ?? this.themeColor,
    largeWindow: largeWindow ?? this.largeWindow,
  );

  Map<String, Object?> toJson() => {
    'chatFontSize': chatFontSize,
    'themeColor': themeColor.id,
    'largeWindow': largeWindow,
  };

  static AppPreferences fromJson(Map<String, Object?> value) {
    final rawFontSize = value['chatFontSize'];
    final fontSize = rawFontSize is num ? rawFontSize.toDouble() : 13.0;
    return AppPreferences(
      chatFontSize: fontSize.clamp(12, 15).toDouble(),
      themeColor: ZommiThemeColor.fromId(value['themeColor']?.toString()),
      largeWindow: value['largeWindow'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.chatFontSize == chatFontSize &&
      other.themeColor == themeColor &&
      other.largeWindow == largeWindow;

  @override
  int get hashCode => Object.hash(chatFontSize, themeColor, largeWindow);
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
      if (!await file.exists()) return const AppPreferences();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const AppPreferences();
      return AppPreferences.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return const AppPreferences();
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
