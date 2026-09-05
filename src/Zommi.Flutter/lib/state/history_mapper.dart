import 'package:zommi_flutter/state/zommi_models.dart';

List<ConversationTurn> mapThreadHistory(Map<String, Object?> response) {
  final thread = mapValue(response['thread']);
  final turns = mapList(thread['turns']);
  return [
    for (var index = 0; index < turns.length; index++)
      _mapTurn(turns[index], index + 1, thread['cwd']?.toString()),
  ];
}

ConversationTurn _mapTurn(
  Map<String, Object?> turn,
  int number,
  String? threadCwd,
) {
  final items = mapList(turn['items']);
  final userItem = items.cast<Map<String, Object?>?>().firstWhere(
    (item) => item?['type'] == 'userMessage',
    orElse: () => null,
  );
  final userText = userItem == null ? 'Continue' : _userItemText(userItem);
  final result = ConversationTurn(
    id: turn['id']?.toString() ?? 'history-turn-$number',
    number: number,
    userText: userText.isEmpty ? 'Continue' : userText,
  );
  for (final item in items) {
    final block = _historyBlock(item, threadCwd);
    if (block != null) result.blocks.add(block);
  }
  final normalized = normalizeTranscriptBlocks(result.blocks);
  result.blocks
    ..clear()
    ..addAll(normalized);
  return result;
}

TranscriptBlock? _historyBlock(Map<String, Object?> item, String? cwd) {
  final type = item['type']?.toString() ?? '';
  if (type == 'userMessage') return null;
  final status = item['status']?.toString();
  final completed =
      status == null ||
      status.isEmpty ||
      {
        'completed',
        'failed',
        'declined',
        'interrupted',
        'cancelled',
        'done',
      }.contains(status.toLowerCase());
  final lifecycle = completed
      ? TranscriptLifecycle.completed
      : TranscriptLifecycle.delta;
  final id = item['id']?.toString() ?? '$type-${item.hashCode}';
  final artifacts = artifactsFromItem(item, cwd: cwd);
  switch (type) {
    case 'agentMessage':
      final phase = item['phase']?.toString();
      return TranscriptBlock(
        id: id,
        kind: phase == 'commentary'
            ? TranscriptKind.thinking
            : TranscriptKind.assistant,
        title: phase == 'commentary' ? 'Thinking' : 'Agent',
        text: item['text']?.toString() ?? '',
        lifecycle: lifecycle,
        status: status,
        expanded: false,
        artifacts: artifacts,
      );
    case 'reasoning':
      return TranscriptBlock(
        id: id,
        kind: TranscriptKind.thinking,
        title: 'Thinking',
        text: mergeDistinctTextSections([
          ..._stringList(item['summary']),
          ..._stringList(item['content']),
        ]),
        lifecycle: lifecycle,
        status: status,
        expanded: false,
        artifacts: artifacts,
      );
    case 'plan':
      return TranscriptBlock(
        id: id,
        kind: TranscriptKind.plan,
        title: 'Plan',
        text: item['text']?.toString() ?? '',
        lifecycle: lifecycle,
        status: status,
        expanded: false,
        artifacts: artifacts,
      );
    case 'commandExecution':
      return _toolBlock(
        id,
        'Command',
        [item['aggregatedOutput']],
        lifecycle,
        status,
        artifacts,
        preview: item['command']?.toString() ?? '',
      );
    case 'fileChange':
      final changes = mapList(item['changes'])
          .map(
            (change) => [
              change['kind']?.toString() ?? '',
              change['path']?.toString() ?? '',
            ].where((part) => part.isNotEmpty).join(' · '),
          )
          .where((line) => line.isNotEmpty)
          .join('\n');
      return _toolBlock(
        id,
        'File change',
        [changes],
        lifecycle,
        status,
        artifacts,
      );
    case 'mcpToolCall':
      return _toolBlock(
        id,
        'MCP tool',
        [item['server'], item['tool']],
        lifecycle,
        status,
        artifacts,
      );
    case 'dynamicToolCall':
      return _toolBlock(
        id,
        'Tool',
        [item['namespace'], item['tool']],
        lifecycle,
        status,
        artifacts,
      );
    case 'webSearch':
      return _toolBlock(
        id,
        'Web search',
        [item['query']],
        lifecycle,
        status,
        artifacts,
      );
    case 'imageView':
      return _toolBlock(
        id,
        'View image',
        [item['path']],
        lifecycle,
        status,
        artifacts,
      );
    case 'imageGeneration':
      return _toolBlock(
        id,
        'Image generation',
        [item['revisedPrompt'], item['savedPath']],
        lifecycle,
        status,
        artifacts,
      );
    case 'contextCompaction':
      return _toolBlock(
        id,
        'Context',
        ['Conversation compacted'],
        lifecycle,
        status,
        artifacts,
      );
    default:
      return null;
  }
}

