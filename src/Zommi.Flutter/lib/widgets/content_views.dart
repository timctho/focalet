import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:markdown/markdown.dart' as md;
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/diagnostics/scroll_performance.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';

class CopyableMarkdown extends StatefulWidget {
  const CopyableMarkdown({
    required this.text,
    required this.onCopy,
    required this.onOpenLink,
    this.compact = false,
    this.showCopyAction = true,
    this.showCodeCopyAction = true,
    super.key,
  });

  final String text;
  final Future<void> Function(String value) onCopy;
  final Future<void> Function(String value) onOpenLink;
  final bool compact;
  final bool showCopyAction;
  final bool showCodeCopyAction;

  @override
  State<CopyableMarkdown> createState() => _CopyableMarkdownState();
}

class _CopyableMarkdownState extends State<CopyableMarkdown> {
  bool _hovered = false;
  bool _copied = false;
  String? _hoveredLink;
  String? _contextLink;
  MarkdownBody? _markdown;

  Widget _selectionMenu(BuildContext context, SelectableRegionState region) {
    final destination = _contextLink;
    final items = region.contextMenuButtonItems;
    if (destination == null ||
        items.any((item) => item.type == ContextMenuButtonType.copy)) {
      return AdaptiveTextSelectionToolbar.selectableRegion(
        selectableRegionState: region,
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: region.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            region.hideToolbar();
            unawaited(widget.onCopy(destination));
          },
        ),
        ...items,
      ],
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _markdown = null;
  }

  @override
  void didUpdateWidget(covariant CopyableMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text ||
        widget.compact != oldWidget.compact ||
        widget.showCodeCopyAction != oldWidget.showCodeCopyAction ||
        widget.onCopy != oldWidget.onCopy ||
        widget.onOpenLink != oldWidget.onOpenLink) {
      _markdown = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    ScrollPerformance.count('markdownBuild');
    if (_markdown == null) ScrollPerformance.count('markdownWidgetCreated');
    final chatFontSize = chatFontSizeOf(context);
    final headingDelta = chatFontSize - topBarAndChatFontSize;
    final base = DefaultTextStyle.of(context).style
        .merge(chatTextStyleOf(context))
        .copyWith(color: Theme.of(context).colorScheme.onSurface, height: 1.38);
    return Listener(
      onPointerDown: (event) {
        _contextLink = event.buttons == kSecondaryMouseButton
            ? _hoveredLink
            : null;
        if (_contextLink != null) Tooltip.dismissAllToolTips();
      },
      child: MouseRegion(
        onEnter: widget.showCopyAction
            ? (_) => setState(() => _hovered = true)
            : null,
        onExit: widget.showCopyAction
            ? (_) => setState(() => _hovered = false)
            : null,
        child: Stack(
          children: [
            ConstrainedBox(
              key: const ValueKey('copy-layout'),
              constraints: const BoxConstraints(minHeight: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                heightFactor: 1,
                child: Padding(
                  // Preserve the compact bubble's former caret spacing while
                  // sharing selection with the rest of the message.
                  padding: EdgeInsets.only(
                    right: widget.showCopyAction
                        ? (widget.compact ? 31 : 28)
                        : 0,
                  ),
                  child: SelectionArea(
                    contextMenuBuilder: _selectionMenu,
                    child: _markdown ??= MarkdownBody(
                      data: widget.text,
                      // All paragraphs and links participate in the same
                      // selection region, including compact user messages.
                      selectable: false,
                      fitContent: true,
                      onTapLink: (_, href, _) {
                        if (href != null) unawaited(widget.onOpenLink(href));
                      },
                      builders: {
                        'pre': _CodeBlockBuilder(
                          onCopy: widget.showCodeCopyAction
                              ? widget.onCopy
                              : null,
                        ),
                        'a': _TooltipLinkBuilder(
                          onOpen: widget.onOpenLink,
                          onHover: (link) => _hoveredLink = link,
                        ),
                      },
                      styleSheet: MarkdownStyleSheet(
                        a: base.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                        p: base,
                        h1: base.copyWith(
                          fontSize: 19.5 + headingDelta,
                          fontWeight: FontWeight.w700,
                        ),
                        h2: base.copyWith(
                          fontSize: 17.5 + headingDelta,
                          fontWeight: FontWeight.w700,
                        ),
                        h3: base.copyWith(
                          fontSize: 16 + headingDelta,
                          fontWeight: FontWeight.w700,
                        ),
                        h4: base.copyWith(fontWeight: FontWeight.w700),
                        h5: base.copyWith(fontWeight: FontWeight.w700),
                        h6: base.copyWith(fontWeight: FontWeight.w700),
                        em: base.copyWith(fontStyle: FontStyle.italic),
                        strong: base.copyWith(fontWeight: FontWeight.w700),
                        del: base.copyWith(
                          decoration: TextDecoration.lineThrough,
                        ),
                        blockquote: base,
                        listBullet: base,
                        tableHead: base.copyWith(fontWeight: FontWeight.w700),
                        tableBody: base,
                        code: base.copyWith(
                          fontFamily: 'monospace',
                          fontSize: chatFontSize,
                          backgroundColor: inlineCodeBackground,
                        ),
                        codeblockPadding: EdgeInsets.zero,
                        codeblockDecoration: const BoxDecoration(),
                        blockquoteDecoration: const BoxDecoration(),
                        blockquotePadding: const EdgeInsets.only(left: 12),
                        tableBorder: const TableBorder(),
                        tableCellsPadding: const EdgeInsets.all(7),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.showCopyAction)
              Positioned(
                right: 0,
                top: 0,
                child: AnimatedOpacity(
                  opacity: _hovered || _copied ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: Semantics(
                    button: true,
                    label: '${_copied ? 'Copied' : 'Copy'} response',
                    child: IconButton(
                      key: ValueKey('copy-${widget.text.hashCode}'),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      style: IconButton.styleFrom(
                        fixedSize: const Size(24, 24),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      padding: EdgeInsets.zero,
                      splashRadius: 13,
                      tooltip: _copied ? 'Copied' : 'Copy response',
                      onPressed: () async {
                        await widget.onCopy(widget.text);
                        if (!mounted) return;
                        setState(() => _copied = true);
                        await Future<void>.delayed(const Duration(seconds: 1));
                        if (mounted) setState(() => _copied = false);
                      },
                      icon: Icon(
                        _copied ? Icons.check_rounded : Icons.copy_rounded,
                        size: 14,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _TooltipLinkBuilder extends MarkdownElementBuilder {
  _TooltipLinkBuilder({required this.onOpen, required this.onHover});

  final Future<void> Function(String value) onOpen;
  final ValueChanged<String?> onHover;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final destination = element.attributes['href'] ?? '';
    return Tooltip(
      key: ValueKey('markdown-link-$destination'),
      message: destination,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(destination.isEmpty ? null : destination),
        onExit: (_) => onHover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: destination.isEmpty
              ? null
              : () => unawaited(onOpen(destination)),
          child: Text.rich(
            TextSpan(
              text: element.textContent,
              mouseCursor: SystemMouseCursors.click,
            ),
            style: (preferredStyle ?? parentStyle ?? chatTextStyleOf(context))
                .copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  decoration: TextDecoration.underline,
                ),
          ),
        ),
      ),
    );
  }
}

final class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.onCopy});

  final Future<void> Function(String value)? onCopy;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) =>
      _CopyableCodeBlock(code: element.textContent, onCopy: onCopy);
}

class _CopyableCodeBlock extends StatefulWidget {
  const _CopyableCodeBlock({required this.code, required this.onCopy});

  final String code;
  final Future<void> Function(String value)? onCopy;

  @override
  State<_CopyableCodeBlock> createState() => _CopyableCodeBlockState();
}

class _CopyableCodeBlockState extends State<_CopyableCodeBlock> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('code-block-${widget.code.hashCode}'),
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(11, 9, 5, 9),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                widget.code,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontFamily: 'monospace',
                  fontSize: chatFontSizeOf(context),
                  height: 1.35,
                ),
              ),
            ),
          ),
          if (widget.onCopy != null)
            IconButton(
              key: ValueKey('copy-code-${widget.code.hashCode}'),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              style: IconButton.styleFrom(
                fixedSize: const Size(30, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              padding: EdgeInsets.zero,
              splashRadius: 16,
              tooltip: _copied ? 'Copied code' : 'Copy code',
              onPressed: () async {
                await widget.onCopy!(widget.code);
                if (!mounted) return;
                setState(() => _copied = true);
                await Future<void>.delayed(const Duration(seconds: 1));
                if (mounted) setState(() => _copied = false);
              },
              icon: Icon(
                _copied ? Icons.check_rounded : Icons.copy_rounded,
                size: 16,
              ),
            ),
        ],
      ),
    );
  }
}

class SafeHtmlView extends StatelessWidget {
  const SafeHtmlView({required this.html, this.compact = false, super.key});

  final String html;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Html(
      data: sanitizeArtifactHtml(html),
      style: {
        'body': Style(
          margin: Margins.zero,
          padding: HtmlPaddings.zero,
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: FontSize(
            compact ? chatFontSizeOf(context) : chatFontSizeOf(context) + 1.5,
          ),
          backgroundColor: const Color(0x00000000),
        ),
        'th': Style(
          padding: HtmlPaddings.all(6),
          fontWeight: FontWeight.w700,
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest,
        ),
        'td': Style(padding: HtmlPaddings.all(6)),
        'pre': Style(
          padding: HtmlPaddings.all(8),
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest,
          whiteSpace: WhiteSpace.pre,
        ),
      },
    );
  }
}

