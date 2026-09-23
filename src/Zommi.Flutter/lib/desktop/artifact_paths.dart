import 'package:path/path.dart' as paths;

/// Preserve link fragments while translating runtime paths to local files.
Uri resolveArtifactFileUri(
  String source, {
  required String cwd,
  required bool windows,
  String? runtimeDistribution,
  String? localDistribution,
}) {
  final context = paths.Context(
    style: windows ? paths.Style.windows : paths.Style.posix,
  );
  var value = source.trim();
  var fragment = '';
  final drivePath = RegExp(r'^[a-z]:[\\/]', caseSensitive: false);
  if (!drivePath.hasMatch(value)) {
    final uri = Uri.parse(value);
    fragment = uri.fragment;
    if (uri.scheme == 'file') {
      final file = uri.replace(fragment: '', query: '');
      if (!windows && file.host.isNotEmpty && file.host != 'localhost') {
        final parts = file.pathSegments;
        if (!const {
              'wsl.localhost',
              r'wsl$',
            }.contains(file.host.toLowerCase()) ||
            parts.isEmpty ||
            parts.first.toLowerCase() != localDistribution?.toLowerCase()) {
          throw const FormatException('This file belongs to another computer.');
        }
        value = '/${parts.skip(1).join('/')}';
      } else {
        value = file.toFilePath(windows: windows);
      }
    } else if (uri.hasScheme) {
      throw const FormatException('Only local documents can be previewed.');
    } else {
      value = Uri.decodeComponent(uri.path);
    }
  } else {
    final separator = value.indexOf('#');
    if (separator >= 0) {
      fragment = value.substring(separator + 1);
      value = value.substring(0, separator);
    }
  }
  // An explicit drive or UNC URI is already resolved; do not prepend WSL twice.
  if (windows &&
      !drivePath.hasMatch(value) &&
      !value.startsWith(r'\\') &&
      runtimeDistribution != null) {
    if (!RegExp(
      r'^[a-z0-9._-]+$',
      caseSensitive: false,
    ).hasMatch(runtimeDistribution)) {
      throw const FormatException('WSL distribution is invalid.');
    }
    final linux = paths.posix.normalize(
      value.startsWith('/') ? value : paths.posix.join(cwd, value),
    );
    value =
        r'\\wsl.localhost\' + runtimeDistribution + linux.replaceAll('/', r'\');
  } else if (!context.isAbsolute(value)) {
    value = context.join(cwd, value);
  }
  return Uri.file(
    context.normalize(value),
    windows: windows,
  ).replace(fragment: fragment.isEmpty ? null : fragment);
}