TranscriptBlock _toolBlock(
  String id,
  String title,
  List<Object?> values,
  TranscriptLifecycle lifecycle,
  String? status,
  List<ArtifactPreview> artifacts, {
  String preview = '',
}) => TranscriptBlock(
  id: id,
  kind: TranscriptKind.tool,
  title: title,
  text: values
      .map((value) => value?.toString() ?? '')
      .where((value) => value.isNotEmpty)
      .join('\n'),
  lifecycle: lifecycle,
  status: status,
  preview: preview,
  expanded: false,
  artifacts: artifacts,
);

List<ArtifactPreview> artifactsFromItem(
  Map<String, Object?> item, {
  String? cwd,
}) {
  final artifacts = <ArtifactPreview>[];
  void add(Map<String, Object?> json) {
    final normalized = <String, Object?>{...json, 'cwd': ?cwd};
    final artifact = ArtifactPreview.fromJson(normalized);
    if ((artifact.path == null || artifact.path!.isEmpty) &&
        (artifact.dataUrl == null || artifact.dataUrl!.isEmpty) &&
        (artifact.html == null || artifact.html!.isEmpty)) {
      return;
    }
    if (artifacts.any((existing) => existing.identity == artifact.identity)) {
      return;
    }
    artifacts.add(artifact);
  }

  for (final artifact in mapList(item['artifacts'])) {
    add(artifact);
  }
  final type = item['type']?.toString();
  if (type == 'imageGeneration' && item['failure'] == null) {
    final path = _pathText(item['savedPath']);
    final dataUrl = _imageDataUrl(item['result']);
    if (dataUrl != null || path.isNotEmpty) {
      add({
        'id': '${item['id'] ?? 'image-generation'}:image',
        'kind': 'image',
        'title': 'Generated image',
        'dataUrl': ?dataUrl,
        if (path.isNotEmpty) 'path': path,
      });
    }
  }
  if (type == 'fileChange' &&
      !RegExp(
        'failed|declined|cancelled',
        caseSensitive: false,
      ).hasMatch(item['status']?.toString() ?? '')) {
    for (final change in mapList(item['changes'])) {
      if (RegExp(
        'delete|remove',
        caseSensitive: false,
      ).hasMatch(change['kind']?.toString() ?? '')) {
        continue;
      }
      final path = _pathText(change['path']);
      final kind = artifactKindFromPath(path);
      if (kind != null) {
        add({
          'id': '${item['id'] ?? 'file-change'}:$path',
          'kind': kind,
          'title': kind == 'html' ? 'HTML preview' : 'Generated image',
          'path': path,
        });
      }
    }
  }
  if (type == 'agentMessage') {
    for (final artifact in artifactsFromText(
      item['text']?.toString() ?? '',
      cwd: cwd,
    )) {
      if (!artifacts.any(
        (existing) => existing.identity == artifact.identity,
      )) {
        artifacts.add(artifact);
      }
    }
  }
  return artifacts;
}

