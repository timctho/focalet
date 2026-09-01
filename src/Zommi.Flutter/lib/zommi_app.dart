import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';

const double compactOrbSize = 56;
const double expandedPanelWidth = 720;
const double expandedPanelHeight = 620;
const double bottomAnchorInset = windowBottomInset;
const Duration hoverCollapseDelay = Duration(milliseconds: 500);
const Duration previewHideDelay = Duration(milliseconds: 260);
const String codexUiFontFamily = 'Segoe UI Variable Text';
const List<String> codexUiFontFallback = ['Segoe UI', 'Inter', 'Arial'];

class ZommiApp extends StatelessWidget {
  const ZommiApp({
    required this.core,
    this.desktop = const NoopDesktopBridge(),
    this.artifactLoader,
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff8178c9),
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: Colors.transparent,
      useMaterial3: true,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zommi',
      theme: theme.copyWith(
        textTheme: _compactTextTheme(theme.textTheme),
        visualDensity: VisualDensity.compact,
      ),
      home: ZommiShell(
        core: core,
        desktop: desktop,
        artifactLoader: artifactLoader,
      ),
    );
  }
}

TextTheme _compactTextTheme(TextTheme base) {
  TextStyle sized(TextStyle? style, double size) =>
      (style ?? const TextStyle()).copyWith(
        fontSize: size,
        fontFamily: codexUiFontFamily,
        fontFamilyFallback: codexUiFontFallback,
      );
  return base.copyWith(
    displayLarge: sized(base.displayLarge, 46),
    displayMedium: sized(base.displayMedium, 36),
    displaySmall: sized(base.displaySmall, 29),
    headlineLarge: sized(base.headlineLarge, 25),
    headlineMedium: sized(base.headlineMedium, 21),
    headlineSmall: sized(base.headlineSmall, 18),
    titleLarge: sized(base.titleLarge, 17),
    titleMedium: sized(base.titleMedium, 13),
    titleSmall: sized(base.titleSmall, 11.5),
    bodyLarge: sized(base.bodyLarge, 12),
    bodyMedium: sized(base.bodyMedium, 11.5),
    bodySmall: sized(base.bodySmall, 10),
    labelLarge: sized(base.labelLarge, 11.5),
    labelMedium: sized(base.labelMedium, 10.5),
    labelSmall: sized(base.labelSmall, 9.5),
  );
}

class ZommiShell extends StatefulWidget {
  const ZommiShell({
    required this.core,
    this.desktop = const NoopDesktopBridge(),
    this.artifactLoader,
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;

  @override
  State<ZommiShell> createState() => _ZommiShellState();
}

class _ZommiShellState extends State<ZommiShell> {
  late final InlineAttachmentTextController _composer;
  final FocusNode _composerFocus = FocusNode(debugLabel: 'Zommi composer');
  late final ZommiController _controller;
  final Object _sessionTapGroup = Object();
  final Object _runtimeTapGroup = Object();
  final Object _modelTapGroup = Object();
  Timer? _collapseTimer;
  Timer? _previewTimer;
  Timer? _sessionTimer;
  int _lastFocusEpoch = 0;
  bool _draggingWindow = false;

  @override
  void initState() {
    super.initState();
    _controller = ZommiController(
      core: widget.core,
      desktop: widget.desktop,
      artifactLoader: widget.artifactLoader,
    );
    _composer = InlineAttachmentTextController(
      onAttachmentRemoved: (attachment) =>
          _controller.removeAttachment(attachment.id),
      onAttachmentEnter: _showAttachmentPreview,
      onAttachmentExit: (_) => _schedulePreviewClose(),
    );
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize());
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _composer.syncAttachments(_controller.attachments);
    if (_lastFocusEpoch != _controller.focusComposerEpoch) {
      _lastFocusEpoch = _controller.focusComposerEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.expanded) _composerFocus.requestFocus();
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _previewTimer?.cancel();
    _sessionTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    unawaited(_controller.close());
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  Future<void> _expand({bool focus = true}) async {
    _collapseTimer?.cancel();
    await _controller.setExpanded(true, focus: focus);
    if (focus && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _composerFocus.requestFocus();
      });
    }
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(hoverCollapseDelay, () {
      if (!mounted || _draggingWindow) return;
      _composerFocus.unfocus();
      _controller.closeTransientPanels();
      _controller.hideAttachmentPreview();
      unawaited(_controller.setExpanded(false));
    });
  }

