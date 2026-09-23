import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// Ubuntu's maintained WebKitGTK engine, hosted in the existing GTK window.
abstract final class LinuxDocumentRenderer {
  static const channel = MethodChannel('zommi/linux_document');
  static int _nextId = 0;
  static final _events = <int, void Function(Map<Object?, Object?>)>{};
  static bool _listening = false;

  static int register(void Function(Map<Object?, Object?>) callback) {
    if (!_listening) {
      channel.setMethodCallHandler((call) async {
        final arguments = call.arguments;
        if (call.method == 'event' && arguments is Map) {
          _events[arguments['id']]?.call(arguments);
        }
      });
      _listening = true;
    }
    final id = ++_nextId;
    _events[id] = callback;
    return id;
  }

  static Future<void> close(int id) async {
    _events.remove(id);
    await channel.invokeMethod<void>('close', {'id': id});
  }

  static Future<Object?> evaluate(int id, String source) async {
    final json = await channel.invokeMethod<String>('evaluate', {
      'id': id,
      'source': source,
    });
    return json == null ? null : jsonDecode(json);
  }

  static Future<void> suspend(bool value) =>
      channel.invokeMethod<void>('suspend', {'value': value});

  static Future<Uint8List> thumbnail(Uri uri) async {
    final bytes = await channel
        .invokeMethod<Uint8List>('thumbnail', {
          'uri': uri.toString(),
          'width': 1280,
          'height': 720,
        })
        .timeout(const Duration(seconds: 20));
    if (bytes == null || bytes.isEmpty) {
      throw StateError('The document renderer produced no preview.');
    }
    return bytes;
  }
}