List<ArtifactPreview> artifactsFromText(String value, {String? cwd}) {
  final artifacts = <ArtifactPreview>[];
  void addPath(String path, [String title = '']) {
    final dataUrl = _imageDataUrl(path);
    final kind = dataUrl == null ? artifactKindFromPath(path) : 'image';
    if (kind == null ||
        (RegExp('^https?:', caseSensitive: false).hasMatch(path) &&
            dataUrl == null)) {
      return;
    }
    final artifact = ArtifactPreview(
      id: 'message:$path',
      kind: kind,
      title: title.isEmpty
          ? (kind == 'html' ? 'HTML preview' : 'Generated image')
          : title,
      path: dataUrl == null ? path : null,
      dataUrl: dataUrl,
      cwd: cwd,
    );
    if (!artifacts.any((existing) => existing.identity == artifact.identity)) {
      artifacts.add(artifact);
    }
  }

  final markdown = RegExp(
    r'''(!?)\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+["'][^"']*["'])?\s*\)''',
  );
  for (final match in markdown.allMatches(value)) {
    addPath(match.group(3) ?? match.group(4) ?? '', match.group(2) ?? '');
  }
  final barePath = RegExp(
    r'''(?:^|[\s("'`])((?:file:///[^\s"'<>]+|[a-z]:[\\/][^\s"'<>]+|/[^\s"'<>]+)\.(?:png|jpe?g|gif|webp|bmp|svg|html?))(?=$|[\s),.;])''',
    caseSensitive: false,
  );
  for (final match in barePath.allMatches(value)) {
    addPath(match.group(1) ?? '');
  }
  return artifacts;
}

String? artifactKindFromPath(String value) {
  final clean = value.split(RegExp(r'[?#]')).first.toLowerCase();
  if (RegExp(r'\.(png|jpe?g|gif|webp|bmp|svg)$').hasMatch(clean)) {
    return 'image';
  }
  if (RegExp(r'\.html?$').hasMatch(clean)) return 'html';
  return null;
}

String mergeActivityText(
  String current,
  String incoming,
  TranscriptKind kind,
  TranscriptLifecycle lifecycle, {
  bool replace = false,
  bool append = false,
}) {
  if (replace) return incoming;
  if (append) return '$current$incoming';
  if (incoming.isEmpty) return current;
  if (current.isEmpty) return incoming;
  if (incoming == current || current.endsWith(incoming)) return current;
  if (incoming.startsWith(current)) return incoming;
  if (lifecycle == TranscriptLifecycle.completed &&
      (kind == TranscriptKind.thinking || kind == TranscriptKind.plan)) {
    if (incoming == current || current.contains(incoming)) return current;
    if (incoming.contains(current)) return incoming;
    return incoming;
  }
  if (lifecycle == TranscriptLifecycle.completed &&
      current.contains(incoming)) {
    return current;
  }
  if (lifecycle == TranscriptLifecycle.completed &&
      incoming.contains(current)) {
    return incoming;
  }
  final overlap = suffixPrefixOverlap(current, incoming);
  if (overlap > 0) return '$current${incoming.substring(overlap)}';
  final separator =
      lifecycle == TranscriptLifecycle.completed &&
          current.isNotEmpty &&
          !current.endsWith('\n')
      ? '\n'
      : '';
  return '$current$separator$incoming';
}

int suffixPrefixOverlap(String current, String incoming) {
  final limit = current.length < incoming.length
      ? current.length
      : incoming.length;
  if (limit == 0) return 0;
  final prefixes = List<int>.filled(limit, 0);
  var matched = 0;
  for (var index = 1; index < limit; index++) {
    while (matched > 0 &&
        incoming.codeUnitAt(index) != incoming.codeUnitAt(matched)) {
      matched = prefixes[matched - 1];
    }
    if (incoming.codeUnitAt(index) == incoming.codeUnitAt(matched)) matched++;
    prefixes[index] = matched;
  }
  matched = 0;
  for (var index = current.length - limit; index < current.length; index++) {
    while (matched > 0 &&
        current.codeUnitAt(index) != incoming.codeUnitAt(matched)) {
      matched = prefixes[matched - 1];
    }
    if (current.codeUnitAt(index) == incoming.codeUnitAt(matched)) matched++;
  }
  return matched;
}

