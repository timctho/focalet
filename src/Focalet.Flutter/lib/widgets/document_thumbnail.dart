import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:focalet_flutter/desktop/document_thumbnail.dart';
import 'package:focalet_flutter/state/focalet_models.dart';

class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({required this.artifact, super.key});

  final ArtifactPreview artifact;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  DocumentThumbnailRequest? _request;
  late Future<Uint8List> _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DocumentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artifact.html != widget.artifact.html ||
        oldWidget.artifact.fileUri != widget.artifact.fileUri) {
      _load();
    }
  }

  void _load() {
    _request?.cancel();
    _request = DocumentThumbnailRequest(widget.artifact);
    _image = _request!.render();
  }

  @override
  void dispose() {
    _request?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _image,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton.icon(
            onPressed: () => setState(_load),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry preview'),
          ),
        );
      }
      if (snapshot.data case final bytes?) {
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          semanticLabel: widget.artifact.title,
        );
      }
      return const Center(child: CircularProgressIndicator());
    },
  );
}
