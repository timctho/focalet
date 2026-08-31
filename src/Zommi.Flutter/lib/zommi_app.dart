import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';

const double compactOrbSize = 56;
const double expandedPanelWidth = 720;
const double expandedPanelHeight = 620;
const double bottomAnchorInset = windowBottomInset;
const Duration hoverCollapseDelay = Duration(milliseconds: 500);
const Duration previewHideDelay = Duration(milliseconds: 260);

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
      (style ?? const TextStyle()).copyWith(fontSize: size);
  return base.copyWith(
    displayLarge: sized(base.displayLarge, 50),
    displayMedium: sized(base.displayMedium, 40),
    displaySmall: sized(base.displaySmall, 32),
    headlineLarge: sized(base.headlineLarge, 28),
    headlineMedium: sized(base.headlineMedium, 24),
    headlineSmall: sized(base.headlineSmall, 21),
    titleLarge: sized(base.titleLarge, 19),
    titleMedium: sized(base.titleMedium, 14),
    titleSmall: sized(base.titleSmall, 12),
    bodyLarge: sized(base.bodyLarge, 13),
    bodyMedium: sized(base.bodyMedium, 12.5),
    bodySmall: sized(base.bodySmall, 11),
    labelLarge: sized(base.labelLarge, 12.5),
    labelMedium: sized(base.labelMedium, 11),
    labelSmall: sized(base.labelSmall, 10),
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
      onAttachmentEnter: (attachment) {
        _previewTimer?.cancel();
        _controller.showAttachmentPreview(attachment);
      },
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
      if (!mounted) return;
      _composerFocus.unfocus();
      _controller.closeTransientPanels();
      _controller.hideAttachmentPreview();
      unawaited(_controller.setExpanded(false));
    });
  }

  void _schedulePreviewClose() {
    _previewTimer?.cancel();
    _previewTimer = Timer(previewHideDelay, _controller.hideAttachmentPreview);
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
    final width = _controller.expanded
        ? (_controller.largePanel ? largeWindowSize.width : expandedPanelWidth)
        : compactOrbSize;
    final height = _controller.expanded
        ? (_controller.largePanel
              ? largeWindowSize.height
              : expandedPanelHeight)
        : compactOrbSize;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        onKeyEvent: _handleKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.bottomCenter,
              child: MouseRegion(
                onEnter: (_) => unawaited(_expand()),
                onExit: (_) => _scheduleCollapse(),
                child: AnimatedContainer(
                  key: const ValueKey('zommi-surface'),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: width,
                  height: height,
                  child: ClipRect(
                    child: _controller.expanded
                        ? OverflowBox(
                            alignment: Alignment.bottomCenter,
                            minWidth: width,
                            maxWidth: width,
                            minHeight: height,
                            maxHeight: height,
                            child: _buildPanel(width, height),
                          )
                        : _CompactOrbButton(
                            working: _controller.anyTurnActive,
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
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
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
          child: Column(
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
                      ),
                    ),
                    if (_controller.sessionPanelOpen)
                      Positioned(
                        left: 18,
                        top: 2,
                        child: TapRegion(
                          groupId: _sessionTapGroup,
                          child: SessionSidebar(
                            controller: _controller,
                            onPointerEnter: () => _sessionTimer?.cancel(),
                            onPointerExit: _scheduleSessionsClose,
                          ),
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
                    if (_controller.approval != null)
                      Positioned.fill(
                        child: ColoredBox(
                          color: const Color(0x220d172a),
                          child: Center(
                            child: ApprovalDialogCard(controller: _controller),
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
            const SizedBox(width: 5),
            SizedBox.square(
              dimension: 31,
              child: Semantics(
                label: _controller.anyTurnActive
                    ? 'Zommi is thinking'
                    : 'Zommi is idle',
                child: ZommiOrb(
                  key: const ValueKey('panel-orb'),
                  working: _controller.anyTurnActive,
                  size: 31,
                ),
              ),
            ),
            const SizedBox(width: 5),
            TapRegion(
              groupId: _runtimeTapGroup,
              onTapOutside: (_) => _controller.dismissRuntimePanel(),
              child: _SummaryButton(
                key: const ValueKey('runtime-summary'),
                label: _controller.runtimeSummary,
                semanticLabel: 'Choose agent runtime',
                warning: _controller.statusWarning,
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
                onPanStart: (_) => unawaited(_controller.startDragging()),
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
          padding: const EdgeInsets.all(7),
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
            crossAxisAlignment: CrossAxisAlignment.end,
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
                  style: const TextStyle(fontSize: 13, height: 1.35),
                  decoration: const InputDecoration(
                    hintText: 'Ask your agent',
                    border: InputBorder.none,
                    isDense: true,
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
                    tooltip: 'Stop response',
                    onPressed: () => unawaited(_controller.interrupt()),
                    icon: const Icon(Icons.stop_rounded),
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

class _SummaryButton extends StatelessWidget {
  const _SummaryButton({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
    this.warning = false,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;
  final bool warning;

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
        ),
        icon: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: warning ? const Color(0xffcf805f) : const Color(0xff66a27b),
            shape: BoxShape.circle,
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
  const _CompactOrbButton({required this.working, required this.onPressed});

  final bool working;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'ZommiOrb',
      hint: working ? 'Open Zommi chat, agent working' : 'Open Zommi chat',
      button: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey('zommi-orb'),
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: ZommiOrb(working: working),
        ),
      ),
    );
  }
}

class ZommiOrb extends StatefulWidget {
  const ZommiOrb({this.working = false, this.size = compactOrbSize, super.key});

  final bool working;
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
    if (widget.working && !MediaQuery.disableAnimationsOf(context)) {
      if (!_motion.isAnimating) _motion.repeat();
    } else {
      _motion
        ..stop()
        ..value = widget.working ? 0.35 : 0;
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
          ),
        ),
      ),
    );
  }
}

class _NebulaOrbPainter extends CustomPainter {
  const _NebulaOrbPainter({required this.phase, required this.working});

  final double phase;
  final bool working;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.39;
    if (working) {
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
    final drift = working ? math.sin(phase * math.pi * 2) * radius * 0.28 : 0;
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
    if (working) {
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
      oldDelegate.phase != phase || oldDelegate.working != working;
}
