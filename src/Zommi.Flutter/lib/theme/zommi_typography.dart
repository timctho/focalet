import 'package:flutter/material.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';

// Codex follows the host UI font stack. Segoe UI gives the Windows build the
// same native text rhythm instead of bundling the heavier Geist face.
const String codexUiFontFamily = 'Segoe UI';
const List<String> codexUiFontFallback = [
  'Segoe UI Variable Text',
  'SF Pro Text',
  'Helvetica Neue',
  'Ubuntu Sans',
  'Noto Sans',
  'Arial',
];

const double topBarAndChatFontSize = 12;
const double userMessageFontSize = topBarAndChatFontSize;
const double assistantMessageFontSize = topBarAndChatFontSize;
const double chatCodeFontSize = topBarAndChatFontSize;
const double compactChatCodeFontSize = topBarAndChatFontSize;

const TextStyle topBarAndChatTextStyle = TextStyle(
  fontFamily: codexUiFontFamily,
  fontFamilyFallback: codexUiFontFallback,
  fontSize: topBarAndChatFontSize,
  fontWeight: FontWeight.w500,
  height: 1.35,
);

double chatFontSizeOf(BuildContext context) =>
    Theme.of(context).extension<ZommiVisualSettings>()?.chatFontSize ??
    topBarAndChatFontSize;

TextStyle chatTextStyleOf(BuildContext context) => topBarAndChatTextStyle
    .copyWith(fontSize: chatFontSizeOf(context), fontWeight: FontWeight.w400);
