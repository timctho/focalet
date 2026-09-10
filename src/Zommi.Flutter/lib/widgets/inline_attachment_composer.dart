import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';

const String inlineAttachmentMarker = '\u{fffc}';

typedef AttachmentHoverCallback = void Function(
  ContextAttachment attachment,
  BuildContext anchor,
);

final class InlineAttachmentTextController extends TextEditingController {
  InlineAttachmentTextController({
    required this.onAttachmentRemoved,
    this.onAttachmentEnter,
    this.onAttachmentExit,
    this.onAttachmentAdjust,
  }) {
    _previousText = text;
    addListener(_handleTextChanged);
  }

  final ValueChanged<ContextAttachment> onAttachmentRemoved;
  final AttachmentHoverCallback? onAttachmentEnter;
  final ValueChanged<ContextAttachment>? onAttachmentExit;
  final ValueChanged<ContextAttachment>? onAttachmentAdjust;
  final List<ContextAttachment> _attachments = [];
  late String _previousText;
  bool _mutating = false;

  List<ContextAttachment> get inlineAttachments =>
      List.unmodifiable(_attachments);

  String get messageText =>
      text.replaceAll(RegExp('\\s*$inlineAttachmentMarker\\s*'), ' ').trim();

  String get inlineText => text;

  void syncAttachments(List<ContextAttachment> current) {
    final currentIds = current.map((attachment) => attachment.id).toSet();
    var changed = false;
    _mutating = true;
    try {
      for (var index = _attachments.length - 1; index >= 0; index--) {
        if (currentIds.contains(_attachments[index].id)) continue;
        final offset = _markerOffset(index);
        _attachments.removeAt(index);
        if (offset >= 0) _removeMarkerAt(offset);
        changed = true;
      }
      for (final attachment in current) {
        final existing = _attachments.indexWhere(
          (candidate) => candidate.id == attachment.id,
        );
        if (existing >= 0) {
          if (!identical(_attachments[existing], attachment)) {
            _attachments[existing] = attachment;
            changed = true;
          }
          continue;
        }
        _insertAttachment(attachment);
        changed = true;
      }
      _previousText = text;
    } finally {
      _mutating = false;
    }
    if (changed) notifyListeners();
  }

  void clearAfterSubmit() {
    _mutating = true;
    try {
      _attachments.clear();
      clear();
      _previousText = '';
    } finally {
      _mutating = false;
    }
  }

  void _insertAttachment(ContextAttachment attachment) {
    final offset = selection.extentOffset.clamp(0, text.length);
    final attachmentIndex = _markerCount(text.substring(0, offset));
    _attachments.insert(attachmentIndex, attachment);
    final updated = text.replaceRange(offset, offset, inlineAttachmentMarker);
    value = value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: offset + 1),
      composing: TextRange.empty,
    );
  }

  void _removeMarkerAt(int offset) {
    final updated = text.replaceRange(offset, offset + 1, '');
    int adjust(int value) => value > offset ? value - 1 : value;
    value = value.copyWith(
      text: updated,
      selection: TextSelection(
        baseOffset: adjust(selection.baseOffset).clamp(0, updated.length),
        extentOffset: adjust(selection.extentOffset).clamp(0, updated.length),
      ),
      composing: TextRange.empty,
    );
  }

  int _markerOffset(int attachmentIndex) {
    var seen = 0;
    for (var offset = 0; offset < text.length; offset++) {
      if (text[offset] != inlineAttachmentMarker) continue;
      if (seen == attachmentIndex) return offset;
      seen++;
    }
    return -1;
  }

  void _handleTextChanged() {
    if (_mutating) return;
    final updated = text;
    var prefix = 0;
    while (prefix < _previousText.length &&
        prefix < updated.length &&
        _previousText.codeUnitAt(prefix) == updated.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < _previousText.length - prefix &&
        suffix < updated.length - prefix &&
        _previousText.codeUnitAt(_previousText.length - suffix - 1) ==
            updated.codeUnitAt(updated.length - suffix - 1)) {
      suffix++;
    }
    final removed = _previousText.substring(
      prefix,
      _previousText.length - suffix,
    );
    final removedCount = _markerCount(removed);
    final attachmentIndex = _markerCount(_previousText.substring(0, prefix));
    final removedAttachments = <ContextAttachment>[];
    for (var count = 0; count < removedCount; count++) {
      if (attachmentIndex >= _attachments.length) break;
      removedAttachments.add(_attachments.removeAt(attachmentIndex));
    }
    _previousText = updated;
    for (final attachment in removedAttachments) {
      onAttachmentRemoved(attachment);
    }
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => TextSpan(
    style: style,
    children: inlineAttachmentSpans(
      text: text,
      attachments: _attachments,
      style: style,
      tileBuilder: (attachment) => InlineAttachmentTile(
        key: ValueKey('composer-inline-tile-${attachment.id}'),
        attachment: attachment,
        onDelete: () => onAttachmentRemoved(attachment),
        onAdjust: onAttachmentAdjust == null
            ? null
            : () => onAttachmentAdjust!(attachment),
        onEnter: onAttachmentEnter == null
            ? null
            : (anchor) => onAttachmentEnter!(attachment, anchor),
        onExit: onAttachmentExit == null
            ? null
            : () => onAttachmentExit!(attachment),
      ),
    ),
  );

  @override
  void dispose() {
    removeListener(_handleTextChanged);
    super.dispose();
  }
}

