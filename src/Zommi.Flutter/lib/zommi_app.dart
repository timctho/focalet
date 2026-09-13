import 'dart:async';

import 'package:zommi_flutter/core/core_bridge.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/diagnostics/scroll_performance.dart';
import 'package:zommi_flutter/state/session_catalog_store.dart';
import 'package:zommi_flutter/state/codex_command_catalog.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';
import 'package:zommi_flutter/widgets/context_preview_layout.dart';
import 'package:zommi_flutter/widgets/command_result.dart';
import 'package:zommi_flutter/widgets/codex_command_menu.dart';
import 'package:zommi_flutter/widgets/inline_attachment_composer.dart';
import 'package:zommi_flutter/widgets/message_history_navigation.dart';
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
    this.sessionCatalogStore = const NoopSessionCatalogStore(),
    this.catalogStartupDelay = Duration.zero,
    this.initialPreferences = const AppPreferences(),
    this.preferencesStore = const NoopAppPreferencesStore(),
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;
  final SessionCatalogStore sessionCatalogStore;
  final Duration catalogStartupDelay;
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
    ThemeData buildTheme(Brightness brightness) {
      final theme = ThemeData(
        brightness: brightness,
        fontFamily: codexUiFontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _preferences.seedColor,
          brightness: brightness,
          dynamicSchemeVariant:
              _preferences.themeColor == ZommiThemeColor.mist ||
                  _preferences.themeColor == ZommiThemeColor.cream
              ? DynamicSchemeVariant.fidelity
              : DynamicSchemeVariant.tonalSpot,
        ),
        scaffoldBackgroundColor: Colors.transparent,
        useMaterial3: true,
      );
      return theme.copyWith(
        textTheme: _compactTextTheme(theme.textTheme),
        visualDensity: VisualDensity.compact,
        extensions: [
          ZommiVisualSettings(
            chatFontSize: _preferences.chatFontSize,
            themeColor: _preferences.themeColor,
          ),
        ],
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zommi',
      themeMode: _preferences.themeMode,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: ZommiShell(
        core: widget.core,
        desktop: widget.desktop,
        artifactLoader: widget.artifactLoader,
        sessionCatalogStore: widget.sessionCatalogStore,
        catalogStartupDelay: widget.catalogStartupDelay,
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
    this.sessionCatalogStore = const NoopSessionCatalogStore(),
    this.catalogStartupDelay = Duration.zero,
    super.key,
  });

  final CoreBridge core;
  final DesktopBridge desktop;
  final ArtifactLoader? artifactLoader;
  final SessionCatalogStore sessionCatalogStore;
  final Duration catalogStartupDelay;
  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onPreferencesChanged;

  @override
  State<ZommiShell> createState() => _ZommiShellState();
}

