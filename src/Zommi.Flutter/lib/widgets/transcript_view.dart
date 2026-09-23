import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zommi_flutter/diagnostics/scroll_performance.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/document_thumbnail.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/message_actions.dart';
import 'package:zommi_flutter/widgets/thinking_flow_background.dart';

const double _messageContentWidthScale = 1.2;
const double userMessageBoxWidth = 416 * _messageContentWidthScale;
const double assistantMessageBoxWidth = 496 * _messageContentWidthScale;
const double conversationContentMaxWidth = 720 * _messageContentWidthScale;
const double _baselineMessageViewportWidth = conversationContentMaxWidth;
const double _transcriptHorizontalInsets = 48;

double responsiveUserMessageBoxWidth(double viewportWidth) {
  final growth = math.max(0, viewportWidth - _baselineMessageViewportWidth);
  return math.min(
    math.max(0, viewportWidth - _transcriptHorizontalInsets),
    userMessageBoxWidth + growth * 0.62,
  );
}

double responsiveAssistantMessageBoxWidth(double viewportWidth) {
  return math.min(conversationContentMaxWidth, math.max(0, viewportWidth));
}

class TranscriptPane extends StatefulWidget {
  const TranscriptPane({
    required this.controller,
    required this.onAttachmentEnter,
    required this.onAttachmentExit,
    super.key,
  });

  final ZommiController controller;
  final AttachmentHoverCallback onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;

  @override
  State<TranscriptPane> createState() => _TranscriptPaneState();
}

class _TranscriptPaneState extends State<TranscriptPane> {
  final ScrollController _scroll = ScrollController(keepScrollOffset: false);
  final ValueNotifier<bool> _awayFromLatest = ValueNotifier(false);
  int _start = 0;
  bool _autoFollow = true;
  bool _loadScheduled = false;
  bool _settlingSession = false;
  bool _waitingForHistory = false;
  int _rangeEpoch = 0;
  int _knownTurnCount = 0;
  int _knownContentRevision = 0;
  (String?, String?)? _knownSession;
  final _retention = _TurnRetention();
  final _turnViews =
      <
        String,
        ({
          int revision,
          double width,
          double availableWidth,
          String runtimeName,
          ConversationTurnView view,
        })
      >{};

