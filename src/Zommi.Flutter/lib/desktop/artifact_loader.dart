import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

abstract interface class ArtifactLoader {
  Future<ArtifactPreview> load(
    ArtifactPreview artifact, {
    RuntimeTarget? target,
  });
}

final class LocalArtifactLoader implements ArtifactLoader {
  const LocalArtifactLoader();

  static const int maximumImageBytes = 25 * 1024 * 1024;
  static const int maximumHtmlBytes = 5 * 1024 * 1024;

  @override
  Future<ArtifactPreview> load(
    ArtifactPreview artifact, {
    RuntimeTarget? target,
  }) async {
    if (artifact.dataUrl?.isNotEmpty == true || artifact.html != null) {
      return artifact;
    }
    final sourcePath = artifact.path?.trim() ?? '';
    if (sourcePath.isEmpty || sourcePath.length > 4096) {
      throw const FormatException('Artifact path is invalid.');
    }
    final expectedKind = artifactKindFromPath(sourcePath);
    if (expectedKind == null || expectedKind != artifact.kind) {
      throw const FormatException(
        'Only generated image and HTML files can be previewed.',
      );
    }
    if (target?.executionHost['kind'] == 'remote') {
      throw StateError('Remote runtime files cannot be previewed locally.');
    }
    final resolved = _resolve(sourcePath, artifact.cwd, target);
    final file = File(resolved);
    final metadata = await file.stat();
    if (metadata.type != FileSystemEntityType.file) {
      throw StateError('Artifact preview requires a regular file.');
    }
    final maximum = artifact.kind == 'image'
        ? maximumImageBytes
        : maximumHtmlBytes;
    if (metadata.size > maximum) {
      throw StateError(
        'Artifact preview exceeds ${maximum ~/ 1024 ~/ 1024} MB.',
      );
    }
    final bytes = await file.readAsBytes();
    if (artifact.kind == 'html') {
      return artifact.copyWith(html: utf8.decode(bytes, allowMalformed: true));
    }
    return artifact.copyWith(
      dataUrl: 'data:${_mimeType(sourcePath)};base64,${base64Encode(bytes)}',
    );
  }

  String _resolve(
    String sourcePath,
    String? artifactCwd,
    RuntimeTarget? target,
  ) {
    var value = sourcePath;
    if (value.toLowerCase().startsWith('file:')) {
      value = Uri.parse(value).toFilePath(windows: Platform.isWindows);
    } else if (RegExp('^[a-z]+:', caseSensitive: false).hasMatch(value) &&
        !RegExp(r'^[a-z]:[\\/]', caseSensitive: false).hasMatch(value)) {
      throw const FormatException(
        'Remote artifact URLs are not available as local previews.',
      );
    }
    final host = target?.executionHost ?? const <String, Object?>{};
    final base = artifactCwd?.trim().isNotEmpty == true
        ? artifactCwd!.trim()
        : target?.runtimeHome?.trim().isNotEmpty == true
        ? target!.runtimeHome!.trim()
        : Directory.current.path;
    if (Platform.isWindows && host['kind'] == 'wsl') {
      final distribution = host['name']?.toString() ?? '';
      if (!RegExp(
        r'^[a-z0-9._-]+$',
        caseSensitive: false,
      ).hasMatch(distribution)) {
        throw const FormatException('WSL artifact host is invalid.');
      }
      final linuxPath = value.startsWith('/')
          ? _normalizeLinux(value)
          : _normalizeLinux('$base/$value');
      return r'\\wsl.localhost\' +
          distribution +
          r'\' +
          linuxPath.substring(1).replaceAll('/', r'\');
    }
    if (_isAbsolute(value)) return File(value).absolute.path;
    return File('$base${Platform.pathSeparator}$value').absolute.path;
  }

  bool _isAbsolute(String value) =>
      value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[a-z]:[\\/]', caseSensitive: false).hasMatch(value);

  String _normalizeLinux(String value) {
    final parts = <String>[];
    for (final part in value.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return '/${parts.join('/')}';
  }

  String _mimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.svg')) return 'image/svg+xml';
    return 'image/png';
  }
}
