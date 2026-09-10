import 'dart:async';

import 'package:zommi_flutter/diagnostics/scroll_performance.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/core/core_bridge.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';
import 'package:zommi_flutter/widgets/context_preview_layout.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';
import 'package:zommi_flutter/widgets/runtime_logo.dart';
import 'package:zommi_flutter/widgets/transcript_view.dart';

export 'package:zommi_flutter/theme/zommi_typography.dart';

const double expandedPanelWidth = 720;
const double expandedPanelHeight = 620;
const double bottomAnchorInset = windowBottomInset;
const Duration sessionSidebarDuration = Duration(milliseconds: 220);
const Duration previewHideDelay = Duration(milliseconds: 260);

class ZommiApp extends StatefulWidget {
  const ZommiApp({
    required this.core,
    this.desktop = const NoopDesktopBridge(),
    this.artifactLoader,
    this.initialPreferences = const AppPreferences(),
    this.preferencesStore = const NoopAppPreferencesStore(),
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;
  final AppPreferences initialPreferences;
  final AppPreferencesStore preferencesStore;

  @override
  State<ZommiApp> createState() => _ZommiAppState();
}

class _ZommiAppState extends State<ZommiApp> {
  late AppPreferences _preferences = widget.initialPreferences;

  @override
  void initState() {
    super.initState();
    _configureBrowserCapture(_preferences);
  }

  void _configureBrowserCapture(AppPreferences preferences) {
    final desktop = widget.desktop;
    if (desktop case final BrowserCaptureSettings settings) {
      settings.setBrowserPageDetails(preferences.browserPageDetails);
    }
  }

  void _updatePreferences(AppPreferences preferences) {
    if (_preferences == preferences) return;
    setState(() => _preferences = preferences);
    _configureBrowserCapture(preferences);
    unawaited(widget.preferencesStore.save(preferences).catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final theme = ThemeData(
      brightness: Brightness.light,
      fontFamily: codexUiFontFamily,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _preferences.themeColor.seed,
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
        extensions: [
          ZommiVisualSettings(
            chatFontSize: _preferences.chatFontSize,
            themeColor: _preferences.themeColor,
          ),
        ],
      ),
      home: ZommiShell(
        core: widget.core,
        desktop: widget.desktop,
        artifactLoader: widget.artifactLoader,
        preferences: _preferences,
        onPreferencesChanged: _updatePreferences,
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
    required this.preferences,
    required this.onPreferencesChanged,
    this.desktop = const NoopDesktopBridge(),
    this.artifactLoader,
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;
  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onPreferencesChanged;

  @override
  State<ZommiShell> createState() => _ZommiShellState();
}

class _ZommiShellState extends State<ZommiShell> with WidgetsBindingObserver {
  late final InlineAttachmentTextController _composer;
  final FocusNode _composerFocus = FocusNode(debugLabel: 'Zommi composer');
  final ScrollController _composerScroll = ScrollController();
  late final ZommiController _controller;
  final Object _workspaceTapGroup = Object();
  final Object _runtimeTapGroup = Object();
  final Object _runtimeSetupTapGroup = Object();
  final Object _modelTapGroup = Object();
  final Object _appSettingsTapGroup = Object();
  final LayerLink _runtimePanelLink = LayerLink();
  final LayerLink _settingsPanelLink = LayerLink();
  final LayerLink _workspacePanelLink = LayerLink();
  final LayerLink _appSettingsPanelLink = LayerLink();
  Timer? _previewTimer;
  final GlobalKey _previewViewportKey = GlobalKey();
  BuildContext? _previewAnchor;
  Rect _previewAnchorBounds = Rect.zero;
  int _lastFocusEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ZommiController(
      core: widget.core,
      desktop: widget.desktop,
      artifactLoader: widget.artifactLoader,
      initialWindowSize: widget.preferences.windowSize,
    );
    _composer = InlineAttachmentTextController(
      onAttachmentRemoved: (attachment) =>
          _controller.removeAttachment(attachment.id),
      onAttachmentEnter: _showAttachmentPreview,
      onAttachmentExit: (_) => _schedulePreviewClose(),
      onAttachmentAdjust: (attachment) =>
          unawaited(_controller.addPointerContext(replacingId: attachment.id)),
    );
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize());
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_previewBlocked && _controller.previewAttachment != null) {
      _controller.hideAttachmentPreview();
      return;
    }
    final previousAttachmentCount = _composer.inlineAttachments.length;
    _composer.syncAttachments(_controller.attachments);
    if (_composer.inlineAttachments.length > previousAttachmentCount &&
        _composer.selection.isCollapsed &&
        _composer.selection.extentOffset == _composer.text.length) {
      // EditableText reveals a text-height caret. A taller inline attachment
      // can still be clipped below it when the draft reaches its height cap.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _composerScroll.hasClients) {
          _composerScroll.jumpTo(_composerScroll.position.maxScrollExtent);
        }
      });
    }
    if (_lastFocusEpoch != _controller.focusComposerEpoch) {
      _lastFocusEpoch = _controller.focusComposerEpoch;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.expanded) _composerFocus.requestFocus();
      });
    }
    setState(() {});
    _updatePreviewAfterLayout();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _previewTimer?.cancel();
    _controller.removeListener(_onControllerChanged);
    unawaited(_controller.close());
    _composer.dispose();
    _composerFocus.dispose();
    _composerScroll.dispose();
    super.dispose();
  }

  Future<void> _startWindowDrag() async {
    await _controller.startDragging();
  }

  void _schedulePreviewClose() {
    _previewTimer?.cancel();
    _previewTimer = Timer(previewHideDelay, _controller.hideAttachmentPreview);
  }

  void _showAttachmentPreview(
    ContextAttachment attachment,
    BuildContext anchor,
  ) {
    if (_previewBlocked) return;
    _previewTimer?.cancel();
    _previewAnchor = anchor;
    _previewAnchorBounds = _previewAnchorRect();
    _controller.showAttachmentPreview(attachment);
  }

  bool get _previewBlocked =>
      !_controller.expanded ||
      _controller.sessionPanelOpen ||
      _controller.runtimeSetupPanelOpen ||
      _controller.approval != null ||
      _controller.question != null ||
      _controller.previewArtifact != null;

  @override
  void didChangeMetrics() => _updatePreviewAfterLayout();

  void _updatePreviewAfterLayout() {
    if (_controller.previewAttachment == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller.previewAttachment == null) return;
      if (_previewAnchor?.mounted != true) {
        _controller.hideAttachmentPreview();
        return;
      }
      final bounds = _previewAnchorRect();
      if (bounds != _previewAnchorBounds) {
        setState(() => _previewAnchorBounds = bounds);
      }
    });
  }

  Rect _previewAnchorRect() {
    final anchor = _previewAnchor;
    final viewport = _previewViewportKey.currentContext?.findRenderObject();
    if (anchor == null || !anchor.mounted || viewport is! RenderBox) {
      return Rect.zero;
    }
    final target = anchor.findRenderObject();
    if (target is! RenderBox || !target.hasSize) return Rect.zero;
    return target.localToGlobal(Offset.zero, ancestor: viewport) & target.size;
  }

  bool _closePreviewOnScroll(ScrollStartNotification notification) {
    final anchor = _previewAnchor;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_previewAnchor, anchor)) {
        _controller.hideAttachmentPreview();
      }
    });
    return false;
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

  Future<void> _selectWindowSize(WindowSizeSetting setting) async {
    await _controller.setWindowSize(setting);
    if (mounted && _controller.windowSize == setting) {
      widget.onPreferencesChanged(
        widget.preferences.copyWith(windowSize: setting),
      );
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_controller.previewArtifact != null) {
        _controller.closeArtifact();
      } else if (_controller.runtimePanelOpen ||
          _controller.runtimeSetupPanelOpen ||
          _controller.modelPanelOpen ||
          _controller.workspacePanelOpen ||
          _controller.appSettingsPanelOpen ||
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        onKeyEvent: _handleKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final height = constraints.maxHeight;
            return SizedBox.expand(
              key: const ValueKey('zommi-surface'),
              child: RepaintBoundary(child: _buildPanel(width, height)),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPanel(double width, double height) {
    final accent = Theme.of(context).colorScheme.primary;
    final tone = Theme.of(context).extension<ZommiVisualSettings>()?.themeColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tone == null || tone == ZommiThemeColor.violet
              ? const Color(0xeaf9fbff)
              : Color.alphaBlend(
                  accent.withValues(alpha: 0.055),
                  const Color(0xeaf9fbff),
                ),
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
          key: _previewViewportKey,
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSessionSidebar(width),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child:
                                        NotificationListener<
                                          ScrollStartNotification
                                        >(
                                          onNotification: _closePreviewOnScroll,
                                          child: ScrollPerformanceBoundary(
                                            child: TranscriptPane(
                                              key: ValueKey(
                                                'transcript-${_controller.activeSessionId}',
                                              ),
                                              controller: _controller,
                                              onAttachmentEnter:
                                                  _showAttachmentPreview,
                                              onAttachmentExit: (_) =>
                                                  _schedulePreviewClose(),
                                            ),
                                          ),
                                        ),
                                  ),
                                  if (_controller.runtimeSetupPanelOpen)
                                    Positioned.fill(
                                      child: ColoredBox(
                                        color: const Color(0x260d172a),
                                        child: Center(
                                          child: TapRegion(
                                            groupId: _runtimeSetupTapGroup,
                                            onTapOutside: (_) => _controller
                                                .dismissRuntimeSetupPanel(),
                                            child: RuntimeSetupPanel(
                                              controller: _controller,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_controller.starting)
                                    Positioned(
                                      top: 10,
                                      left: 0,
                                      right: 0,
                                      child: IgnorePointer(
                                        child: Center(
                                          child: _LoadingPill(
                                            label: 'Waking Zommi…',
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
                                            key: ValueKey(
                                              _controller.question!.id,
                                            ),
                                            controller: _controller,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_controller.previewArtifact != null)
                                    ArtifactViewerDialog(
                                      controller: _controller,
                                    ),
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
                    ],
                  ),
                ),
              ],
            ),
            if (_controller.previewAttachment case final attachment?)
              if (_previewAnchor?.mounted == true)
                Positioned.fill(
                  child: CustomSingleChildLayout(
                    delegate: ContextPreviewLayout(
                      anchorRect: _previewAnchorBounds,
                    ),
                    child: ContextPreviewPanel(
                      attachment: attachment,
                      onClose: _controller.hideAttachmentPreview,
                      onPointerEnter: () => _previewTimer?.cancel(),
                      onPointerExit: _schedulePreviewClose,
                      onAdjust:
                          _controller.attachments.any(
                            (item) => item.id == attachment.id,
                          )
                          ? () => unawaited(
                              _controller.addPointerContext(
                                replacingId: attachment.id,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
            if (_controller.runtimePanelOpen)
              Positioned(
                left: 0,
                top: 0,
                child: CompositedTransformFollower(
                  link: _runtimePanelLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  offset: const Offset(0, 6),
                  child: TapRegion(
                    groupId: _runtimeTapGroup,
                    child: RuntimePanel(controller: _controller),
                  ),
                ),
              ),
            if (_controller.modelPanelOpen)
              Positioned(
                left: 0,
                top: 0,
                child: CompositedTransformFollower(
                  link: _settingsPanelLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
                  offset: const Offset(0, 6),
                  child: TapRegion(
                    groupId: _modelTapGroup,
                    child: ModelSettingsPanel(controller: _controller),
                  ),
                ),
              ),
            if (_controller.workspacePanelOpen)
              Positioned(
                left: 0,
                top: 0,
                child: CompositedTransformFollower(
                  link: _workspacePanelLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, 6),
                  child: TapRegion(
                    groupId: _workspaceTapGroup,
                    child: WorkspacePanel(
                      key: const ValueKey('workspace-panel'),
                      controller: _controller,
                      onBack: _controller.dismissWorkspacePanel,
                    ),
                  ),
                ),
              ),
            if (_controller.appSettingsPanelOpen)
              Positioned(
                left: 0,
                top: 0,
                child: CompositedTransformFollower(
                  link: _appSettingsPanelLink,
                  showWhenUnlinked: false,
                  targetAnchor: Alignment.bottomRight,
                  followerAnchor: Alignment.topRight,
                  offset: const Offset(0, 6),
                  child: TapRegion(
                    groupId: _appSettingsTapGroup,
                    child: AppSettingsPanel(
                      controller: _controller,
                      preferences: widget.preferences,
                      onChanged: widget.onPreferencesChanged,
                      onWindowSizeChanged: _selectWindowSize,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionSidebar(double width) {
    final sidebarWidth = (width * .32).clamp(200.0, 260.0);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _controller.sessionPanelOpen ? 1 : 0),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : sessionSidebarDuration,
      curve: Curves.easeInOutCubic,
      builder: (context, progress, child) => SizedBox(
        key: const ValueKey('session-sidebar-slide'),
        width: sidebarWidth * progress,
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerRight,
            minWidth: sidebarWidth,
            maxWidth: sidebarWidth,
            child: IgnorePointer(
              ignoring: !_controller.sessionPanelOpen,
              child: ExcludeSemantics(
                excluding: !_controller.sessionPanelOpen,
                child: TickerMode(
                  enabled: _controller.sessionPanelOpen,
                  child: ExcludeFocus(
                    excluding: !_controller.sessionPanelOpen,
                    child: Offstage(offstage: progress == 0, child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: SessionSidebar(controller: _controller),
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      key: const ValueKey('window-drag-region'),
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(_startWindowDrag()),
      child: SizedBox(
        height: 62,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 7),
          child: Row(
            children: [
              Semantics(
                expanded: _controller.sessionPanelOpen,
                child: _HeaderButton(
                  key: const ValueKey('toggle-sessions'),
                  label: _controller.sessionPanelOpen
                      ? 'Hide chat sessions'
                      : 'Show chat sessions',
                  customIcon: const SessionSidebarIcon(),
                  onPressed: _controller.sessionNavigationSupported
                      ? () => _controller.toggleSessionPanel()
                      : null,
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: TapRegion(
                        groupId: _runtimeTapGroup,
                        onTapOutside: (_) => _controller.dismissRuntimePanel(),
                        child: CompositedTransformTarget(
                          link: _runtimePanelLink,
                          child: _SummaryButton(
                            key: const ValueKey('runtime-summary'),
                            label: _controller.runtimeSummary,
                            semanticLabel: 'Choose agent runtime',
                            warning: _controller.statusWarning,
                            loading: _controller.runtimeBusy,
                            onPressed: _controller.toggleRuntimePanel,
                          ),
                        ),
                      ),
                    ),
                    if (_controller.sessionSettingsSupported) ...[
                      const SizedBox(width: 5),
                      Flexible(
                        child: TapRegion(
                          groupId: _modelTapGroup,
                          onTapOutside: (_) => _controller.dismissModelPanel(),
                          child: CompositedTransformTarget(
                            link: _settingsPanelLink,
                            child: _SummaryButton(
                              key: const ValueKey('model-summary'),
                              label: _controller.modelSummary,
                              semanticLabel: 'Model settings',
                              onPressed: _controller.toggleModelPanel,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: TapRegion(
                          groupId: _workspaceTapGroup,
                          onTapOutside: (_) =>
                              _controller.dismissWorkspacePanel(),
                          child: CompositedTransformTarget(
                            link: _workspacePanelLink,
                            child: _SummaryButton(
                              key: const ValueKey('workspace-summary'),
                              label: _controller.selectedWorkspace.isEmpty
                                  ? 'Workspace'
                                  : _controller.workspaceSummary,
                              semanticLabel: 'Workspace',
                              icon: Icons.folder_outlined,
                              onPressed: _controller.toggleWorkspacePanel,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              TapRegion(
                groupId: _appSettingsTapGroup,
                onTapOutside: (_) => _controller.dismissAppSettingsPanel(),
                child: CompositedTransformTarget(
                  link: _appSettingsPanelLink,
                  child: _HeaderButton(
                    key: const ValueKey('app-settings'),
                    label: 'App settings',
                    icon: Icons.settings_outlined,
                    onPressed: _controller.toggleAppSettingsPanel,
                  ),
                ),
              ),
              _HeaderButton(
                key: const ValueKey('hide-zommi'),
                label: 'Minimize Zommi',
                icon: Icons.remove_rounded,
                onPressed: () => unawaited(_controller.hideWindow()),
              ),
              _HeaderButton(
                key: const ValueKey('close-zommi'),
                label: 'Close Zommi',
                icon: Icons.close_rounded,
                onPressed: () => unawaited(_controller.closeWindow()),
              ),
            ],
          ),
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
          key: const ValueKey('message-composer-shell'),
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
              TextButton.icon(
                key: const ValueKey('select-content'),
                onPressed: _controller.selectingContent
                    ? null
                    : () => unawaited(_controller.addPointerContext()),
                icon: const Icon(Icons.ads_click_rounded, size: 18),
                label: Text(
                  _controller.selectingContent
                      ? 'Selecting…'
                      : 'Select content',
                ),
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('zommi-composer'),
                  focusNode: _composerFocus,
                  controller: _composer,
                  scrollController: _composerScroll,
                  enabled: !_controller.sessionBusy,
                  minLines: 1,
                  maxLines: 5,
                  // Let inline attachment widgets set the height of their own
                  // line instead of painting across fixed-height text lines.
                  strutStyle: _composer.inlineAttachments.isEmpty
                      ? null
                      : const StrutStyle(forceStrutHeight: false),
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textAlignVertical: TextAlignVertical.center,
                  style: topBarAndChatTextStyle,
                  decoration: const InputDecoration(
                    hintText: 'Ask your agent',
                    border: InputBorder.none,
                    isDense: true,
                    // The first line fills the control row. Further lines add
                    // height immediately, with the row's bottom staying fixed.
                    contentPadding: EdgeInsets.symmetric(vertical: 20),
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
                    onPressed:
                        _controller.submitting ||
                            _controller.selectingContent ||
                            _controller.sessionBusy ||
                            _controller.runtimeBusy
                        ? null
                        : _submit,
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
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.label,
    this.icon,
    this.customIcon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData? icon;
  final Widget? customIcon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        icon: customIcon ?? Icon(icon, size: 18),
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
            const SizedBox.square(
              key: ValueKey('loading-indicator'),
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              key: const ValueKey('loading-status'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: topBarAndChatTextStyle.copyWith(
                color: Color(0xff514a70),
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
    this.icon,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;
  final bool warning;
  final bool loading;
  final IconData? icon;

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
          textStyle: topBarAndChatTextStyle,
        ),
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: loading
              ? const SizedBox.square(
                  key: ValueKey('runtime-loading-indicator'),
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : icon != null
              ? Icon(icon, size: 15)
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
