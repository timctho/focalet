import 'dart:async';

import 'package:flutter/material.dart';
import 'package:focalet_flutter/desktop/linux_document_renderer.dart';

class LinuxDocumentSurface extends StatefulWidget {
  const LinuxDocumentSurface({
    required this.uri,
    required this.onLoaded,
    required this.onError,
    this.onDismiss,
    super.key,
  });
  final Uri uri;
  final void Function(Future<Object?> Function(String) evaluate) onLoaded;
  final void Function(String error) onError;
  final VoidCallback? onDismiss;
  @override
  State<LinuxDocumentSurface> createState() => _LinuxDocumentSurfaceState();
}

class _LinuxDocumentSurfaceState extends State<LinuxDocumentSurface>
    with WidgetsBindingObserver {
  final _boundsKey = GlobalKey();
  late final int _id;
  Rect? _lastBounds;
  bool _created = false;
  bool _scheduled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _id = LinuxDocumentRenderer.register((event) {
      if (!mounted) return;
      switch (event['event']) {
        case 'ready':
          widget.onLoaded(
            (source) => LinuxDocumentRenderer.evaluate(_id, source),
          );
        case 'error':
          widget.onError(
            event['message']?.toString() ??
                'Document renderer stopped. Retry to recover.',
          );
        case 'dismiss':
          widget.onDismiss?.call();
      }
    });
  }

  @override
  void didChangeMetrics() => _scheduleBounds();
  void _scheduleBounds() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      final box = _boundsKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || box.size.isEmpty) return;
      final bounds = box.localToGlobal(Offset.zero) & box.size;
      if (_created && bounds == _lastBounds) return;
      final method = _created ? 'bounds' : 'open';
      _created = true;
      _lastBounds = bounds;
      unawaited(
        LinuxDocumentRenderer.channel
            .invokeMethod<void>(method, {
              'id': _id,
              'uri': widget.uri.toString(),
              'x': bounds.left,
              'y': bounds.top,
              'width': bounds.width,
              'height': bounds.height,
            })
            .catchError((Object error) {
              if (mounted) widget.onError('$error');
            }),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(LinuxDocumentRenderer.close(_id).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleBounds();
        return SizedBox.expand(key: _boundsKey);
      },
    );
  }
}