  Future<void> _startWindowDrag() async {
    _collapseTimer?.cancel();
    _draggingWindow = true;
    try {
      await _controller.startDragging();
    } finally {
      _draggingWindow = false;
    }
  }

  void _schedulePreviewClose() {
    _previewTimer?.cancel();
    _previewTimer = Timer(previewHideDelay, _controller.hideAttachmentPreview);
  }

  void _showAttachmentPreview(ContextAttachment attachment) {
    _previewTimer?.cancel();
    _controller.showAttachmentPreview(attachment);
  }

  void _openSessions() {
    _sessionTimer?.cancel();
    _controller.toggleSessionPanel(true);
  }

  void _scheduleSessionsClose() {
    _sessionTimer?.cancel();
    _sessionTimer = Timer(
      hoverCollapseDelay,
      () => _controller.toggleSessionPanel(false),
    );
  }

  void _submit() {
    final text = _composer.messageText;
    if (text.isEmpty ||
        _controller.submitting ||
        _controller.turnActive ||
        _controller.activeRuntime == null ||
        _controller.activeSessionId == null) {
      return;
    }
    final submission = _controller.submit(
      text,
      inlineMessage: _composer.inlineText,
      attachmentOrder: _composer.inlineAttachments
          .map((attachment) => attachment.id)
          .toList(growable: false),
    );
    _composer.clearAfterSubmit();
    unawaited(submission);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_controller.previewArtifact != null) {
        _controller.closeArtifact();
      } else if (_controller.runtimePanelOpen ||
          _controller.modelPanelOpen ||
          _controller.sessionPanelOpen) {
        _controller.closeTransientPanels();
      } else {
        unawaited(_controller.hideWindow());
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !_controller.turnActive) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final fromSize = zommiSurfaceSize(
      expanded: _controller.expanded,
      large: _controller.largePanel,
    );
    final toSize = zommiSurfaceSize(
      expanded: _controller.transitionTargetExpanded,
      large: _controller.transitionTargetLarge,
    );
    final renderExpanded =
        _controller.expanded ||
        (_controller.surfaceTransitioning &&
            _controller.transitionTargetExpanded);
    final renderLarge =
        _controller.largePanel ||
        (_controller.surfaceTransitioning && _controller.transitionTargetLarge);
    final width = renderExpanded
        ? (renderLarge ? largeWindowSize.width : expandedPanelWidth)
        : compactOrbSize;
    final height = renderExpanded
        ? (renderLarge ? largeWindowSize.height : expandedPanelHeight)
        : compactOrbSize;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        onKeyEvent: _handleKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              // The native window grows upward from one bottom-centre anchor.
              // Keep the Flutter surface on that same anchor even during the
              // one frame where Win32 and Flutter have different sizes. If
              // this is centred, the compact morph is clipped out before the
              // enlarged backing surface arrives and appears to jump.
              alignment: _controller.surfaceTransitioning
                  ? Alignment.bottomCenter
                  : Alignment.center,
              child: MouseRegion(
                onEnter: (_) => unawaited(_expand()),
                onExit: (_) => _scheduleCollapse(),
                child: SizedBox(
                  key: const ValueKey('zommi-surface'),
                  width: width,
                  height: height,
                  child: ClipRect(
                    child: _controller.surfaceTransitioning
                        ? _SurfaceTransitionView(
                            fromSize: fromSize,
                            toSize: toSize,
                            animate: _controller.surfaceTransitionAnimating,
                            working: _controller.anyTurnActive,
                            loading: _controller.starting,
                            panelSize: Size(width, height),
                            panel: RepaintBoundary(
                              child: _buildPanel(width, height),
                            ),
                          )
                        : _controller.expanded
                        ? OverflowBox(
                            alignment: Alignment.center,
                            minWidth: width,
                            maxWidth: width,
                            minHeight: height,
                            maxHeight: height,
                            child: _buildPanel(width, height),
                          )
                        : _CompactOrbButton(
                            working: _controller.anyTurnActive,
                            loading: _controller.starting,
                            onPressed: () => unawaited(_expand()),
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

  Widget _buildPanel(double width, double height) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xeaf9fbff),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: const Color(0xccffffff)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x240d172a),
              blurRadius: 42,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: TranscriptPane(
                          key: ValueKey(
                            'transcript-${_controller.activeSessionId}',
                          ),
                          controller: _controller,
                          onAttachmentEnter: _showAttachmentPreview,
                          onAttachmentExit: (_) => _schedulePreviewClose(),
                        ),
                      ),
                      if (_controller.runtimePanelOpen)
                        Positioned(
                          top: 2,
                          left: math.max(18, (width - 420) / 2),
                          child: TapRegion(
                            groupId: _runtimeTapGroup,
                            child: RuntimePanel(controller: _controller),
                          ),
                        ),
                      if (_controller.modelPanelOpen)
                        Positioned(
                          top: 2,
                          right: 20,
                          child: TapRegion(
                            groupId: _modelTapGroup,
                            child: ModelPanel(controller: _controller),
                          ),
                        ),
                      if (_controller.previewAttachment case final attachment?)
                        Positioned(
                          right: 22,
                          bottom: 12,
                          child: ContextPreviewPanel(
                            attachment: attachment,
                            onClose: _controller.hideAttachmentPreview,
                            onPointerEnter: () => _previewTimer?.cancel(),
                            onPointerExit: _schedulePreviewClose,
                          ),
                        ),
                      if (_controller.starting || _controller.runtimeBusy)
                        Positioned(
                          top: 10,
                          left: 0,
                          right: 0,
                          child: IgnorePointer(
                            child: Center(
                              child: _LoadingPill(
                                label: _controller.starting
                                    ? 'Waking Zommi…'
                                    : _controller.status,
                              ),
                            ),
                          ),
                        ),
                      if (_controller.approval != null)
                        Positioned.fill(
                          child: ColoredBox(
                            color: const Color(0x220d172a),
                            child: Center(
                              child: ApprovalDialogCard(
                                controller: _controller,
                              ),
                            ),
                          ),
                        ),
                      if (_controller.question != null)
                        Positioned.fill(
                          child: ColoredBox(
                            color: const Color(0x220d172a),
                            child: Center(
                              child: QuestionDialogCard(
                                key: ValueKey(_controller.question!.id),
                                controller: _controller,
                              ),
                            ),
                          ),
                        ),
                      if (_controller.previewArtifact != null)
                        ArtifactViewerDialog(controller: _controller),
                    ],
                  ),
                ),
                _buildComposer(),
                if (_controller.activeSessionId != null)
                  Semantics(
                    container: true,
                    label: 'Exact agent session bound',
                    child: const SizedBox(width: 1, height: 1),
                  ),
                _buildFooter(),
              ],
            ),
            if (_controller.sessionPanelOpen)
              Positioned(
                left: 18,
                top: 58,
                bottom: 14,
                width: width / 2,
                child: TapRegion(
                  groupId: _sessionTapGroup,
                  child: SessionSidebar(
                    controller: _controller,
                    onPointerEnter: () => _sessionTimer?.cancel(),
                    onPointerExit: _scheduleSessionsClose,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 62,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 7),
        child: Row(
          children: [
            _HeaderButton(
              key: const ValueKey('hide-zommi'),
              label: 'Hide Zommi',
              icon: Icons.close_rounded,
              onPressed: () => unawaited(_controller.hideWindow()),
            ),
            TapRegion(
              groupId: _sessionTapGroup,
              onTapOutside: (_) => _controller.dismissSessionPanel(),
              child: MouseRegion(
                onEnter: (_) => _openSessions(),
                onExit: (_) => _scheduleSessionsClose(),
                child: _HeaderButton(
                  key: const ValueKey('toggle-sessions'),
                  label: _controller.sessionPanelOpen
                      ? 'Chat sessions — visible while hovered'
                      : 'Chat sessions — hover to show',
                  icon: Icons.menu_rounded,
                  onPressed: _controller.sessionNavigationSupported
                      ? _openSessions
                      : null,
                ),
              ),
            ),
            TapRegion(
              groupId: _runtimeTapGroup,
              onTapOutside: (_) => _controller.dismissRuntimePanel(),
              child: _SummaryButton(
                key: const ValueKey('runtime-summary'),
                label: _controller.runtimeSummary,
                semanticLabel: 'Choose agent runtime',
                warning: _controller.statusWarning,
                loading: _controller.runtimeBusy,
                onPressed: _controller.toggleRuntimePanel,
              ),
            ),
            if (_controller.modelSelectionSupported) ...[
              const SizedBox(width: 5),
              TapRegion(
                groupId: _modelTapGroup,
                onTapOutside: (_) => _controller.dismissModelPanel(),
                child: _SummaryButton(
                  key: const ValueKey('model-summary'),
                  label: _controller.modelSummary,
                  semanticLabel: 'Choose model and reasoning level',
                  onPressed: _controller.toggleModelPanel,
                ),
              ),
            ],
            Expanded(
              child: GestureDetector(
                key: const ValueKey('window-drag-region'),
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => unawaited(_startWindowDrag()),
                child: const SizedBox.expand(),
              ),
            ),
            _HeaderButton(
              key: const ValueKey('expand-zommi'),
              label: _controller.largePanel ? 'Restore Zommi' : 'Expand Zommi',
              icon: _controller.largePanel
                  ? Icons.close_fullscreen_rounded
                  : Icons.open_in_full_rounded,
              onPressed: () => unawaited(_controller.toggleLargePanel()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    return Semantics(
      container: true,
      label: 'Message composer',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xe6ffffff),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xffe1e4ed)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x160d172a),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                button: true,
                label: 'Select image context',
                child: IconButton(
                  key: const ValueKey('select-image'),
                  tooltip: _controller.imageInputSupported
                      ? 'Select image context'
                      : '${_controller.activeRuntimeName} does not accept image input',
                  onPressed: _controller.imageInputSupported
                      ? () => unawaited(_controller.addImageContext())
                      : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('zommi-composer'),
                  focusNode: _composerFocus,
                  controller: _composer,
                  enabled: !_controller.sessionBusy,
                  minLines: 1,
                  maxLines: 5,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textAlignVertical: TextAlignVertical.center,
                  style: const TextStyle(fontSize: 12, height: 1.3),
                  decoration: const InputDecoration(
                    hintText: 'Ask your agent',
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 5),
              if (_controller.turnActive)
                Semantics(
                  label: 'Stop active turn',
                  button: true,
                  child: IconButton.filled(
                    key: const ValueKey('stop-turn'),
                    tooltip: _controller.activeTurnStopping
                        ? 'Stopping response'
                        : 'Stop response',
                    onPressed: _controller.activeTurnStopping
                        ? null
                        : () => unawaited(_controller.interrupt()),
                    icon: Icon(
                      _controller.activeTurnStopping
                          ? Icons.hourglass_top_rounded
                          : Icons.stop_rounded,
                    ),
                  ),
                )
              else
                Semantics(
                  label: _controller.submitting
                      ? 'Preparing context'
                      : 'Send message',
                  button: true,
                  child: IconButton.filled(
                    key: const ValueKey('send-message'),
                    tooltip: 'Send',
                    onPressed: _controller.submitting ? null : _submit,
                    icon: Icon(
                      _controller.submitting
                          ? Icons.more_horiz
                          : Icons.arrow_upward_rounded,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    final shortcuts = [
      _controller.contextShortcutRegistered
          ? 'Alt+A context'
          : 'Alt+A unavailable',
      _controller.imageShortcutRegistered
          ? 'Alt+Shift+A image'
          : 'Alt+Shift+A unavailable',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(26, 0, 26, 13),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: _controller.statusWarning
                  ? const Color(0xffcf805f)
                  : _controller.turnActive
                  ? const Color(0xff8f83ce)
                  : const Color(0xff66a27b),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Semantics(
              liveRegion: true,
              label: 'Agent status: ${_controller.status}',
              child: Text(
                _controller.status,
                key: const ValueKey('core-status'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _controller.statusWarning
                      ? const Color(0xffa2543f)
                      : const Color(0xff6d7280),
                  fontSize: 11,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            shortcuts,
            key: const ValueKey('shortcut-status'),
            style: const TextStyle(color: Color(0xff7b808d), fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _LoadingPill extends StatelessWidget {
  const _LoadingPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xf7ffffff),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xffdedbea)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1f554b7a),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 14, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ZommiOrb(
              key: ValueKey('loading-orb'),
              loading: true,
              size: 28,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              key: const ValueKey('loading-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xff514a70),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryButton extends StatelessWidget {
  const _SummaryButton({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.warning = false,
    this.loading = false,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;
  final bool warning;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xff4c5160),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(fontSize: 11),
        ),
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: loading
              ? const SizedBox.square(
                  key: ValueKey('runtime-loading-indicator'),
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Container(
                  key: const ValueKey('runtime-status-dot'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: warning
                        ? const Color(0xffcf805f)
                        : const Color(0xff66a27b),
                    shape: BoxShape.circle,
                  ),
                ),
        ),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 170),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class _CompactOrbButton extends StatelessWidget {
  const _CompactOrbButton({
    required this.working,
    required this.loading,
    required this.onPressed,
  });

  final bool working;
  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'ZommiOrb',
      hint: loading
          ? 'Zommi is starting'
          : working
          ? 'Open Zommi chat, agent working'
          : 'Open Zommi chat',
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('zommi-orb'),
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: ZommiOrb(working: working, loading: loading),
        ),
      ),
    );
  }
}

Size zommiSurfaceSize({required bool expanded, required bool large}) =>
    expanded ? (large ? largeWindowSize : normalWindowSize) : compactWindowSize;

double symmetricSurfaceEase(double progress) {
  final value = progress.clamp(0.0, 1.0);
  return value < 0.5
      ? 4 * value * value * value
      : 1 - math.pow(-2 * value + 2, 3).toDouble() / 2;
}

Size surfaceTransitionSize(Size from, Size to, double progress) =>
    Size.lerp(from, to, symmetricSurfaceEase(progress))!;

double surfaceTransitionCompactness(Size from, Size to, double progress) {
  final eased = symmetricSurfaceEase(progress);
  final fromCompact = from == compactWindowSize ? 1.0 : 0.0;
  final toCompact = to == compactWindowSize ? 1.0 : 0.0;
  return fromCompact + (toCompact - fromCompact) * eased;
}

double surfaceTransitionCornerRadius(Size size, double compactness) {
  final panelness = 1 - compactness;
  final outer = Offset.zero & size;
  final compactBounds = Rect.fromCenter(
    center: outer.center,
    width: math.min(44, size.width),
    height: math.min(44, size.height),
  );
  final morphBounds = Rect.lerp(compactBounds, outer, panelness)!;
  return compactness * morphBounds.shortestSide / 2 + panelness * 34;
}

class _SurfaceTransitionView extends StatefulWidget {
  const _SurfaceTransitionView({
    required this.fromSize,
    required this.toSize,
    required this.animate,
    required this.working,
    required this.loading,
    required this.panelSize,
    required this.panel,
  });

  final Size fromSize;
  final Size toSize;
  final bool animate;
  final bool working;
  final bool loading;
  final Size panelSize;
  final Widget panel;

  @override
  State<_SurfaceTransitionView> createState() => _SurfaceTransitionViewState();
}

class _SurfaceTransitionViewState extends State<_SurfaceTransitionView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: surfaceTransitionDuration,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _motion.forward();
  }

  @override
  void didUpdateWidget(covariant _SurfaceTransitionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate &&
        (!oldWidget.animate ||
            oldWidget.fromSize != widget.fromSize ||
            oldWidget.toSize != widget.toSize)) {
      _motion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedBuilder(
          animation: _motion,
          builder: (context, child) {
            final progress = _motion.value;
            final size = surfaceTransitionSize(
              widget.fromSize,
              widget.toSize,
              progress,
            );
            final compactness = surfaceTransitionCompactness(
              widget.fromSize,
              widget.toSize,
              progress,
            );
            final panelness = 1 - compactness;
            final radius = surfaceTransitionCornerRadius(size, compactness);
            final contentOpacity = ((panelness - 0.65) / 0.35).clamp(0.0, 1.0);
            return SizedBox.fromSize(
              key: const ValueKey('surface-transition'),
              size: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _SurfaceMorphPainter(
                        compactness: compactness,
                        phase: progress,
                        working: widget.working,
                        loading: widget.loading,
                      ),
                    ),
                    if (contentOpacity > 0)
                      IgnorePointer(
                        child: Opacity(
                          opacity: contentOpacity,
                          child: OverflowBox(
                            alignment: Alignment.bottomCenter,
                            minWidth: widget.panelSize.width,
                            maxWidth: widget.panelSize.width,
                            minHeight: widget.panelSize.height,
                            maxHeight: widget.panelSize.height,
                            child: SizedBox.fromSize(
                              size: widget.panelSize,
                              child: widget.panel,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SurfaceMorphPainter extends CustomPainter {
  const _SurfaceMorphPainter({
    required this.compactness,
    required this.phase,
    required this.working,
    required this.loading,
  });

  final double compactness;
  final double phase;
  final bool working;
  final bool loading;

  @override
  void paint(Canvas canvas, Size size) {
    final panelness = 1 - compactness;
    final outer = Offset.zero & size;
    final compactRect = Rect.fromCenter(
      center: outer.center,
      width: math.min(44, size.width),
      height: math.min(44, size.height),
    );
    final bounds = Rect.lerp(compactRect, outer, panelness)!;
    final radius = surfaceTransitionCornerRadius(size, compactness);
    final shape = RRect.fromRectAndRadius(bounds, Radius.circular(radius));
    canvas.drawRRect(
      shape,
      Paint()
        ..color = Color.lerp(
          const Color(0xff716cae),
          const Color(0xeaf9fbff),
          panelness,
        )!,
    );
    if (compactness > 0) {
      canvas.save();
      canvas.clipRRect(shape);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.28, -0.32),
            radius: 0.95,
            colors: [
              Color.fromRGBO(247, 246, 255, compactness),
              Color.fromRGBO(182, 200, 236, compactness),
              Color.fromRGBO(105, 225, 220, compactness * 0.5),
              Color.fromRGBO(97, 85, 127, compactness),
            ],
            stops: const [0, 0.32, 0.68, 1],
          ).createShader(bounds),
      );
      canvas.restore();
    }
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xd9ffffff),
    );
    if ((working || loading) && compactness > 0.55) {
      final pulse = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
      canvas.drawArc(
        bounds.inflate(3 + pulse),
        phase * math.pi * 2 - math.pi / 2,
        math.pi * 0.72,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = Color.fromRGBO(105, 216, 209, compactness),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SurfaceMorphPainter oldDelegate) =>
      oldDelegate.compactness != compactness ||
      oldDelegate.phase != phase ||
      oldDelegate.working != working ||
      oldDelegate.loading != loading;
}

class ZommiOrb extends StatefulWidget {
  const ZommiOrb({
    this.working = false,
    this.loading = false,
    this.size = compactOrbSize,
    super.key,
  });

  final bool working;
  final bool loading;
  final double size;

  @override
  State<ZommiOrb> createState() => _ZommiOrbState();
}

class _ZommiOrbState extends State<ZommiOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(covariant ZommiOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  void _syncMotion() {
    if ((widget.working || widget.loading) &&
        !MediaQuery.disableAnimationsOf(context)) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion
        ..stop()
        ..value = widget.working || widget.loading ? 0.35 : 0;
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, child) => CustomPaint(
          key: const ValueKey('zommi-orb-canvas'),
          size: Size.square(widget.size),
          painter: _NebulaOrbPainter(
            phase: _motion.value,
            working: widget.working,
            loading: widget.loading,
          ),
        ),
      ),
    );
  }
}

class _NebulaOrbPainter extends CustomPainter {
  const _NebulaOrbPainter({
    required this.phase,
    required this.working,
    required this.loading,
  });

  final double phase;
  final bool working;
  final bool loading;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.39;
    if (working || loading) {
      final breath = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
      final orbitRadius = radius + size.shortestSide * 0.07;
      final orbitBounds = Rect.fromCircle(center: center, radius: orbitRadius);
      canvas.drawCircle(
        center,
        orbitRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = const Color(0x357f79c5),
      );
      canvas.drawArc(
        orbitBounds,
        phase * math.pi * 2 - math.pi / 2,
        math.pi * 0.72,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..color = Color.lerp(
            const Color(0xff7f79c5),
            const Color(0xff69d8d1),
            breath,
          )!,
      );
      if (loading) {
        canvas.drawArc(
          orbitBounds.inflate(size.shortestSide * 0.045),
          -phase * math.pi * 2 + math.pi / 3,
          math.pi * 0.48,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.7
            ..strokeCap = StrokeCap.round
            ..color = Color.lerp(
              const Color(0xffe28bd4),
              const Color(0xff8fddda),
              1 - breath,
            )!,
        );
        canvas.drawCircle(
          center,
          radius + size.shortestSide * (0.11 + breath * 0.025),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0x287f79c5),
        );
      }
      final angle = phase * math.pi * 2 + math.pi * 0.22;
      canvas.drawCircle(
        center.translate(
          math.cos(angle) * orbitRadius,
          math.sin(angle) * orbitRadius,
        ),
        math.max(1.6, size.shortestSide * 0.045),
        Paint()..color = const Color(0xfff8f7ff),
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.28, -0.32),
          radius: 0.95,
          colors: [
            Color(0xfff7f6ff),
            Color(0xffb6c8ec),
            Color(0xff777dc0),
            Color(0xff61557f),
          ],
          stops: [0, 0.32, 0.68, 1],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final drift = working || loading
        ? math.sin(phase * math.pi * 2) * radius * 0.28
        : 0;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius)),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(-radius * 0.16 + drift, -radius * 0.08),
        width: radius * 1.45,
        height: radius * 0.72,
      ),
      Paint()
        ..color = const Color(0x7569e1dc)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center.translate(radius * 0.28 - drift * 0.5, radius * 0.25),
        width: radius * 1.2,
        height: radius * 0.82,
      ),
      Paint()
        ..color = const Color(0x5cdd7bd0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.restore();
    if (working || loading) {
      final pulse = 0.5 + 0.5 * math.cos(phase * math.pi * 2);
      canvas.drawCircle(
        center.translate(radius * 0.15, -radius * 0.18),
        radius * (0.12 + pulse * 0.08),
        Paint()..color = const Color(0xb8ffffff),
      );
    }
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = const Color(0xd9ffffff),
    );
  }

  @override
  bool shouldRepaint(covariant _NebulaOrbPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.working != working ||
      oldDelegate.loading != loading;
}
