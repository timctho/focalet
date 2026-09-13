import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zommi_flutter/diagnostics/scroll_performance.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';

const double userMessageBoxWidth = 416;
const double assistantMessageBoxWidth = 496;
const double _baselineMessageViewportWidth = 720;
const double _transcriptHorizontalInsets = 48;

double responsiveUserMessageBoxWidth(double viewportWidth) {
  final growth = math.max(0, viewportWidth - _baselineMessageViewportWidth);
  return math.min(
    math.max(0, viewportWidth - _transcriptHorizontalInsets),
    userMessageBoxWidth + growth * 0.62,
  );
}

double responsiveAssistantMessageBoxWidth(double viewportWidth) {
  final growth = math.max(0, viewportWidth - _baselineMessageViewportWidth);
  return math.min(
    math.max(0, viewportWidth - _transcriptHorizontalInsets),
    assistantMessageBoxWidth + growth * 0.74,
  );
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
    if (position.pixels <= 96 && _start > 0 && !_loadScheduled) {
      _loadScheduled = true;
      final epoch = _rangeEpoch;
      final oldExtent = position.maxScrollExtent;
      final oldPixels = position.pixels;
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
    }
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

  Widget _turnView(ConversationTurn turn, double viewportWidth) {
    // Only visible rows are fingerprinted. Keep completed rows' widget trees
    // unchanged when another row streams, while preserving folds and updates.
    final isResponding =
        widget.controller.turnActive &&
        identical(turn, widget.controller.turns.last);
    final revision = Object.hash(
      isResponding,
      transcriptContentRevision([turn], visibleOnly: true),
      turn.activityExpanded,
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
        cached.runtimeName == runtimeName) {
      return _retain(turn, cached.view);
    }
    final view = ConversationTurnView(
      key: ValueKey('turn-${turn.id}'),
      turn: turn,
      viewportWidth: viewportWidth,
      runtimeName: runtimeName,
      controller: widget.controller,
      isResponding: isResponding,
      onAttachmentEnter: _attachmentEnter,
      onAttachmentExit: _attachmentExit,
    );
    _turnViews[turn.id] = (
      revision: revision,
      width: viewportWidth,
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
                return _turnView(turn, constraints.maxWidth);
              },
            ),
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
    super.key,
  });

  final ConversationTurn turn;
  final double viewportWidth;
  final String runtimeName;
  final ZommiController controller;
  final AttachmentHoverCallback onAttachmentEnter;
  final ValueChanged<ContextAttachment> onAttachmentExit;
  final bool isResponding;

  @override
  Widget build(BuildContext context) {
    ScrollPerformance.count('turnBuild');
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
                constraints: BoxConstraints(
                  maxWidth: responsiveUserMessageBoxWidth(viewportWidth),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color:
                      Theme.of(context)
                              .extension<ZommiVisualSettings>()
                              ?.themeColor ==
                          ZommiThemeColor.violet
                      ? const Color(0xffe9e7f8)
                      : Color.alphaBlend(
                          Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.10),
                          const Color(0xfff2f3f8),
                        ),
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
                          turn.contextTokens.join(' '),
                          style: const TextStyle(
                            color: Color(0xff6d639f),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    if (turn.attachments.isNotEmpty)
                      InlineAttachmentMessage(
                        key: ValueKey('inline-user-message-${turn.id}'),
                        text:
                            turn.inlineUserText.contains(inlineAttachmentMarker)
                            ? turn.inlineUserText
                            : '${turn.userText}\n${List.filled(turn.attachments.length, inlineAttachmentMarker).join(' ')}',
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
            for (final segment in segments)
              if (!segment.first.kind.isFoldedActivity)
                Padding(
                  key: ValueKey('message-segment-${segment.first.id}'),
                  padding: const EdgeInsets.only(bottom: 9),
                  child: segment.first.kind.isMessage
                      ? AssistantBlockView(
                          block: segment.first,
                          width: responsiveAssistantMessageBoxWidth(
                            viewportWidth,
                          ),
                          runtimeName: runtimeName,
                          controller: controller,
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
                  padding: const EdgeInsets.only(bottom: 9),
                  child: ThinkingActivityGroup(
                    turn: turn,
                    activities: segment,
                    width: responsiveAssistantMessageBoxWidth(viewportWidth),
                    controller: controller,
                  ),
                ),
            if (showTyping)
              Align(
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
                        color: const Color(0x80ffffff),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const RepaintBoundary(child: TypingDots()),
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
                    ? const Color(0xff747988)
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
                  block.kind,
                  block.completed,
                  block.text.trim().isNotEmpty || block.artifacts.isNotEmpty,
                ]
              : <Object?>[
                  block.id,
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
    final duplicateIndex = block.kind == TranscriptKind.assistant
        ? result.indexWhere(
            (existing) =>
                existing.kind == TranscriptKind.assistant &&
                transcriptTextSnapshotsOverlap(existing.text, block.text),
          )
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
    super.key,
  });

  final ConversationTurn turn;
  final List<TranscriptBlock> activities;
  final double width;
  final ZommiController controller;

  String get groupId => activities.first.id;
  String get id => '${turn.id}-$groupId';

  @override
  Widget build(BuildContext context) {
    final expanded = turn.isActivityGroupExpanded(groupId);
    final completed = activities.every((activity) => activity.completed);
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
            decoration: BoxDecoration(
              color: const Color(0x80ffffff),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xffe2e5ed)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  key: ValueKey('thinking-toggle-$id'),
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => controller.setTurnActivityExpanded(
                    turn,
                    !expanded,
                    groupId: groupId,
                  ),
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
                        Expanded(
                          child: Text(
                            'Thinking',
                            style: chatTextStyleOf(context).copyWith(
                              color: Color(0xff4b5060),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (toolCount > 0)
                          Text(
                            '$toolCount tool${toolCount == 1 ? '' : 's'}',
                            key: const ValueKey('thinking-tool-count'),
                            style: chatTextStyleOf(context)
                                .copyWith(color: Color(0xff747988)),
                          ),
                        if (toolCount > 0) const SizedBox(width: 8),
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
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: _ActivityList(
                      activities: activities,
                      controller: controller,
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

class _ActivityList extends StatefulWidget {
  const _ActivityList({required this.activities, required this.controller});

  final List<TranscriptBlock> activities;
  final ZommiController controller;

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

  Widget _item(TranscriptBlock activity) => RepaintBoundary(
    key: ValueKey(activity.id),
    child: activity.kind == TranscriptKind.thinking
        ? _ThinkingActivitySubItem(
            block: activity,
            controller: widget.controller,
          )
        : _ToolActivitySubItem(block: activity, controller: widget.controller),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.activities.length <= 8) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: widget.activities.map(_item).toList(growable: false),
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
              _item(widget.activities[widget.activities.length - 1 - index]),
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
  });

  final TranscriptBlock block;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('activity-${block.id}'),
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 9),
      decoration: BoxDecoration(
        color: const Color(0x52f3f1fb),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 14,
                color: Color(0xff746b99),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  block.title,
                  overflow: TextOverflow.ellipsis,
                  style: chatTextStyleOf(context).copyWith(
                    color: const Color(0xff4b5060),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!block.completed)
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
            const SizedBox(height: 5),
            CopyableMarkdown(
              text: block.text,
              compact: true,
              onCopy: controller.copyText,
              onOpenLink: controller.openExternalLink,
            ),
          ],
          for (final artifact in block.artifacts)
            ArtifactCard(artifact: artifact, controller: controller),
        ],
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
                      activityBlockTitle(block),
                      overflow: TextOverflow.ellipsis,
                      style: chatTextStyleOf(context).copyWith(
                        color: Color(0xff4b5060),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!block.completed)
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
            duration: const Duration(milliseconds: 130),
            child: Padding(
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
    super.key,
  });

  final TranscriptBlock block;
  final double width;
  final String runtimeName;
  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$runtimeName response',
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width),
          child: Container(
            key: ValueKey('assistant-${block.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xb3ffffff),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x99ffffff)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  onTap: () =>
                      controller.setBlockExpanded(block, !block.expanded),
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
                            style: chatTextStyleOf(context).copyWith(
                              color: Color(0xff4b5060),
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
