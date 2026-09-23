import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_paths.dart';
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
        'Only image, HTML and Markdown files can be previewed.',
      );
    }
    if (target?.executionHost['kind'] == 'remote') {
      throw StateError('Remote runtime files cannot be previewed locally.');
    }
    final resolved = _resolve(sourcePath, artifact.cwd, target);
    final file = File.fromUri(resolved.replace(fragment: '', query: ''));
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
    if (artifact.kind == 'html' || artifact.kind == 'markdown') {
      return artifact.copyWith(
        html: utf8.decode(bytes, allowMalformed: true),
        fileUri: resolved,
      );
    }
    return artifact.copyWith(
      dataUrl: 'data:${_mimeType(sourcePath)};base64,${base64Encode(bytes)}',
    );
  }

  Uri _resolve(String sourcePath, String? artifactCwd, RuntimeTarget? target) {
    final host = target?.executionHost ?? const <String, Object?>{};
    return resolveArtifactFileUri(
      sourcePath,
      cwd: artifactCwd?.trim().isNotEmpty == true
          ? artifactCwd!.trim()
          : target?.runtimeHome?.trim().isNotEmpty == true
          ? target!.runtimeHome!.trim()
          : Directory.current.path,
      windows: Platform.isWindows,
      runtimeDistribution: host['kind'] == 'wsl'
          ? host['name']?.toString()
          : null,
      localDistribution: Platform.environment['WSL_DISTRO_NAME'],
    );
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