class _ZommiShellState extends State<ZommiShell> with WidgetsBindingObserver {
  late final InlineAttachmentTextController _composer;
  String? _composerSessionKey;
  int _lastCommandComposerEpoch = 0;
  int _selectedCommand = 0;
  String? _dismissedCommandText;
  bool _restoringComposer = false;
  final MessageHistoryNavigation _history = MessageHistoryNavigation();
  final FocusNode _composerFocus = FocusNode(debugLabel: 'Zommi composer');
  final ScrollController _composerScroll = ScrollController();
  late final ZommiController _controller;
  final Object _workspaceTapGroup = Object();
  final Object _runtimeSetupTapGroup = Object();
  final Object _modelTapGroup = Object();
  final Object _appSettingsTapGroup = Object();
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
      sessionCatalogStore: widget.sessionCatalogStore,
      catalogStartupDelay: widget.catalogStartupDelay,
      initialWindowSize: widget.preferences.windowSize,
    );
    _composer = InlineAttachmentTextController(
      emphasisRange: (text) =>
          _controller.activeRuntime?.adapterId == 'codex-app-server'
          ? codexCommandEmphasis(text)
          : TextRange.empty,
      onAttachmentRemoved: (attachment) =>
          _controller.removeAttachment(attachment.id),
      onAttachmentEnter: _showAttachmentPreview,
      onAttachmentExit: (_) => _schedulePreviewClose(),
    );
    _composer.addListener(_onComposerChanged);
    _composerFocus.onKeyEvent = _handleComposerKey;
    _composerFocus.addListener(_onComposerFocusChanged);
    _controller.addListener(_onControllerChanged);
    unawaited(_controller.initialize());
  }

  void _onComposerChanged() {
    _history.textChanged(_composer.text);
    if (!_restoringComposer) {
      final previous = _controller.composerValue.text.trim();
      final wasCommand = _controller.isCodexCommand(previous);
      _controller.updateComposerValue(
        _composer.value,
        attachmentOrder: _composer.inlineAttachments
            .map((attachment) => attachment.id)
            .toList(),
      );
      if (previous != _composer.text.trim()) {
        _selectedCommand = 0;
        _dismissedCommandText = null;
      }
      if (wasCommand || _controller.isCodexCommand(_composer.messageText)) {
        setState(() {});
      }
    }
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_composerSessionKey != _controller.composerSessionKey ||
        _lastCommandComposerEpoch != _controller.commandComposerEpoch) {
      _lastCommandComposerEpoch = _controller.commandComposerEpoch;
      _history.reset();
      _composerSessionKey = _controller.composerSessionKey;
      _restoringComposer = true;
      try {
        _composer.restoreDraft(
          _controller.composerValue,
          _controller.attachments,
        );
      } finally {
        _restoringComposer = false;
      }
    }
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
    _composerFocus.removeListener(_onComposerFocusChanged);
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
    final isCommand = _controller.isCodexCommand(text);
    if (_composer.value.composing.isValid &&
        !_composer.value.composing.isCollapsed) {
      return;
    }
    if (text.isEmpty ||
        _controller.sessionReadOnly ||
        (_controller.submitting && isCommand) ||
        _controller.sessionBusy ||
        _controller.runtimeBusy ||
        _controller.selectingContent ||
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
    if (!isCommand) {
      _composer.clearAfterSubmit();
      _history.reset();
    }
    _composerFocus.requestFocus();
    unawaited(submission);
  }

  Future<void> _toggleWindowMaximized() async {
    await _controller.toggleMaximized();
    if (mounted && _controller.windowSize != widget.preferences.windowSize) {
      widget.onPreferencesChanged(
        widget.preferences.copyWith(windowSize: _controller.windowSize),
      );
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_controller.previewArtifact != null) {
        _controller.closeArtifact();
      } else if (_controller.runtimeSetupPanelOpen ||
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
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if ((_composer.value.composing.isValid &&
            !_composer.value.composing.isCollapsed) ||
        keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final commandResult = _handleCommandKey(node, event);
    if (commandResult != KeyEventResult.ignored) return commandResult;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final recalled = _history.navigate(
        older: event.logicalKey == LogicalKeyboardKey.arrowUp,
        value: _composer.value,
        history: _controller.composerHistory,
      );
      if (recalled == null) return KeyEventResult.ignored;
      _composer.value = recalled;
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onComposerFocusChanged() {
    if (mounted) setState(() {});
  }

  List<CodexComposerCommand> get _commandSuggestions {
    if (!_composerFocus.hasFocus ||
        _controller.sessionBusy ||
        _controller.activeRuntime?.adapterId != 'codex-app-server' ||
        _dismissedCommandText == _composer.text ||
        (_composer.value.composing.isValid &&
            !_composer.value.composing.isCollapsed) ||
        !_composer.selection.isCollapsed ||
        _composer.selection.extentOffset != _composer.text.length) {
      return const [];
    }
    return matchingCodexCommands(_composer.text);
  }

  void _chooseCommand(CodexComposerCommand command) {
    _composer.value = TextEditingValue(
      text: command.completion,
      selection: TextSelection.collapsed(offset: command.completion.length),
    );
    setState(() => _dismissedCommandText = _composer.text);
    _composerFocus.requestFocus();
  }

  KeyEventResult _handleCommandKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final suggestions = _commandSuggestions;
    if (suggestions.isEmpty) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _dismissedCommandText = _composer.text);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _selectedCommand =
            (_selectedCommand +
                (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
            suggestions.length,
      );
      return KeyEventResult.handled;
    }
    final selected =
        suggestions[_selectedCommand.clamp(0, suggestions.length - 1)];
    if (key == LogicalKeyboardKey.tab ||
        (key == LogicalKeyboardKey.enter &&
            !suggestions.any(
              (command) => command.text == _composer.messageText,
            ))) {
      _chooseCommand(selected);
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
              child: DragToResizeArea(
                resizeEdgeSize: 16,
                enableResizeEdges:
                    // macOS provides native resize handles; startResizing is
                    // supplied by window_manager on Windows and Linux.
                    Theme.of(context).platform != TargetPlatform.macOS &&
                        _controller.expanded &&
                        !_controller.maximizedPanel &&
                        !_controller.surfaceTransitioning
                    ? const [
                        ResizeEdge.topLeft,
                        ResizeEdge.topRight,
                        ResizeEdge.bottomLeft,
                        ResizeEdge.bottomRight,
                      ]
                    : const [],
                child: RepaintBoundary(child: _buildPanel(width, height)),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPanel(double width, double height) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: Theme.of(context).colorScheme.surface),
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
                                              key: ValueKey((
                                                'transcript',
                                                _controller.activeRuntime?.id,
                                                _controller.activeSessionId,
                                              )),
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
                            if (_commandSuggestions.isNotEmpty)
                              CodexCommandMenu(
                                key: const ValueKey('codex-command-menu'),
                                commands: _commandSuggestions,
                                selectedIndex: _selectedCommand.clamp(
                                  0,
                                  _commandSuggestions.length - 1,
                                ),
                                onSelected: _chooseCommand,
                              )
                            else if (_controller.commandResult
                                case final result?)
                              CommandResult(
                                key: const ValueKey('command-result'),
                                text: result,
                                onClose: _controller.dismissCommandResult,
                              ),
                            if (_controller.queuedMessages.isNotEmpty)
                              _buildMessageQueue(),
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
                  targetAnchor: Alignment.bottomLeft,
                  followerAnchor: Alignment.topLeft,
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
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: () => unawaited(_toggleWindowMaximized()),
              ),
            ),
            Padding(
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
                        if (_controller.sessionSettingsSupported) ...[
                          const SizedBox(width: 5),
                          Flexible(
                            child: TapRegion(
                              groupId: _modelTapGroup,
                              onTapOutside: (_) =>
                                  _controller.dismissModelPanel(),
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
                    key: const ValueKey('maximize-zommi'),
                    label: _controller.maximizedPanel
                        ? 'Restore Zommi'
                        : 'Maximize Zommi',
                    icon: _controller.maximizedPanel
                        ? Icons.filter_none_rounded
                        : Icons.crop_square_rounded,
                    onPressed: _controller.surfaceTransitioning
                        ? null
                        : () => unawaited(_toggleWindowMaximized()),
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
          ],
        ),
      ),
    );
  }

  Widget _buildComposer() {
    final willQueue =
        !_controller.isCodexCommand(_composer.messageText) &&
        (_controller.turnActive || _controller.queuedMessages.isNotEmpty);
    return Semantics(
      container: true,
      label: 'Message composer',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 6, 22, 6),
        child: Container(
          key: const ValueKey('message-composer-shell'),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
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
              FilledButton.tonalIcon(
                key: const ValueKey('select-content'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 36),
                  shape: const StadiumBorder(),
                ),
                onPressed: _controller.selectingContent
                    ? null
                    : () => unawaited(_controller.addPointerContext()),
                icon: const Icon(Icons.ads_click_rounded, size: 18),
                label: Text(
                  _controller.selectingContent ? 'Selecting…' : 'Select',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                // Undo history belongs to the selected chat too.
                key: ValueKey((
                  'composer-session',
                  _controller.composerSessionKey,
                )),
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
                  style: chatTextStyleOf(context),
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
                  child: IconButton.filledTonal(
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
                ),
              Semantics(
                label: willQueue ? 'Queue message' : 'Send message',
                button: true,
                child: IconButton.filled(
                  key: const ValueKey('send-message'),
                  tooltip: willQueue ? 'Queue message (Enter)' : 'Send (Enter)',
                  onPressed:
                      (_controller.submitting &&
                              _controller.isCodexCommand(
                                _composer.messageText,
                              )) ||
                          _controller.activeSessionId == null ||
                          _controller.selectingContent ||
                          _controller.sessionBusy ||
                          _controller.sessionReadOnly ||
                          _controller.runtimeBusy
                      ? null
                      : _submit,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageQueue() {
    final messages = _controller.queuedMessages;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Container(
        key: const ValueKey('message-queue'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${messages.length} queued${_controller.queuePaused ? ' · paused' : ' · sends after response'}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (_controller.queuePaused)
                  TextButton(
                    key: const ValueKey('resume-message-queue'),
                    onPressed:
                        _controller.turnActive ||
                            _controller.sessionBusy ||
                            _controller.sessionReadOnly ||
                            _controller.runtimeBusy
                        ? null
                        : _controller.resumeQueuedMessages,
                    child: const Text('Resume'),
                  ),
              ],
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 80),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  return Row(
                    key: ValueKey('queued-message-${message.id}'),
                    children: [
                      Text(
                        '${index + 1}. ',
                        style: const TextStyle(fontSize: 11),
                      ),
                      Expanded(
                        child: Tooltip(
                          message: message.text,
                          child: Text(
                            message.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (message.attachments.isNotEmpty)
                        Text(
                          ' · ${message.attachments.length} attached',
                          style: const TextStyle(fontSize: 10),
                        ),
                      IconButton(
                        key: ValueKey('remove-queued-message-${message.id}'),
                        tooltip: 'Remove queued message ${index + 1}',
                        onPressed: () =>
                            _controller.removeQueuedMessage(message.id),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
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
                  ? Theme.of(context).colorScheme.primary
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
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
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
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
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
                color: Theme.of(context).colorScheme.onSurface,
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
    this.icon,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: topBarAndChatTextStyle,
        ),
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: icon != null
              ? Icon(icon, size: 15)
              : Container(
                  key: const ValueKey('runtime-status-dot'),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: const Color(0xff66a27b),
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
