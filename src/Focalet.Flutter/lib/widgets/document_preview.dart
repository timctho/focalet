import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:focalet_flutter/desktop/document_environment.dart';
import 'package:focalet_flutter/desktop/document_server.dart';
import 'package:focalet_flutter/diagnostics/document_preview_probe.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/linux_document_surface.dart';

/// A full browser surface inside the existing floating artifact panel.
class DocumentPreview extends StatefulWidget {
  const DocumentPreview({required this.artifact, this.onDismiss, super.key});
  final ArtifactPreview artifact;
  final VoidCallback? onDismiss;
  @override
  State<DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<DocumentPreview> {
  DocumentServer? _server;
  WebViewEnvironment? _environment;
  Timer? _timeout;
  String? _error;
  bool _ready = false;
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final attempt = ++_attempt;
    _timeout?.cancel();
    final previous = _server;
    setState(() {
      _server = null;
      _error = null;
      _ready = false;
    });
    _timeout = Timer(const Duration(seconds: 20), () {
      if (attempt != _attempt) return;
      _attempt++;
      _fail('Document loading timed out. Retry to open it again.');
    });
    await previous?.close();
    try {
      _environment = defaultTargetPlatform == TargetPlatform.linux
          ? null
          : await documentEnvironment();
      final server = await DocumentServer.start(
        content: widget.artifact.html!,
        fileUri: widget.artifact.fileUri,
        isMarkdown: widget.artifact.kind == 'markdown',
      );
      if (!mounted || attempt != _attempt) {
        await server.close();
        return;
      }
      setState(() => _server = server);
    } on Object catch (error) {
      if (mounted && attempt == _attempt) _fail('$error');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    _timeout?.cancel();
    final server = _server;
    setState(() {
      _error = message;
      _server = null;
    });
    if (server != null) unawaited(server.close());
    unawaited(recordDocumentPreviewFailure(widget.artifact, message));
  }

  @override
  void dispose() {
    _attempt++;
    _timeout?.cancel();
    final server = _server;
    if (server != null) unawaited(server.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.description_outlined, size: 32),
              const SizedBox(height: 12),
              Text(error, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _prepare,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final server = _server;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (server != null && defaultTargetPlatform == TargetPlatform.linux)
          LinuxDocumentSurface(
            key: ValueKey(_attempt),
            uri: server.uri,
            onDismiss: widget.onDismiss,
            onLoaded: (evaluate) {
              if (!mounted || _server != server) return;
              _timeout?.cancel();
              setState(() => _ready = true);
              unawaited(recordDocumentPreview(widget.artifact, evaluate));
            },
            onError: (message) {
              if (_server == server) _fail(message);
            },
          ),
        if (server != null && defaultTargetPlatform != TargetPlatform.linux)
          InAppWebView(
            key: ValueKey(_attempt),
            webViewEnvironment: _environment,
            initialUrlRequest: URLRequest(url: WebUri(server.uri.toString())),
            initialSettings: documentBrowserSettings(),
            shouldOverrideUrlLoading: (_, action) async =>
                server.allowsNavigation(action.request.url?.toString() ?? '')
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL,
            onCreateWindow: (_, action) async => false,
            onPermissionRequest: (_, request) async => PermissionResponse(
              resources: request.resources,
              action: PermissionResponseAction.DENY,
            ),
            onLoadStop: (controller, url) async {
              if (!mounted ||
                  _server != server ||
                  !server.allowsNavigation(url?.toString() ?? '')) {
                return;
              }
              _timeout?.cancel();
              setState(() => _ready = true);
              await recordDocumentPreview(
                widget.artifact,
                (source) => controller.evaluateJavascript(source: source),
              );
            },
            onReceivedError: (_, request, error) {
              if (_server == server && request.isForMainFrame == true) {
                _fail('Could not load this document. ${error.description}');
              }
            },
            onReceivedHttpError: (_, request, response) {
              if (_server == server && request.isForMainFrame == true) {
                _fail('This document is no longer available.');
              }
            },
            onWebContentProcessDidTerminate: (_) {
              if (_server == server) {
                _fail('Document renderer stopped. Retry to recover.');
              }
            },
            onRenderProcessGone: (_, detail) {
              if (_server == server) {
                _fail('Document renderer stopped. Retry to recover.');
              }
            },
          ),
        if (!_ready) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
