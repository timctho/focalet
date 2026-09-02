import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';

const double userMessageBoxWidth = 416;
const double assistantMessageBoxWidth = 496;

class TranscriptPane extends StatefulWidget {
  const TranscriptPane({
    required this.controller,
    required this.onAttachmentEnter,
    required this.onAttachmentExit,
    super.key,
  });

  final ZommiController controller;
  final ValueChanged<ContextAttachment> onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;

  @override
  State<TranscriptPane> createState() => _TranscriptPaneState();
}

class _TranscriptPaneState extends State<TranscriptPane> {
  final ScrollController _scroll = ScrollController();
  int _start = 0;
  bool _autoFollow = true;
  bool _loadScheduled = false;
  int _knownTurnCount = 0;
  int _knownContentRevision = 0;

  @override
  void initState() {
    super.initState();
    _resetRange();
    _scroll.addListener(_handleScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
  }

  @override
  void didUpdateWidget(covariant TranscriptPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final turns = widget.controller.turns;
    final contentRevision = transcriptContentRevision(turns);
    if (oldWidget.controller.activeSessionId !=
        widget.controller.activeSessionId) {
      _resetRange();
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
      return;
    }
    if (turns.length < _knownTurnCount) _resetRange();
    _knownTurnCount = turns.length;
    if (_knownContentRevision != contentRevision && _autoFollow) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
    _knownContentRevision = contentRevision;
  }

  void _resetRange() {
    final count = widget.controller.turns.length;
    _start = math.max(0, count - historyPageSize);
    _knownTurnCount = count;
    _knownContentRevision = transcriptContentRevision(widget.controller.turns);
    _autoFollow = true;
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    _autoFollow = position.maxScrollExtent - position.pixels <= 36;
    if (position.pixels <= 96 && _start > 0 && !_loadScheduled) {
      _loadScheduled = true;
      final oldExtent = position.maxScrollExtent;
      final oldPixels = position.pixels;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _start = math.max(0, _start - historyPageSize));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _loadScheduled = false;
          if (!_scroll.hasClients) return;
          final added = _scroll.position.maxScrollExtent - oldExtent;
          _scroll.jumpTo(
            (oldPixels + added).clamp(
              _scroll.position.minScrollExtent,
              _scroll.position.maxScrollExtent,
            ),
          );
        });
      });
    }
    if (mounted) setState(() {});
  }

  void _scrollToLatest() {
    if (!_scroll.hasClients) return;
    _autoFollow = true;
    unawaited(
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final turns = widget.controller.turns;
    if (turns.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Point, ask, keep moving.',
              style: TextStyle(
                color: Color(0xff43495a),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Ask about anything under your pointer.',
              style: TextStyle(color: Color(0xff737887), fontSize: 10.5),
            ),
          ],
        ),
      );
    }
    final visible = turns.sublist(_start.clamp(0, turns.length));
    final awayFromLatest =
        _scroll.hasClients &&
        _scroll.position.maxScrollExtent - _scroll.position.pixels > 36;
    return Stack(
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          label: 'Agent conversation including thinking and tool activity',
          child: ListView.builder(
            key: const ValueKey('zommi-transcript'),
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final turn = visible[index];
              return ConversationTurnView(
                key: ValueKey('turn-${turn.id}'),
                turn: turn,
                runtimeName: widget.controller.activeRuntimeName,
                controller: widget.controller,
                onAttachmentEnter: widget.onAttachmentEnter,
                onAttachmentExit: widget.onAttachmentExit,
              );
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: Center(
            child: AnimatedScale(
              scale: awayFromLatest ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              child: Semantics(
                button: true,
                label: 'Scroll to latest message',
                child: SizedBox.square(
                  dimension: 36,
                  child: IconButton.filledTonal(
                    key: const ValueKey('scroll-to-latest'),
                    tooltip: 'Latest message',
                    padding: EdgeInsets.zero,
                    alignment: Alignment.center,
                    iconSize: 20,
                    onPressed: awayFromLatest ? _scrollToLatest : null,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      key: ValueKey('scroll-to-latest-glyph'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class ConversationTurnView extends StatelessWidget {
  const ConversationTurnView({
    required this.turn,
    required this.runtimeName,
    required this.controller,
    required this.onAttachmentEnter,
    required this.onAttachmentExit,
    super.key,
  });

  final ConversationTurn turn;
  final String runtimeName;
  final ZommiController controller;
  final ValueChanged<ContextAttachment> onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;

  @override
  Widget build(BuildContext context) {
    final blocks = distinctTranscriptBlocks(turn.blocks);
    final thinking = blocks.cast<TranscriptBlock?>().firstWhere(
      (block) => block?.kind == TranscriptKind.thinking,
      orElse: () => null,
    );
    final tools = blocks
        .where((block) => block.kind == TranscriptKind.tool)
        .toList(growable: false);
    return Semantics(
      container: true,
      label: 'Conversation turn ${turn.number}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                key: ValueKey('user-message-${turn.id}'),
                constraints: const BoxConstraints(
                  maxWidth: userMessageBoxWidth,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xffe9e7f8),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (turn.contextTokens.isNotEmpty &&
                        turn.attachments.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text(
                          turn.contextTokens.join(' '),
                          style: const TextStyle(
                            color: Color(0xff6d639f),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    if (turn.attachments.isNotEmpty &&
                        turn.inlineUserText.contains(inlineAttachmentMarker))
                      InlineAttachmentMessage(
                        key: ValueKey('inline-user-message-${turn.id}'),
                        text: turn.inlineUserText,
                        attachments: turn.attachments,
                        onAttachmentEnter: onAttachmentEnter,
                        onAttachmentExit: onAttachmentExit,
                      )
                    else
                      CopyableMarkdown(
                        text: turn.userText,
                        compact: true,
                        onCopy: controller.copyText,
                        onOpenLink: controller.openExternalLink,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final block in blocks)
              if (block.kind != TranscriptKind.tool &&
                  (block.kind != TranscriptKind.thinking ||
                      identical(block, thinking)))
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: block.kind == TranscriptKind.assistant
                      ? AssistantBlockView(
                          block: block,
                          runtimeName: runtimeName,
                          controller: controller,
                        )
                      : block.kind == TranscriptKind.thinking
                      ? ThinkingActivityGroup(
                          block: block,
                          tools: tools,
                          controller: controller,
                        )
                      : ActivityBlockView(block: block, controller: controller),
                ),
          ],
        ),
      ),
    );
  }
}

int transcriptContentRevision(Iterable<ConversationTurn> turns) =>
    Object.hashAll(
      turns.expand(
        (turn) => <Object?>[
          turn.id,
          turn.userText,
          turn.inlineUserText,
          ...turn.attachments.map((attachment) => attachment.id),
          ...turn.blocks.expand(
            (block) => <Object?>[
              block.id,
              block.kind,
              block.text,
              block.lifecycle,
              block.expanded,
              ...block.artifacts.map((artifact) => artifact.identity),
            ],
          ),
        ],
      ),
    );

List<TranscriptBlock> distinctTranscriptBlocks(
  Iterable<TranscriptBlock> blocks,
) {
  final result = <TranscriptBlock>[];
  for (final block in normalizeTranscriptBlocks(blocks)) {
    final text = block.text.trim();
    final duplicate =
        block.kind == TranscriptKind.assistant &&
        text.isNotEmpty &&
        result.any(
          (existing) =>
              existing.kind == block.kind && existing.text.trim() == text,
        );
    if (!duplicate) result.add(block);
  }
  return result;
}

class ThinkingActivityGroup extends StatelessWidget {
  const ThinkingActivityGroup({
    required this.block,
    required this.tools,
    required this.controller,
    super.key,
  });

  final TranscriptBlock block;
  final List<TranscriptBlock> tools;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final completed = block.completed && tools.every((tool) => tool.completed);
    return Semantics(
      container: true,
      label: 'Thinking ${completed ? 'completed' : 'in progress'}',
      child: Container(
        key: ValueKey('activity-${block.id}'),
        decoration: BoxDecoration(
          color: const Color(0x80ffffff),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xffe2e5ed)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const ValueKey('thinking-toggle'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => controller.setBlockExpanded(block, !block.expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      size: 15,
                      color: Color(0xff746b99),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Thinking',
                        style: TextStyle(
                          color: Color(0xff4b5060),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (tools.isNotEmpty)
                      Text(
                        '${tools.length} tool${tools.length == 1 ? '' : 's'}',
                        key: const ValueKey('thinking-tool-count'),
                        style: const TextStyle(
                          color: Color(0xff747988),
                          fontSize: 10,
                        ),
                      ),
                    if (tools.isNotEmpty) const SizedBox(width: 8),
                    if (!completed)
                      const SizedBox.square(
                        dimension: 13,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    else
                      const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 15,
                        color: Color(0xff659071),
                      ),
                    const SizedBox(width: 5),
                    Icon(
                      block.expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 17,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              key: const ValueKey('thinking-fold'),
              firstChild: const SizedBox(width: double.infinity),
              secondChild: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (block.text.isNotEmpty)
                      CopyableMarkdown(
                        text: block.text,
                        compact: true,
                        onCopy: controller.copyText,
                        onOpenLink: controller.openExternalLink,
                      ),
                    for (final artifact in block.artifacts)
                      ArtifactCard(artifact: artifact, controller: controller),
                    for (final tool in tools)
                      _ToolActivitySubItem(block: tool, controller: controller),
                  ],
                ),
              ),
              crossFadeState: block.expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 150),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolActivitySubItem extends StatelessWidget {
  const _ToolActivitySubItem({required this.block, required this.controller});

  final TranscriptBlock block;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('activity-${block.id}'),
      margin: const EdgeInsets.only(top: 7),
      decoration: BoxDecoration(
        color: const Color(0x66eef0f6),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('tool-toggle-${block.id}'),
            borderRadius: BorderRadius.circular(10),
            onTap: () => controller.setBlockExpanded(block, !block.expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.build_outlined,
                    size: 14,
                    color: Color(0xff746b99),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      block.title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xff4b5060),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!block.completed)
                    const SizedBox.square(
                      dimension: 11,
                      child: CircularProgressIndicator(strokeWidth: 1.4),
                    )
                  else
                    const Icon(
                      Icons.check_rounded,
                      size: 14,
                      color: Color(0xff659071),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    block.expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (block.text.isNotEmpty)
                    CopyableMarkdown(
                      text: block.text,
                      compact: true,
                      onCopy: controller.copyText,
                      onOpenLink: controller.openExternalLink,
                    ),
                  for (final artifact in block.artifacts)
                    ArtifactCard(artifact: artifact, controller: controller),
                ],
              ),
            ),
            crossFadeState: block.expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 130),
          ),
        ],
      ),
    );
  }
}

class AssistantBlockView extends StatelessWidget {
  const AssistantBlockView({
    required this.block,
    required this.runtimeName,
    required this.controller,
    super.key,
  });

  final TranscriptBlock block;
  final String runtimeName;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$runtimeName response',
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: ValueKey('assistant-${block.id}'),
          constraints: const BoxConstraints(maxWidth: assistantMessageBoxWidth),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xb3ffffff),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0x99ffffff)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CopyableMarkdown(
                text: block.text,
                onCopy: controller.copyText,
                onOpenLink: controller.openExternalLink,
              ),
              for (final artifact in block.artifacts)
                ArtifactCard(artifact: artifact, controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class ActivityBlockView extends StatelessWidget {
  const ActivityBlockView({
    required this.block,
    required this.controller,
    super.key,
  });

  final TranscriptBlock block;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final completed = block.lifecycle == TranscriptLifecycle.completed;
    final icon = switch (block.kind) {
      TranscriptKind.thinking => Icons.auto_awesome_rounded,
      TranscriptKind.plan => Icons.format_list_bulleted_rounded,
      TranscriptKind.error => Icons.error_outline_rounded,
      _ => Icons.build_outlined,
    };
    return Semantics(
      container: true,
      label: '${block.title} ${completed ? 'completed' : 'in progress'}',
      child: Container(
        key: ValueKey('activity-${block.id}'),
        decoration: BoxDecoration(
          color: block.kind == TranscriptKind.error
              ? const Color(0xffffedf0)
              : const Color(0x80ffffff),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: block.kind == TranscriptKind.error
                ? const Color(0xffe9b6bf)
                : const Color(0xffe2e5ed),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => controller.setBlockExpanded(block, !block.expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 15, color: const Color(0xff746b99)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        block.title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xff4b5060),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!completed)
                      const SizedBox.square(
                        dimension: 13,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    else
                      const Icon(
                        Icons.check_circle_outline_rounded,
                        size: 15,
                        color: Color(0xff659071),
                      ),
                    const SizedBox(width: 5),
                    Icon(
                      block.expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 17,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox(width: double.infinity),
              secondChild: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  key: ValueKey('activity-scroll-${block.id}'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (block.text.isNotEmpty)
                        CopyableMarkdown(
                          text: block.text,
                          compact: true,
                          onCopy: controller.copyText,
                          onOpenLink: controller.openExternalLink,
                        ),
                      for (final artifact in block.artifacts)
                        ArtifactCard(
                          artifact: artifact,
                          controller: controller,
                        ),
                    ],
                  ),
                ),
              ),
              crossFadeState: block.expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 150),
            ),
          ],
        ),
      ),
    );
  }
}