class InlineAttachmentMessage extends StatelessWidget {
  const InlineAttachmentMessage({
    required this.text,
    required this.attachments,
    this.onAttachmentEnter,
    this.onAttachmentExit,
    super.key,
  });

  final String text;
  final List<ContextAttachment> attachments;
  final AttachmentHoverCallback? onAttachmentEnter;
  final ValueChanged<ContextAttachment>? onAttachmentExit;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.copyWith(
      color: const Color(0xff272b38),
      fontSize: chatFontSizeOf(context),
      fontWeight: FontWeight.w500,
      height: 1.35,
      fontFamily: codexUiFontFamily,
      fontFamilyFallback: codexUiFontFallback,
    );
    return SelectionArea(
      child: RichText(
        key: key,
        text: TextSpan(
          style: style,
          children: inlineAttachmentSpans(
            text: text,
            attachments: attachments,
            style: style,
            tileBuilder: (attachment) => InlineAttachmentTile(
              key: ValueKey('sent-inline-tile-${attachment.id}'),
              attachment: attachment,
              onEnter: onAttachmentEnter == null
                  ? null
                  : (anchor) => onAttachmentEnter!(attachment, anchor),
              onExit: onAttachmentExit == null
                  ? null
                  : () => onAttachmentExit!(attachment),
            ),
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> inlineAttachmentSpans({
  required String text,
  required List<ContextAttachment> attachments,
  required TextStyle? style,
  required Widget Function(ContextAttachment attachment) tileBuilder,
}) {
  final spans = <InlineSpan>[];
  var textStart = 0;
  var attachmentIndex = 0;
  for (var offset = 0; offset < text.length; offset++) {
    if (text[offset] != inlineAttachmentMarker) continue;
    if (textStart < offset) {
      spans.add(
        TextSpan(text: text.substring(textStart, offset), style: style),
      );
    }
    if (attachmentIndex < attachments.length) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: tileBuilder(attachments[attachmentIndex]),
          ),
        ),
      );
    }
    attachmentIndex++;
    textStart = offset + 1;
  }
  if (textStart < text.length) {
    spans.add(TextSpan(text: text.substring(textStart), style: style));
  }
  return spans;
}

class InlineAttachmentTile extends StatefulWidget {
  const InlineAttachmentTile({
    required this.attachment,
    this.onDelete,
    this.onAdjust,
    this.onEnter,
    this.onExit,
    super.key,
  });

  final ContextAttachment attachment;
  final VoidCallback? onDelete;
  final VoidCallback? onAdjust;
  final ValueChanged<BuildContext>? onEnter;
  final VoidCallback? onExit;

  @override
  State<InlineAttachmentTile> createState() => _InlineAttachmentTileState();
}

class _InlineAttachmentTileState extends State<InlineAttachmentTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    final keyPrefix = widget.onDelete == null ? 'sent-inline' : 'inline';
    final image = _imageBytes(attachment.imageDataUrl);
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onEnter?.call(context);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.onExit?.call();
      },
      child: Semantics(
        label: '${attachment.reference}: ${attachment.excerpt}',
        child: Container(
          key: ValueKey('$keyPrefix-attachment-${attachment.id}'),
          height: 34,
          constraints: const BoxConstraints(maxWidth: 290),
          padding: const EdgeInsets.only(left: 6, right: 2),
          decoration: BoxDecoration(
            color: const Color(0xffeceaf8),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _hovered
                  ? const Color(0xff8178c9)
                  : const Color(0xffd8d4ed),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                attachment.reference,
                style: const TextStyle(
                  color: Color(0xff625989),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              if (image != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(
                    image,
                    key: ValueKey('$keyPrefix-image-${attachment.id}'),
                    width: 36,
                    height: 26,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined, size: 15),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Tooltip(
                  message: attachment.sourceTitle,
                  child: GestureDetector(
                    onTap: () => widget.onEnter?.call(context),
                    child: Text(
                      attachment.excerpt,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff272b38),
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.onAdjust != null)
                TextButton(
                  key: ValueKey('adjust-attachment-${attachment.id}'),
                  onPressed: widget.onAdjust,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Adjust', style: TextStyle(fontSize: 10.5)),
                ),
              if (widget.onDelete != null)
                IconButton(
                  tooltip: 'Remove ${attachment.reference}',
                  onPressed: widget.onDelete,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded, size: 13),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

int _markerCount(String value) =>
    inlineAttachmentMarker.allMatches(value).length;

Uint8List? _imageBytes(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    return UriData.parse(value).contentAsBytes();
  } on FormatException {
    return null;
  }
}