String sanitizeArtifactHtml(String value) {
  final fragment = html_parser.parseFragment(value);
  for (final element in fragment.querySelectorAll(
    'script, iframe, object, embed, form, base, link, meta, style',
  )) {
    element.remove();
  }
  for (final element in fragment.querySelectorAll('*')) {
    for (final attribute in element.attributes.keys.toList(growable: false)) {
      final name = attribute.toString().toLowerCase().split(':').last;
      final attributeValue = element.attributes[attribute]?.trim() ?? '';
      final remove =
          name.startsWith('on') ||
          const {
            'action',
            'background',
            'formaction',
            'ping',
            'poster',
            'srcdoc',
            'srcset',
            'style',
          }.contains(name) ||
          (name == 'href' && !attributeValue.startsWith('#')) ||
          (name == 'src' && !_safeInlineImage.hasMatch(attributeValue));
      if (remove) element.attributes.remove(attribute);
    }
  }
  return fragment.outerHtml;
}

final RegExp _safeInlineImage = RegExp(
  r'^data:image/(?:png|jpe?g|gif|webp|bmp);base64,',
  caseSensitive: false,
);

class ArtifactSurface extends StatelessWidget {
  const ArtifactSurface({
    required this.artifact,
    this.compact = false,
    super.key,
  });

  final ArtifactPreview artifact;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (artifact.kind == 'error') {
      return SelectableText(
        artifact.html ?? 'Preview unavailable',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    final dataUrl = artifact.dataUrl;
    if (artifact.kind == 'image' && dataUrl != null) {
      final bytes = decodeImageDataUrl(dataUrl);
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: compact ? BoxFit.cover : BoxFit.contain,
          filterQuality: FilterQuality.medium,
          semanticLabel: artifact.title,
          errorBuilder: (_, error, stackTrace) => Text(
            'Image preview unavailable · $error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );
      }
    }
    final html = artifact.html;
    if (artifact.kind == 'html' && html != null) {
      return SafeHtmlView(html: html, compact: compact);
    }
    return Center(
      child: Text(
        artifact.path == null ? 'Loading preview…' : 'Preview available',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}

Uint8List? decodeImageDataUrl(String value) {
  final separator = value.indexOf(',');
  if (!value.startsWith('data:image/') || separator < 0) return null;
  try {
    return base64Decode(
      value.substring(separator + 1).replaceAll(RegExp(r'\s'), ''),
    );
  } on FormatException {
    return null;
  }
}