class ArtifactCard extends StatefulWidget {
  const ArtifactCard({
    required this.artifact,
    required this.controller,
    super.key,
  });

  final ArtifactPreview artifact;
  final ZommiController controller;

  @override
  State<ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<ArtifactCard> {
  ArtifactPreview? _loaded;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await widget.controller.artifactLoader.load(
        widget.artifact,
        target: widget.controller.activeRuntime,
      );
      if (mounted) setState(() => _loaded = value);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final artifact = _loaded ?? widget.artifact;
    return Container(
      key: ValueKey('artifact-${artifact.id}'),
      margin: const EdgeInsets.only(top: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xfff7f8fb),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xffdfe3ec)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 8),
            child: Row(
              children: [
                Text(
                  artifact.kind == 'html' ? 'HTML' : 'Image',
                  style: const TextStyle(
                    color: Color(0xff746b99),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    artifact.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 150,
            child: _error == null
                ? ArtifactSurface(artifact: artifact, compact: true)
                : Center(
                    child: Text(
                      'Preview unavailable · $_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xff9b4050)),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 7, 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    artifact.path ?? 'Generated in this chat',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xff747988),
                      fontSize: 11,
                    ),
                  ),
                ),
                if (artifact.kind == 'image' && artifact.dataUrl != null)
                  IconButton(
                    tooltip: 'Copy image',
                    onPressed: () => unawaited(
                      widget.controller.copyImage(artifact.dataUrl!),
                    ),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                  ),
                TextButton(
                  onPressed: _error == null
                      ? () =>
                            unawaited(widget.controller.showArtifact(artifact))
                      : null,
                  child: const Text('Preview'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
