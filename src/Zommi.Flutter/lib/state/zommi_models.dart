import 'dart:convert';

enum SessionPresence { active, running, unread, done }

enum TranscriptKind {
  assistant,
  commentary,
  thinking,
  plan,
  tool,
  error;

  bool get isMessage => this == assistant || this == commentary;
  bool get isFoldedActivity => this == thinking || this == tool;
}

enum TranscriptLifecycle { started, delta, completed }

final class ContextAttachment {
  ContextAttachment({
    required this.id,
    required this.token,
    this.snapshot,
    this.previewText = '',
    this.imageDataUrl,
    this.bounds,
  });

  final String id;
  final String token;
  final Map<String, Object?>? snapshot;
  final String previewText;
  final String? imageDataUrl;
  final Map<String, Object?>? bounds;

  bool get hasImage => imageDataUrl?.isNotEmpty == true;

  String get reference => token.replaceAll(RegExp(r'[\[\]]'), '');

  String get sourceTitle =>
      snapshot?['windowTitle']?.toString() ??
      snapshot?['application']?.toString() ??
      'Selected content';

  String get excerpt {
    final selection = snapshot?['selection'];
    if (selection is List && selection.isNotEmpty) {
      return _compactExcerpt(
        selection.map((value) => value.toString()).join(' '),
      );
    }
    final dom = snapshot?['dom'];
    final elements = dom is Map ? dom['elements'] : null;
    final selected = snapshot?['selectionElements'];
    final tree = snapshot?['accessibilityTree'];
    final spatial = snapshot?['spatialContext'];
    final cells = spatial is Map ? spatial['cells'] : null;
    String? location;
    if (cells is List && cells.isNotEmpty && cells.first is Map) {
      final cell = cells.first as Map;
      final headers = cell['columnHeaders'];
      final column = headers is List ? headers.join(' / ') : '';
      final row = cell['dataRowNumber'];
      if (column.isNotEmpty) {
        location = row is num ? '$column · row $row' : column;
      }
    }
    String? firstText(Object? items) {
      if (items is! List) return null;
      for (final item in items.whereType<Map>()) {
        for (final key in ['text', 'value', 'name', 'label', 'href']) {
          final value = item[key]?.toString().trim();
          if (value != null && value.isNotEmpty) return value;
        }
        final child = firstText(item['children']);
        if (child != null) return child;
      }
      return null;
    }

    return _compactExcerpt(
      firstText(elements) ??
          firstText(selected) ??
          firstText(tree is Map ? tree['roots'] : null) ??
          location ??
          (hasImage ? 'Selected image' : sourceTitle),
    );
  }

  static String _compactExcerpt(String value) {
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }

  ContextAttachment withToken(String value) => ContextAttachment(
    id: id,
    token: value,
    snapshot: snapshot,
    previewText: previewText,
    imageDataUrl: imageDataUrl,
    bounds: bounds,
  );
}

List<Map<String, Object?>> contextHandoffSnapshots(
  List<ContextAttachment> attachments,
) {
  var imageIndex = 0;
  final snapshots = <Map<String, Object?>>[];
  for (final attachment in attachments) {
    if (attachment.hasImage) imageIndex++;
    snapshots.add({
      ...?attachment.snapshot,
      if (attachment.reference.isNotEmpty) 'contextLabel': attachment.reference,
      if (attachment.hasImage) 'imageIndex': imageIndex,
    });
  }
  return snapshots;
}

