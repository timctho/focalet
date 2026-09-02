import 'package:flutter/material.dart';

const String codexUiFontFamily = 'packages/fossui/Geist';
const List<String> codexUiFontFallback = [
  'Geist',
  'Segoe UI Variable Text',
  'Segoe UI',
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
  height: 1.35,
);