  @override
  void initState() {
    super.initState();
    _resetRange();
    _scroll.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant TranscriptPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final turns = widget.controller.turns;
    final contentRevision = widget.controller.transcriptRevision;
    if (_knownSession !=
            (
              widget.controller.activeRuntime?.id,
              widget.controller.activeSessionId,
            ) ||
        (_knownTurnCount == 0 && turns.isNotEmpty) ||
        (_waitingForHistory && !_historyLoading)) {
      // A cold session can be selected before its history arrives. Treat that
      // first populated snapshot as a page, not an unbounded batch of new turns.
      _resetRange();
      return;
    }
    if (turns.length < _knownTurnCount) _resetRange();
    _knownTurnCount = turns.length;
    if (_knownContentRevision != contentRevision &&
        _autoFollow &&
        !_settlingSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToLatest());
    }
    _knownContentRevision = contentRevision;
  }

  void _resetRange() {
    final epoch = ++_rangeEpoch;
    _loadScheduled = false;
    _waitingForHistory = _historyLoading;
    _settlingSession = true;
    final count = widget.controller.turns.length;
    _start = math.max(0, count - historyPageSize);
    _knownTurnCount = count;
    _knownContentRevision = widget.controller.transcriptRevision;
    _knownSession = (
      widget.controller.activeRuntime?.id,
      widget.controller.activeSessionId,
    );
    _turnViews.clear();
    _retention.clear();
    _autoFollow = true;
    _awayFromLatest.value = false;
    _settleSessionAtBottom(epoch);
  }

  bool get _historyLoading =>
      widget.controller.sessionBusy ||
      widget.controller.runtimeBusy ||
      widget.controller.starting;

  void _settleSessionAtBottom(int epoch) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _rangeEpoch) return;
      if (!_scroll.hasClients) {
        _settlingSession = false;
        return;
      }
      final position = _scroll.position;
      // Lazy rows have estimated heights until laid out. Follow the changing
      // extent across frames instead of stopping at the first estimate.
      if ((position.maxScrollExtent - position.pixels).abs() <= 0.5) {
        _settlingSession = false;
        _autoFollow = true;
        _awayFromLatest.value = false;
        return;
      }
      _scroll.jumpTo(position.maxScrollExtent);
      _settleSessionAtBottom(epoch);
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  void _handleScroll() {
    if (!_scroll.hasClients || _settlingSession) return;
    final position = _scroll.position;
    _autoFollow = position.maxScrollExtent - position.pixels <= 36;
    _awayFromLatest.value = !_autoFollow;
    if (position.pixels <= 96 &&
        (_start > 0 || widget.controller.hasOlderHistory) &&
        !_loadScheduled) {
      unawaited(_loadEarlier());
    }
  }

  Future<void> _loadEarlier() async {
    if (!_scroll.hasClients || _loadScheduled) return;
    final position = _scroll.position;
    _loadScheduled = true;
    final epoch = _rangeEpoch;
    final oldExtent = position.maxScrollExtent;
    final oldPixels = position.pixels;
    if (_start == 0) await widget.controller.loadOlderHistory();
    if (!mounted || epoch != _rangeEpoch) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _rangeEpoch) return;
      setState(() => _start = math.max(0, _start - historyPageSize));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || epoch != _rangeEpoch) return;
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
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scrollToLatest() {
    if (!mounted || !_scroll.hasClients || _settlingSession) return;
    _autoFollow = true;
    unawaited(
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      ),
    );
    _awayFromLatest.value = false;
  }

  void _attachmentEnter(ContextAttachment attachment, BuildContext anchor) =>
      widget.onAttachmentEnter(attachment, anchor);

  void _attachmentExit(ContextAttachment attachment) =>
      widget.onAttachmentExit(attachment);

  Widget _turnView(
    ConversationTurn turn,
    double viewportWidth,
    double availableWidth,
  ) {
    // Only visible rows are fingerprinted. Keep completed rows' widget trees
    // unchanged when another row streams, while preserving folds and updates.
    final isResponding =
        widget.controller.turnActive &&
        identical(turn, widget.controller.turns.last);
    final revision = Object.hash(
      isResponding,
      transcriptContentRevision([turn], visibleOnly: true),
      turn.activityExpanded,
      turn.number,
      turn.historySummary,
      turn.historyLoading,
      turn.historyError,
      Object.hashAll(
        turn.activityGroupExpansion.entries.map(
          (entry) => Object.hash(entry.key, entry.value),
        ),
      ),
      Object.hashAll(turn.contextTokens),
      Object.hashAll(
        turn.blocks
            .where(
              (block) =>
                  turn.hasExpandedActivity || !block.kind.isFoldedActivity,
            )
            .expand((block) => [block.title, block.status, block.expanded]),
      ),
    );
    final runtimeName = widget.controller.activeRuntimeName;
    final cached = _turnViews[turn.id];
    if (cached != null &&
        identical(cached.view.turn, turn) &&
        identical(cached.view.controller, widget.controller) &&
        cached.revision == revision &&
        cached.width == viewportWidth &&
        cached.availableWidth == availableWidth &&
        cached.runtimeName == runtimeName) {
      return _retain(turn, cached.view);
    }
    final view = ConversationTurnView(
      key: ValueKey('turn-${turn.id}'),
      turn: turn,
      viewportWidth: viewportWidth,
      availableWidth: availableWidth,
      runtimeName: runtimeName,
      controller: widget.controller,
      isResponding: isResponding,
      onAttachmentEnter: _attachmentEnter,
      onAttachmentExit: _attachmentExit,
    );
    _turnViews[turn.id] = (
      revision: revision,
      width: viewportWidth,
      availableWidth: availableWidth,
      runtimeName: runtimeName,
      view: view,
    );
    if (_turnViews.length > 128) _turnViews.remove(_turnViews.keys.first);
    return _retain(turn, view);
  }

  Widget _retain(ConversationTurn turn, Widget child) {
    // Bound retained render trees by both row count and visible source size.
    // Running/expanded activity and image-heavy rows are not retained offscreen.
    final eligible =
        !turn.hasExpandedActivity &&
        turn.attachments.isEmpty &&
        turn.blocks.every(
          (block) => block.completed && block.artifacts.isEmpty,
        );
    final characters =
        turn.userText.length +
        turn.blocks
            .where((block) => !block.kind.isFoldedActivity)
            .fold<int>(0, (sum, block) => sum + block.text.length);
    return _RetainedTurn(
      key: ValueKey('turn-layout-${turn.id}'),
      retention: _retention,
      characters: eligible ? characters : null,
      child: child,
    );
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_handleScroll)
      ..dispose();
    _awayFromLatest.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final turns = widget.controller.turns;
    ScrollPerformance.ready(turns.length);
    ScrollPerformance.count('transcriptBuild');
    if (turns.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Point, ask, keep moving.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ask about anything under your pointer.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 10.5,
              ),
            ),
          ],
        ),
      );
    }
    final visible = turns.sublist(_start.clamp(0, turns.length));
    final indices = {
      for (var index = 0; index < visible.length; index++)
        ValueKey('turn-layout-${visible[index].id}'): index,
    };
    // A LayoutBuilder inside each row makes even a descendant spinner/hover
    // rebuild schedule row layout and repaint. Resolve the shared width once,
    // outside the sliver, so those updates stay inside their paint boundary.
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
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
              findChildIndexCallback: (key) => indices[key],
              itemBuilder: (context, index) {
                final turn = visible[index];
                final contentWidth = math.min(
                  conversationContentMaxWidth,
                  math.max(0.0, constraints.maxWidth - 48),
                );
                final availableWidth = math.max(0.0, constraints.maxWidth - 48);
                return _turnView(turn, contentWidth, availableWidth);
              },
            ),
          ),
          if (widget.controller.loadingOlderHistory)
            const Positioned(
              top: 2,
              left: 24,
              right: 24,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (widget.controller.olderHistoryError case final error?)
            Positioned(
              top: 4,
              left: 24,
              child: TextButton(onPressed: _loadEarlier, child: Text(error)),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 12,
            child: ValueListenableBuilder<bool>(
              valueListenable: _awayFromLatest,
              builder: (context, awayFromLatest, _) => Center(
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
          ),
        ],
      ),
    );
  }
}