final class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.runtimeTargetId,
    this.cwd,
    this.profile,
    this.updatedAt,
  });

  factory SessionSummary.fromJson(
    Map<String, Object?> json, {
    required String runtimeTargetId,
  }) {
    final source = _firstText(json, const ['name', 'preview', 'title']);
    return SessionSummary(
      id: json['id']?.toString() ?? json['sessionId']?.toString() ?? '',
      runtimeTargetId: runtimeTargetId,
      title: compactSessionTitle(source),
      cwd: json['cwd']?.toString(),
      profile: json['profile']?.toString(),
      updatedAt: (json['updatedAt'] ?? json['createdAt'])?.toString(),
    );
  }

  final String id;
  final String runtimeTargetId;
  final String title;
  final String? cwd;
  final String? profile;
  final String? updatedAt;

  DateTime? get activityTime {
    final value = updatedAt;
    if (value == null) return null;
    final epoch = num.tryParse(value);
    if (epoch == null) return DateTime.tryParse(value)?.toUtc();
    // Codex and Hermes use Unix seconds; gateway runtimes may use milliseconds.
    final milliseconds = epoch.abs() < 100000000000 ? epoch * 1000 : epoch;
    if (!milliseconds.isFinite || milliseconds.abs() > 8640000000000000) {
      return null;
    }
    return DateTime.fromMillisecondsSinceEpoch(
      milliseconds.round(),
      isUtc: true,
    );
  }

  SessionSummary copyWith({
    String? title,
    String? cwd,
    String? profile,
    String? updatedAt,
  }) => SessionSummary(
    id: id,
    runtimeTargetId: runtimeTargetId,
    title: title ?? this.title,
    cwd: cwd ?? this.cwd,
    profile: profile ?? this.profile,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

final class SessionSettings {
  const SessionSettings({
    this.workspace = '',
    this.model = '',
    this.effort = '',
    this.profile = '',
  });

  final String workspace;
  final String model;
  final String effort;
  final String profile;

  SessionSettings copyWith({
    String? workspace,
    String? model,
    String? effort,
    String? profile,
  }) => SessionSettings(
    workspace: workspace ?? this.workspace,
    model: model ?? this.model,
    effort: effort ?? this.effort,
    profile: profile ?? this.profile,
  );
}

final class ArtifactPreview {
  const ArtifactPreview({
    required this.id,
    required this.kind,
    required this.title,
    this.path,
    this.cwd,
    this.dataUrl,
    this.html,
  });

  factory ArtifactPreview.fromJson(Map<String, Object?> json) =>
      ArtifactPreview(
        id:
            json['id']?.toString() ??
            json['path']?.toString() ??
            'artifact-${json.hashCode}',
        kind: json['kind']?.toString() ?? 'image',
        title:
            json['title']?.toString() ??
            (json['kind'] == 'html' ? 'HTML preview' : 'Generated image'),
        path: json['path']?.toString(),
        cwd: json['cwd']?.toString(),
        dataUrl: json['dataUrl']?.toString(),
        html: json['html']?.toString(),
      );

  final String id;
  final String kind;
  final String title;
  final String? path;
  final String? cwd;
  final String? dataUrl;
  final String? html;

  String get identity => path ?? dataUrl ?? id;

  ArtifactPreview copyWith({String? dataUrl, String? html}) => ArtifactPreview(
    id: id,
    kind: kind,
    title: title,
    path: path,
    cwd: cwd,
    dataUrl: dataUrl ?? this.dataUrl,
    html: html ?? this.html,
  );
}

final class TranscriptBlock {
  TranscriptBlock({
    required this.id,
    required this.kind,
    required this.title,
    String? sourceId,
    this.text = '',
    this.lifecycle = TranscriptLifecycle.delta,
    this.status,
    this.preview = '',
    this.expanded = true,
    List<ArtifactPreview> artifacts = const [],
  }) : sourceId = sourceId ?? id,
       artifacts = List<ArtifactPreview>.of(artifacts);

  final String id;
  final String sourceId;
  final TranscriptKind kind;
  String title;
  String text;
  TranscriptLifecycle lifecycle;
  String? status;
  String preview;
  bool expanded;
  final List<ArtifactPreview> artifacts;

  bool get isActivity => !kind.isMessage;
  bool get completed => lifecycle == TranscriptLifecycle.completed;
}

final class ConversationTurn {
  ConversationTurn({
    required this.id,
    required this.userText,
    String? inlineUserText,
    this.number = 0,
    this.activityExpanded = false,
    Map<String, bool> activityGroupExpansion = const {},
    List<String> contextTokens = const [],
    List<ContextAttachment> attachments = const [],
    List<TranscriptBlock> blocks = const [],
  }) : inlineUserText = inlineUserText ?? userText,
       activityGroupExpansion = Map.of(activityGroupExpansion),
       contextTokens = List<String>.of(contextTokens),
       attachments = List<ContextAttachment>.of(attachments),
       blocks = List<TranscriptBlock>.of(blocks);

  final String id;
  final int number;
  final String userText;
  final String inlineUserText;
  bool activityExpanded;
  final Map<String, bool> activityGroupExpansion;
  bool get hasExpandedActivity =>
      activityExpanded || activityGroupExpansion.containsValue(true);
  bool isActivityGroupExpanded(String id) =>
      activityGroupExpansion[id] ?? activityExpanded;
  final List<String> contextTokens;
  final List<ContextAttachment> attachments;
  final List<TranscriptBlock> blocks;

  TranscriptBlock? block(String id) {
    for (final value in blocks) {
      if (value.id == id) return value;
    }
    return null;
  }
}

final class PendingApproval {
  const PendingApproval({
    required this.id,
    required this.runtimeTargetId,
    required this.sessionId,
    required this.title,
    required this.detail,
    required this.options,
  });

  factory PendingApproval.fromEvent(
    String runtimeTargetId,
    String sessionId,
    Map<String, Object?> payload,
  ) {
    final toolCall = mapValue(payload['toolCall']);
    final raw = toolCall['rawInput'];
    return PendingApproval(
      id: payload['approvalId']?.toString() ?? '',
      runtimeTargetId: runtimeTargetId,
      sessionId: sessionId,
      title: toolCall['title']?.toString() ?? 'Agent requests permission',
      detail: raw is String
          ? raw
          : raw == null
          ? ''
          : const JsonEncoder.withIndent('  ').convert(raw),
      options: mapList(payload['options'])
          .map(ApprovalOption.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String runtimeTargetId;
  final String sessionId;
  final String title;
  final String detail;
  final List<ApprovalOption> options;
}

final class ApprovalOption {
  const ApprovalOption({
    required this.id,
    required this.label,
    required this.kind,
  });

  factory ApprovalOption.fromJson(Map<String, Object?> json) => ApprovalOption(
    id: json['optionId']?.toString() ?? '',
    label:
        json['name']?.toString() ??
        json['label']?.toString() ??
        json['optionId']?.toString() ??
        'Allow',
    kind: json['kind']?.toString() ?? 'allow_once',
  );

  final String id;
  final String label;
  final String kind;

  bool get isReject => kind.toLowerCase().contains('reject');
}

final class PendingQuestion {
  const PendingQuestion({
    required this.id,
    required this.runtimeTargetId,
    required this.sessionId,
    required this.title,
    required this.message,
    required this.method,
    required this.options,
    required this.questions,
    this.placeholder = '',
    this.prefill = '',
    this.sensitive = false,
  });

  factory PendingQuestion.fromEvent(
    String runtimeTargetId,
    String sessionId,
    Map<String, Object?> payload,
  ) => PendingQuestion(
    id: payload['questionId']?.toString() ?? '',
    runtimeTargetId: runtimeTargetId,
    sessionId: sessionId,
    title: payload['title']?.toString() ?? 'Agent asks a question',
    message: payload['message']?.toString() ?? '',
    method: payload['method']?.toString() ?? 'input',
    options: (payload['options'] as List<Object?>? ?? const [])
        .map(QuestionOption.fromValue)
        .toList(growable: false),
    questions: mapList(payload['questions'])
        .map(StructuredQuestion.fromJson)
        .toList(growable: false),
    placeholder: payload['placeholder']?.toString() ?? '',
    prefill: payload['prefill']?.toString() ?? '',
    sensitive: payload['sensitive'] == true,
  );

  final String id;
  final String runtimeTargetId;
  final String sessionId;
  final String title;
  final String message;
  final String method;
  final List<QuestionOption> options;
  final List<StructuredQuestion> questions;
  final String placeholder;
  final String prefill;
  final bool sensitive;
}

final class StructuredQuestion {
  const StructuredQuestion({
    required this.id,
    required this.header,
    required this.question,
    required this.options,
    required this.multiSelect,
    required this.allowOther,
    required this.secret,
  });

  factory StructuredQuestion.fromJson(Map<String, Object?> json) =>
      StructuredQuestion(
        id: json['questionId']?.toString() ?? '',
        header: json['header']?.toString() ?? 'Question',
        question: json['question']?.toString() ?? '',
        options: (json['options'] as List<Object?>? ?? const [])
            .map(QuestionOption.fromValue)
            .toList(growable: false),
        multiSelect: json['multiSelect'] == true,
        allowOther: json['isOther'] == true,
        secret: json['isSecret'] == true,
      );

  final String id;
  final String header;
  final String question;
  final List<QuestionOption> options;
  final bool multiSelect;
  final bool allowOther;
  final bool secret;
}

final class QuestionOption {
  const QuestionOption({required this.value, required this.label, this.detail});

  factory QuestionOption.fromValue(Object? value) {
    if (value is String) {
      return QuestionOption(value: value, label: value);
    }
    final json = mapValue(value);
    final optionValue =
        json['value']?.toString() ?? json['label']?.toString() ?? '';
    return QuestionOption(
      value: optionValue,
      label: json['label']?.toString() ?? optionValue,
      detail: json['description']?.toString(),
    );
  }

  final String value;
  final String label;
  final String? detail;
}

String compactSessionTitle(String value) {
  final match = RegExp(
    r'<user_message>\s*([\s\S]*?)\s*</user_message>',
    caseSensitive: false,
  ).firstMatch(value);
  final normalized = (match?.group(1) ?? value)
      .replaceFirst(RegExp(r'^Zommi\s*·\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final title = normalized.isEmpty ? 'New chat' : normalized;
  return title.length <= 42 ? title : '${title.substring(0, 41)}…';
}

String displayUserText(String value) {
  final match = RegExp(
    r'<user_message>\s*([\s\S]*?)\s*</user_message>',
    caseSensitive: false,
  ).firstMatch(value);
  return (match?.group(1) ?? value).trim();
}

Map<String, Object?> mapValue(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, Object?>{};
}

List<Map<String, Object?>> mapList(Object? value) =>
    (value as List<Object?>? ?? const []).map(mapValue).toList(growable: false);

String _firstText(Map<String, Object?> json, List<String> keys) {
  for (final key in keys) {
    final value = json[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return 'New chat';
}