String mergeDistinctTextSections(Iterable<String> sections) {
  final values = <String>[];
  for (final section in sections) {
    final value = section.trim();
    if (value.isEmpty ||
        values.any(
          (existing) => existing == value || existing.contains(value),
        )) {
      continue;
    }
    values.removeWhere(value.contains);
    values.add(value);
  }
  return values.join('\n');
}

bool transcriptTextSnapshotsOverlap(String first, String second) {
  final left = first.trim();
  final right = second.trim();
  if (left.isEmpty || right.isEmpty) return false;
  return left == right || left.startsWith(right) || right.startsWith(left);
}

List<TranscriptBlock> normalizeTranscriptBlocks(
  Iterable<TranscriptBlock> source,
) {
  final result = <TranscriptBlock>[];
  final indexes = <(TranscriptKind, String), int>{};
  for (final block in source) {
    final identity = (block.kind, block.id);
    final duplicateIndex = indexes[identity];
    if (duplicateIndex != null) {
      result[duplicateIndex] = mergeTranscriptBlocks(
        result[duplicateIndex],
        block,
      );
      continue;
    }
    if (block.kind == TranscriptKind.thinking &&
        result.isNotEmpty &&
        result.last.kind == TranscriptKind.thinking &&
        result.last.text.trim().isNotEmpty &&
        result.last.text.trim() == block.text.trim()) {
      indexes[identity] = result.length - 1;
      result[result.length - 1] = mergeTranscriptBlocks(result.last, block);
      continue;
    }
    indexes[identity] = result.length;
    result.add(block);
  }
  return result;
}

TranscriptBlock mergeTranscriptBlocks(
  TranscriptBlock primary,
  TranscriptBlock secondary,
) {
  final text = transcriptTextSnapshotsOverlap(primary.text, secondary.text)
      ? (secondary.text.trim().length >= primary.text.trim().length
            ? secondary.text
            : primary.text)
      : mergeActivityText(
          primary.text,
          secondary.text,
          primary.kind,
          secondary.lifecycle,
        );
  final artifacts = List<ArtifactPreview>.of(primary.artifacts);
  for (final artifact in secondary.artifacts) {
    if (!artifacts.any((existing) => existing.identity == artifact.identity)) {
      artifacts.add(artifact);
    }
  }
  return TranscriptBlock(
    id: primary.id,
    sourceId: primary.sourceId,
    kind: primary.kind,
    title: primary.title.isEmpty ? secondary.title : primary.title,
    text: text,
    lifecycle: primary.completed || secondary.completed
        ? TranscriptLifecycle.completed
        : secondary.lifecycle,
    status: secondary.status ?? primary.status,
    preview: primary.preview.isEmpty ? secondary.preview : primary.preview,
    expanded: primary.expanded,
    artifacts: artifacts,
  );
}

String _userItemText(Map<String, Object?> item) {
  final content = mapList(item['content'])
      .where((entry) => entry['type'] == 'text')
      .map((entry) => entry['text']?.toString() ?? '')
      .where((text) => text.isNotEmpty)
      .join('\n');
  return displayUserText(content);
}

List<String> _stringList(Object? value) => (value as List<Object?>? ?? const [])
    .map((entry) {
      if (entry is String) return entry;
      final map = mapValue(entry);
      return map['text']?.toString() ?? entry.toString();
    })
    .toList(growable: false);

String _pathText(Object? value) {
  if (value is String) return value;
  final map = mapValue(value);
  return map['path']?.toString() ?? map['value']?.toString() ?? '';
}

String? _imageDataUrl(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (RegExp(
    r'^data:image/[a-z0-9.+-]+(?:;[a-z0-9=.+-]+)*;base64,[a-z0-9+/=\s]+$',
    caseSensitive: false,
  ).hasMatch(text)) {
    return text;
  }
  return null;
}