class ConversationTurnView extends StatelessWidget {
  const ConversationTurnView({
    required this.turn,
    required this.viewportWidth,
    required this.runtimeName,
    required this.controller,
    required this.onAttachmentEnter,
    required this.onAttachmentExit,
    this.isResponding = false,
    this.availableWidth,
    super.key,
  });

  final ConversationTurn turn;
  final double viewportWidth;
  final double? availableWidth;
  final String runtimeName;
  final ZommiController controller;
  final AttachmentHoverCallback onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;
  final bool isResponding;

  @override
  Widget build(BuildContext context) {
    ScrollPerformance.count('turnBuild');
    final proseInset = math.max(
      0.0,
      ((availableWidth ?? viewportWidth) - viewportWidth) / 2,
    );
    final blocks = ScrollPerformance.measure(
      'normalizeBlocks',
      () => distinctTranscriptBlocks(turn.blocks),
    );
    final showTyping =
        isResponding &&
        !blocks.any(
          (block) =>
              block.kind.isMessage &&
              (block.text.trim().isNotEmpty || block.artifacts.isNotEmpty),
        );
    // Fold only adjacent activity so later thinking stays after the response
    // that preceded it. Empty message placeholders do not split a group.
    final segments = <List<TranscriptBlock>>[];
    for (final block in blocks) {
      if (block.kind.isMessage &&
          block.text.trim().isEmpty &&
          block.artifacts.isEmpty) {
        continue;
      }
      if (block.kind.isFoldedActivity &&
          segments.isNotEmpty &&
          segments.last.first.kind.isFoldedActivity) {
        segments.last.add(block);
      } else {
        segments.add([block]);
      }
    }
    if (turn.historySummary) {
      segments.insert(0, [
        TranscriptBlock(
          id: '${turn.id}:history-details',
          kind: TranscriptKind.thinking,
          title: 'Thinking',
          text: '',
          lifecycle: TranscriptLifecycle.completed,
        ),
      ]);
    }
    final lastActivity = segments
        .where((segment) => segment.first.kind.isFoldedActivity)
        .lastOrNull;
    // Item completion also occurs for progress updates. Wait for the turn to
    // finish before exposing the final assistant answer's single copy action.
    final finalResponse = blocks
        .where(
          (block) =>
              block.kind == TranscriptKind.assistant &&
              (block.text.trim().isNotEmpty || block.artifacts.isNotEmpty),
        )
        .lastOrNull;
    return Semantics(
      container: true,
      label: 'Conversation turn ${turn.number}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: viewportWidth,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _EditableUserMessage(
                    turn: turn,
                    controller: controller,
                    width: responsiveUserMessageBoxWidth(viewportWidth),
                    onAttachmentEnter: onAttachmentEnter,
                    onAttachmentExit: onAttachmentExit,
                    child: Container(
                      key: ValueKey('user-message-${turn.id}'),
                      constraints: BoxConstraints(
                        maxWidth: responsiveUserMessageBoxWidth(viewportWidth),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (turn.contextTokens.isNotEmpty &&
                              turn.attachments.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Text(
                                turn.contextTokens
                                    .map(
                                      (token) =>
                                          '${token.replaceAll(RegExp(r'[\[\]]'), '')}.',
                                    )
                                    .join(' '),
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          if (turn.attachments.isNotEmpty)
                            InlineAttachmentMessage(
                              key: ValueKey('inline-user-message-${turn.id}'),
                              text:
                                  turn.inlineUserText.contains(
                                    inlineAttachmentMarker,
                                  )
                                  ? turn.inlineUserText
                                  : '${turn.userText}\n${List.filled(turn.attachments.length, inlineAttachmentMarker).join(' ')}',
                              attachments: turn.attachments,
                              onAttachmentEnter: onAttachmentEnter,
                              onAttachmentExit: onAttachmentExit,
                            )
                          else
                            DefaultTextStyle.merge(
                              // Shrink wrapped paragraphs to their longest visible
                              // line so both sides keep the same bubble inset.
                              textWidthBasis: TextWidthBasis.longestLine,
                              child: CopyableMarkdown(
                                text: turn.userText,
                                compact: true,
                                showCopyAction: false,
                                onCopy: controller.copyText,
                                onOpenLink: controller.openExternalLink,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (final segment in segments)
              if (!segment.first.kind.isFoldedActivity)
                Padding(
                  key: ValueKey('message-segment-${segment.first.id}'),
                  padding: EdgeInsets.only(
                    bottom: 9,
                    left: segment.first.kind.isMessage ? 0 : proseInset,
                    right: segment.first.kind.isMessage ? 0 : proseInset,
                  ),
                  child: segment.first.kind.isMessage
                      ? AssistantBlockView(
                          block: segment.first,
                          width: responsiveAssistantMessageBoxWidth(
                            viewportWidth,
                          ),
                          tableWidth: availableWidth,
                          proseInset: proseInset,
                          runtimeName: runtimeName,
                          controller: controller,
                          showActions:
                              !isResponding &&
                              identical(segment.first, finalResponse) &&
                              segment.first.completed,
                        )
                      : ActivityBlockView(
                          block: segment.first,
                          width: responsiveAssistantMessageBoxWidth(
                            viewportWidth,
                          ),
                          controller: controller,
                        ),
                )
              else
                Padding(
                  key: ValueKey('activity-segment-${segment.first.id}'),
                  padding: EdgeInsets.fromLTRB(proseInset, 0, proseInset, 6),
                  child: ThinkingActivityGroup(
                    turn: turn,
                    activities: segment,
                    width: responsiveAssistantMessageBoxWidth(viewportWidth),
                    controller: controller,
                    isResponding:
                        isResponding && identical(segment, lastActivity),
                    forceCompleted:
                        !isResponding || !identical(segment, segments.last),
                  ),
                ),
            if (showTyping)
              Padding(
                padding: EdgeInsets.only(left: proseInset),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    label: '$runtimeName is typing',
                    liveRegion: true,
                    child: ExcludeSemantics(
                      child: Container(
                        key: ValueKey('typing-indicator-${turn.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const RepaintBoundary(child: TypingDots()),
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

class _EditableUserMessage extends StatefulWidget {
  const _EditableUserMessage({
    required this.turn,
    required this.controller,
    required this.width,
    required this.onAttachmentEnter,
    required this.onAttachmentExit,
    required this.child,
  });

  final ConversationTurn turn;
  final ZommiController controller;
  final double width;
  final AttachmentHoverCallback onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;
  final Widget child;

  @override
  State<_EditableUserMessage> createState() => _EditableUserMessageState();
}

class _EditableUserMessageState extends State<_EditableUserMessage> {
  TextEditingController? _editor;
  bool _sending = false;

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  void _cancel() {
    final editor = _editor;
    setState(() => _editor = null);
    // The field releases its listener on the next build.
    WidgetsBinding.instance.addPostFrameCallback((_) => editor?.dispose());
  }

  Future<void> _send() async {
    final editor = _editor;
    if (editor == null ||
        _sending ||
        (editor.value.composing.isValid &&
            !editor.value.composing.isCollapsed)) {
      return;
    }
    setState(() => _sending = true);
    final accepted = await widget.controller.resendMessage(
      widget.turn,
      editor.text,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (accepted) _cancel();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final editor = _editor;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final enabled =
            !_sending &&
            controller.messageEditingSupported &&
            widget.turn.runtimeTurnId != null &&
            !controller.sessionReadOnly &&
            !controller.sessionBusy &&
            !controller.runtimeBusy &&
            !controller.selectingContent &&
            controller.turns.contains(widget.turn);
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.width),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (editor == null)
                widget.child
              else
                Container(
                  key: ValueKey('message-editor-${widget.turn.id}'),
                  width: widget.width,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh
                        .withValues(alpha: .80),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        key: ValueKey('edit-message-text-${widget.turn.id}'),
                        controller: editor,
                        autofocus: true,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 8,
                        style: chatTextStyleOf(context),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                      if (widget.turn.attachments.isNotEmpty)
                        InlineAttachmentMessage(
                          text: List.filled(
                            widget.turn.attachments.length,
                            inlineAttachmentMarker,
                          ).join(' '),
                          attachments: widget.turn.attachments,
                          onAttachmentEnter: widget.onAttachmentEnter,
                          onAttachmentExit: widget.onAttachmentExit,
                        ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _sending ? null : _cancel,
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: 6),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: editor,
                            builder: (context, value, _) => FilledButton(
                              key: ValueKey('resend-message-${widget.turn.id}'),
                              onPressed: enabled && value.text.trim().isNotEmpty
                                  ? _send
                                  : null,
                              child: Text(_sending ? 'Sending…' : 'Resend'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              if (editor == null)
                MessageActions(
                  key: ValueKey('user-actions-${widget.turn.id}'),
                  text: widget.turn.userText,
                  timestamp: widget.turn.createdAt,
                  isUser: true,
                  onCopy: controller.copyText,
                  onEdit: enabled
                      ? () => setState(
                          () => _editor = TextEditingController(
                            text: widget.turn.userText,
                          ),
                        )
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }
}

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> {
  Timer? _timer;
  int _visibleDots = 1;
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion || !TickerMode.valuesOf(context).enabled) {
      _timer?.cancel();
      _timer = null;
    } else {
      // Only the discrete dot phases need repainting, not every display frame.
      _timer ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
        setState(() => _visibleDots = _visibleDots % 3 + 1);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibleDots = _reduceMotion ? 3 : _visibleDots;
    // Keep all three glyphs laid out so each phase has identical bounds.
    return Text.rich(
      TextSpan(
        children: [
          for (var index = 0; index < 3; index++)
            TextSpan(
              text: '.',
              style: TextStyle(
                color: index < visibleDots
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : const Color(0x00747988),
              ),
            ),
        ],
      ),
      style: chatTextStyleOf(context).copyWith(letterSpacing: 2),
    );
  }
}

int transcriptContentRevision(
  Iterable<ConversationTurn> turns, {
  bool visibleOnly = false,
}) => ScrollPerformance.measure(
  'revisionScan',
  () => Object.hashAll(
    turns.expand(
      (turn) => <Object?>[
        turn.id,
        turn.createdAt,
        turn.userText,
        turn.inlineUserText,
        ...turn.attachments.map((attachment) => attachment.id),
        ...turn.blocks.expand(
          (block) =>
              visibleOnly &&
                  !turn.hasExpandedActivity &&
                  block.kind.isFoldedActivity
              ? <Object?>[
                  block.id,
                  block.createdAt,
                  block.kind,
                  block.completed,
                  block.text.trim().isNotEmpty || block.artifacts.isNotEmpty,
                ]
              : <Object?>[
                  block.id,
                  block.createdAt,
                  block.kind,
                  block.text,
                  block.lifecycle,
                  block.preview,
                  ...block.artifacts.map((artifact) => artifact.identity),
                ],
        ),
      ],
    ),
  ),
);

// ListView normally disposes an offscreen row, including Markdown's parsed
// state. Keep a small working set alive for scrolling back over recent replies.
// Eviction only changes keep-alive parent data after layout has finished.
class _TurnRetention {
  final _entries = <_RetainedTurnState, int>{};
  static const maxTurns = 8;
  static const maxCharacters = 128000;
  int _characters = 0;

  bool claim(_RetainedTurnState state, int? characters) {
    forget(state);
    if (characters == null || characters > maxCharacters) return false;
    _entries[state] = characters;
    _characters += characters;
    while (_entries.length > maxTurns || _characters > maxCharacters) {
      final oldest = _entries.keys.first;
      forget(oldest);
      _releaseAfterLayout(oldest);
    }
    return true;
  }

  void forget(_RetainedTurnState state) {
    _characters -= _entries.remove(state) ?? 0;
  }

  void clear() {
    final old = _entries.keys.toList();
    _entries.clear();
    _characters = 0;
    for (final state in old) {
      _releaseAfterLayout(state);
    }
  }

  void _releaseAfterLayout(_RetainedTurnState state) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.mounted && !_entries.containsKey(state)) state.release();
    });
  }
}

class _RetainedTurn extends StatefulWidget {
  const _RetainedTurn({
    required this.retention,
    required this.characters,
    required this.child,
    super.key,
  });
  final _TurnRetention retention;
  final int? characters;
  final Widget child;
  @override
  State<_RetainedTurn> createState() => _RetainedTurnState();
}

class _RetainedTurnState extends State<_RetainedTurn>
    with AutomaticKeepAliveClientMixin {
  bool _retained = false;
  @override
  bool get wantKeepAlive => _retained;

  void release() {
    _retained = false;
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    final retained = widget.retention.claim(this, widget.characters);
    if (_retained != retained) {
      _retained = retained;
      updateKeepAlive();
    }
    super.build(context);
    return widget.child;
  }

  @override
  void dispose() {
    widget.retention.forget(this);
    super.dispose();
  }
}

List<TranscriptBlock> distinctTranscriptBlocks(
  Iterable<TranscriptBlock> blocks,
) {
  final result = <TranscriptBlock>[];
  for (final block in normalizeTranscriptBlocks(blocks)) {
    if (block.kind == TranscriptKind.thinking &&
        block.text.trim().isEmpty &&
        block.artifacts.isEmpty) {
      continue;
    }
    final duplicateIndex =
        block.kind == TranscriptKind.assistant &&
            result.isNotEmpty &&
            result.last.kind == TranscriptKind.assistant &&
            transcriptTextSnapshotsOverlap(result.last.text, block.text)
        ? result.length - 1
        : -1;
    if (duplicateIndex < 0) {
      result.add(block);
    } else if (result[duplicateIndex].text.trim().length >=
        block.text.trim().length) {
      continue;
    } else {
      result[duplicateIndex] = mergeTranscriptBlocks(
        result[duplicateIndex],
        block,
      );
    }
  }
  return result;
}

String activityBlockTitle(TranscriptBlock block) {
  if (block.title.toLowerCase() != 'command') return block.title;
  final command = block.preview.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (command.isEmpty) return block.title;
  final codePoints = command.runes.toList(growable: false);
  final abbreviated = codePoints.length <= 20
      ? command
      : '${String.fromCharCodes(codePoints.take(20))}...';
  return 'Command · $abbreviated';
}

class _ExpandableActivityBody extends StatelessWidget {
  const _ExpandableActivityBody({
    required this.expanded,
    required this.duration,
    required this.child,
    super.key,
  });

  final bool expanded;
  final Duration duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = expanded
        ? child
        : const SizedBox(
            key: ValueKey('collapsed-activity'),
            width: double.infinity,
          );
    return ClipRect(
      child: duration == Duration.zero
          ? content
          : AnimatedSize(
              duration: duration,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: content,
            ),
    );
  }
}

class ThinkingActivityGroup extends StatelessWidget {
  const ThinkingActivityGroup({
    required this.turn,
    required this.activities,
    required this.width,
    required this.controller,
    required this.isResponding,
    this.forceCompleted = false,
    super.key,
  });

  final ConversationTurn turn;
  final List<TranscriptBlock> activities;
  final double width;
  final ZommiController controller;
  final bool isResponding;
  final bool forceCompleted;

  String get groupId => activities.first.id;
  String get id => '${turn.id}-$groupId';

  @override
  Widget build(BuildContext context) {
    final expanded = turn.isActivityGroupExpanded(groupId);
    // A new reasoning phase closes older tool work without creating another
    // section. Individual items retain their own completion state.
    var activePhaseStart = 0;
    var sawTool = false;
    for (var index = 0; index < activities.length; index++) {
      if (activities[index].kind == TranscriptKind.tool) {
        sawTool = true;
      } else if (activities[index].kind == TranscriptKind.thinking && sawTool) {
        activePhaseStart = index;
        sawTool = false;
      }
    }
    // Keep the last section active through gaps and answer streaming until the
    // response ends, even when every thinking/tool item has already completed.
    final completed = !isResponding;
    final toolCount = activities
        .where((activity) => activity.kind == TranscriptKind.tool)
        .length;
    return Semantics(
      container: true,
      label: 'Thinking ${completed ? 'completed' : 'in progress'}',
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(width: width),
          child: Container(
            key: ValueKey('activity-section-$id'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
            child: Stack(
              children: [
                if (!completed)
                  Positioned.fill(
                    child: ThinkingFlowBackground(
                      key: ValueKey('thinking-flow-$id'),
                    ),
                  ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      key: ValueKey('thinking-toggle-$id'),
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => controller.setTurnActivityExpanded(
                        turn,
                        !expanded,
                        groupId: groupId,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.auto_awesome_rounded,
                              size: 15,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Thinking',
                                style: chatTextStyleOf(context).copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (toolCount > 0)
                              Text(
                                '$toolCount tool${toolCount == 1 ? '' : 's'}',
                                key: const ValueKey('thinking-tool-count'),
                                style: chatTextStyleOf(context).copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            if (toolCount > 0) const SizedBox(width: 8),
                            if (!completed)
                              Icon(
                                Icons.more_horiz_rounded,
                                size: 15,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              )
                            else
                              const Icon(
                                Icons.check_circle_outline_rounded,
                                size: 15,
                                color: Color(0xff659071),
                              ),
                            const SizedBox(width: 5),
                            Icon(
                              expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 17,
                            ),
                          ],
                        ),
                      ),
                    ),
                    _ExpandableActivityBody(
                      key: ValueKey('thinking-fold-$id'),
                      expanded: expanded,
                      duration: completed
                          ? const Duration(milliseconds: 150)
                          : Duration.zero,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                        child: turn.historySummary
                            ? turn.historyLoading
                                  ? const Text('Loading activity…')
                                  : TextButton(
                                      onPressed: () =>
                                          controller.loadTurnHistory(turn),
                                      child: Text(
                                        turn.historyError ?? 'Load activity',
                                      ),
                                    )
                            : _ActivityList(
                                activities: activities,
                                controller: controller,
                                forceCompleted: forceCompleted,
                                completedBefore: activePhaseStart,
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityList extends StatefulWidget {
  const _ActivityList({
    required this.activities,
    required this.controller,
    required this.forceCompleted,
    required this.completedBefore,
  });

  final List<TranscriptBlock> activities;
  final ZommiController controller;
  final bool forceCompleted;
  final int completedBefore;

  @override
  State<_ActivityList> createState() => _ActivityListState();
}

class _ActivityListState extends State<_ActivityList> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ActivityList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_scroll.hasClients && _scroll.position.extentBefore <= 36) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(0);
        }
      });
    }
  }

  Widget _item(int index) {
    final activity = widget.activities[index];
    final completed = widget.forceCompleted || index < widget.completedBefore;
    return RepaintBoundary(
      key: ValueKey(activity.id),
      child: activity.kind == TranscriptKind.thinking
          ? _ThinkingActivitySubItem(
              block: activity,
              controller: widget.controller,
              forceCompleted: completed,
            )
          : _ToolActivitySubItem(
              block: activity,
              controller: widget.controller,
              forceCompleted: completed,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.activities.length <= 8) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(widget.activities.length, _item),
      );
    }
    return SizedBox(
      height: 360,
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          key: const ValueKey('thinking-activity-list'),
          controller: _scroll,
          primary: false,
          reverse: true,
          itemCount: widget.activities.length,
          findChildIndexCallback: (key) {
            final index = widget.activities.indexWhere(
              (activity) => ValueKey(activity.id) == key,
            );
            return index < 0 ? null : widget.activities.length - 1 - index;
          },
          itemBuilder: (_, index) =>
              _item(widget.activities.length - 1 - index),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}

class _ThinkingActivitySubItem extends StatelessWidget {
  const _ThinkingActivitySubItem({
    required this.block,
    required this.controller,
    required this.forceCompleted,
  });

  final TranscriptBlock block;
  final ZommiController controller;
  final bool forceCompleted;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('activity-${block.id}'),
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.fromLTRB(9, 4, 9, 5),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh
            .withValues(alpha: .65),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 14,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  block.title,
                  overflow: TextOverflow.ellipsis,
                  style: chatTextStyleOf(context).copyWith(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!forceCompleted && !block.completed)
                const SizedBox.square(
                  dimension: 11,
                  child: RepaintBoundary(
                    child: CircularProgressIndicator(strokeWidth: 1.4),
                  ),
                )
              else
                const Icon(
                  Icons.check_rounded,
                  size: 14,
                  color: Color(0xff659071),
                ),
            ],
          ),
          if (block.text.isNotEmpty) ...[
            const SizedBox(height: 3),
            CopyableMarkdown(
              text: block.text,
              compact: true,
              showCopyAction: false,
              showCodeCopyAction: false,
              onCopy: controller.copyText,
              onOpenLink: controller.openExternalLink,
            ),
          ],
          for (final artifact in block.artifacts)
            ArtifactCard(
              artifact: artifact,
              controller: controller,
              showCopyAction: false,
            ),
        ],
      ),
    );
  }
}

class _ToolActivitySubItem extends StatelessWidget {
  const _ToolActivitySubItem({
    required this.block,
    required this.controller,
    required this.forceCompleted,
  });

  final TranscriptBlock block;
  final ZommiController controller;
  final bool forceCompleted;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('activity-${block.id}'),
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh
            .withValues(alpha: .65),
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
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.build_outlined,
                    size: 14,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      activityBlockTitle(block),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: chatTextStyleOf(context).copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!forceCompleted && !block.completed)
                    const SizedBox.square(
                      dimension: 11,
                      child: RepaintBoundary(
                        child: CircularProgressIndicator(strokeWidth: 1.4),
                      ),
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
          _ExpandableActivityBody(
            expanded: block.expanded,
            // Tool output can stream just like reasoning. Animating each delta
            // makes the card and its surrounding thinking edge chase the text.
            duration: forceCompleted || block.completed
                ? const Duration(milliseconds: 130)
                : Duration.zero,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 9, 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (block.text.isNotEmpty)
                    CopyableMarkdown(
                      text: block.text,
                      compact: true,
                      showCopyAction: false,
                      showCodeCopyAction: false,
                      onCopy: controller.copyText,
                      onOpenLink: controller.openExternalLink,
                    ),
                  for (final artifact in block.artifacts)
                    ArtifactCard(
                      artifact: artifact,
                      controller: controller,
                      showCopyAction: false,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AssistantBlockView extends StatelessWidget {
  const AssistantBlockView({
    required this.block,
    required this.width,
    required this.runtimeName,
    required this.controller,
    this.showActions = false,
    this.tableWidth,
    this.proseInset = 0,
    super.key,
  });

  final TranscriptBlock block;
  final double width;
  final double? tableWidth;
  final double proseInset;
  final String runtimeName;
  final ZommiController controller;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$runtimeName response',
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tableWidth ?? width),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: ValueKey('assistant-${block.id}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 5,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CopyableMarkdown(
                      text: block.text,
                      proseWidth: math.max(0, width - 26),
                      proseInset: proseInset,
                      showCopyAction: false,
                      showCodeCopyAction: false,
                      onCopy: controller.copyText,
                      onOpenLink: controller.openExternalLink,
                    ),
                    for (final artifact in block.artifacts)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: proseInset),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: width - 26),
                          child: ArtifactCard(
                            artifact: artifact,
                            controller: controller,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (showActions)
                Padding(
                  padding: EdgeInsets.only(left: proseInset),
                  child: MessageActions(
                    key: ValueKey('assistant-actions-${block.id}'),
                    text: block.text,
                    timestamp: block.createdAt,
                    onCopy: controller.copyText,
                  ),
                ),
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
    required this.width,
    required this.controller,
    super.key,
  });

  final TranscriptBlock block;
  final double width;
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
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Container(
            key: ValueKey('activity-${block.id}'),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () =>
                      controller.setBlockExpanded(block, !block.expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: 15,
                          color: block.kind == TranscriptKind.error
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            block.title,
                            overflow: TextOverflow.ellipsis,
                            style: chatTextStyleOf(context).copyWith(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (!completed)
                          const SizedBox.square(
                            dimension: 13,
                            child: RepaintBoundary(
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
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
                _ExpandableActivityBody(
                  expanded: block.expanded,
                  duration: const Duration(milliseconds: 150),
                  child: ConstrainedBox(
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
                              showCopyAction: false,
                              showCodeCopyAction: false,
                              onCopy: controller.copyText,
                              onOpenLink: controller.openExternalLink,
                            ),
                          for (final artifact in block.artifacts)
                            ArtifactCard(
                              artifact: artifact,
                              controller: controller,
                              showCopyAction: false,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ArtifactCard extends StatefulWidget {
  const ArtifactCard({
    required this.artifact,
    required this.controller,
    this.showCopyAction = true,
    super.key,
  });

  final ArtifactPreview artifact;
  final ZommiController controller;
  final bool showCopyAction;

  @override
  State<ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<ArtifactCard> {
  ArtifactPreview? _loaded;
  Object? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ArtifactCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.artifact;
    final current = widget.artifact;
    if (previous.id != current.id ||
        previous.path != current.path ||
        previous.html != current.html ||
        previous.dataUrl != current.dataUrl ||
        previous.cwd != current.cwd) {
      _loaded = null;
      _error = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      final value = await widget.controller.artifactLoader.load(
        widget.artifact,
        target: widget.controller.activeRuntime,
      );
      if (mounted && generation == _loadGeneration) {
        setState(() => _loaded = value);
      }
    } on Object catch (error) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _error = error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final artifact = _loaded ?? widget.artifact;
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('artifact-${artifact.id}'),
      margin: const EdgeInsets.only(top: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    switch (artifact.kind) {
                      'html' => 'HTML',
                      'markdown' => 'Markdown',
                      _ => 'Image',
                    },
                    style: TextStyle(
                      color: colors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Tooltip(
                    message: artifact.path ?? artifact.title,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artifact.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        if (artifact.path case final path?)
                          Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (widget.showCopyAction &&
                    artifact.kind == 'image' &&
                    artifact.dataUrl != null)
                  IconButton(
                    tooltip: 'Copy image',
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => unawaited(
                      widget.controller.copyImage(artifact.dataUrl!),
                    ),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(fontSize: 12),
                  ),
                  onPressed: _error == null
                      ? () =>
                            unawaited(widget.controller.showArtifact(artifact))
                      : null,
                  icon: const Icon(Icons.open_in_full_rounded, size: 13),
                  label: const Text('Preview'),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: artifact.kind == 'image'
                  ? 150
                  : math.min(180, constraints.maxWidth * 9 / 16),
              child: _error != null
                  ? Center(child: Text('Preview unavailable · $_error'))
                  : (artifact.kind == 'html' || artifact.kind == 'markdown') &&
                        artifact.html != null
                  ? GestureDetector(
                      onTap: () =>
                          unawaited(widget.controller.showArtifact(artifact)),
                      child: DocumentThumbnail(
                        key: ValueKey(artifact.id),
                        artifact: artifact,
                      ),
                    )
                  : ArtifactSurface(artifact: artifact, compact: true),
            ),
          ),
        ],
      ),
    );
  }
}
