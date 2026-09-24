import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/gnome_integration.dart';
import 'package:zommi_flutter/widgets/gnome_integration_setup.dart';
import 'package:zommi_flutter/desktop/capture_shortcut.dart';
import 'package:zommi_flutter/widgets/capture_shortcut_setting.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/theme/zommi_typography.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/document_preview.dart';
import 'package:zommi_flutter/widgets/capture_permission_setup.dart';
import 'package:zommi_flutter/widgets/frosted_surface.dart';
import 'package:zommi_flutter/widgets/runtime_logo.dart';
import 'package:zommi_flutter/widgets/session_context_menu.dart';
import 'package:zommi_flutter/widgets/theme_color_picker.dart';

const Color zommiOverlayPanelColor = Color(0xfaf7f9fd);
const Color zommiOverlayPanelShadowColor = Color(0x260d172a);
const double zommiOverlayPanelRadius = 18;
const double zommiOverlayPanelElevation = 18;

class ZommiOverlayPanelSurface extends StatelessWidget {
  const ZommiOverlayPanelSurface({
    required this.width,
    required this.child,
    this.height,
    super.key,
  });

  final double width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: zommiOverlayPanelShadowColor,
      elevation: zommiOverlayPanelElevation,
      borderRadius: BorderRadius.circular(zommiOverlayPanelRadius),
      clipBehavior: Clip.antiAlias,
      child: FrostedSurface(
        radius: zommiOverlayPanelRadius,
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        opacity: .94,
        child: SizedBox(width: width, height: height, child: child),
      ),
    );
  }
}

class SessionSidebar extends StatefulWidget {
  const SessionSidebar({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<SessionSidebar> createState() => _SessionSidebarState();
}

class _SessionSidebarState extends State<SessionSidebar> {
  ZommiController get controller => widget.controller;
  bool _loadedForScroll = false;
  late final Timer _relativeTimeTimer;

  @override
  void initState() {
    super.initState();
    _relativeTimeTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _relativeTimeTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = controller.visibleSessions;
    return Semantics(
      container: true,
      label: 'Chat sessions',
      child: Material(
        key: const ValueKey('session-sidebar'),
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        elevation: 0,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Text(
                          'Agents',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (controller.sessionCatalogLoading ||
                            controller.sessionBusy ||
                            controller.runtimeBusy) ...[
                          const SizedBox(width: 10),
                          const SizedBox.square(
                            dimension: 16,
                            child: RepaintBoundary(
                              child: CircularProgressIndicator(
                                key: ValueKey('session-catalog-loading'),
                                semanticsLabel: 'Loading agents and chats',
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  _NewAgentMenu(controller: controller),
                ],
              ),
            ),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification.depth != 0) return false;
                  if (notification is ScrollStartNotification) {
                    _loadedForScroll = false;
                  }
                  final down = switch (notification) {
                    ScrollUpdateNotification(:final scrollDelta) =>
                      (scrollDelta ?? 0) > 0,
                    OverscrollNotification(:final overscroll) => overscroll > 0,
                    _ => false,
                  };
                  if (!_loadedForScroll &&
                      down &&
                      notification.metrics.extentAfter <= 1) {
                    _loadedForScroll = true;
                    unawaited(controller.loadMoreSessions());
                  }
                  return false;
                },
                child: ListView.builder(
                  key: const ValueKey('session-list'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  itemCount: sessions.isEmpty ? 1 : sessions.length,
                  itemBuilder: (context, index) {
                    if (sessions.isEmpty) {
                      return Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'No recent chats are available.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      );
                    }
                    final session = sessions[index];
                    final runtime = controller.runtimeForSession(session);
                    final presence = controller.presenceFor(
                      session.id,
                      runtimeTargetId: session.runtimeTargetId,
                    );
                    final selected =
                        session.id == controller.activeSessionId &&
                        session.runtimeTargetId == controller.activeRuntime?.id;
                    final workspace = _sessionWorkspaceLabel(session.cwd);
                    final updated = session.activityTime?.toLocal();
                    final colors = Theme.of(context).colorScheme;
                    final localizations = MaterialLocalizations.of(context);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        selected: selected,
                        label:
                            '${session.title}, ${runtime?.displayName ?? 'Agent'}, ${presence.name} session',
                        child: SessionContextMenu(
                          controller: controller,
                          session: session,
                          child: ListTile(
                            key: ValueKey(
                              'session-${session.runtimeTargetId}-${session.id}',
                            ),
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -3),
                            minVerticalPadding: 0,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            selected: selected,
                            tileColor: Colors.transparent,
                            selectedTileColor: colors.primary.withValues(
                              alpha: colors.brightness == Brightness.dark
                                  ? .18
                                  : .10,
                            ),
                            selectedColor: colors.onSurface,
                            hoverColor: colors.brightness == Brightness.dark
                                ? colors.primary.withValues(alpha: .16)
                                : null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            minLeadingWidth: 28.8,
                            horizontalTitleGap: 10,
                            titleAlignment: ListTileTitleAlignment.center,
                            leading: _SessionTooltip(
                              message: runtime?.displayName ?? 'Agent runtime',
                              child: RuntimeLogo(
                                key: ValueKey(
                                  'session-runtime-${session.runtimeTargetId}-${session.id}',
                                ),
                                runtimeId: runtime?.runtimeId ?? '',
                                size: 28.8,
                              ),
                            ),
                            title: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    _SessionTooltip(
                                      message: presence.name,
                                      child: SizedBox.square(
                                        dimension: 18,
                                        child: Center(
                                          child: _SessionStatusIcon(
                                            presence: presence,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        workspace,
                                        key: ValueKey(
                                          'session-workspace-${session.runtimeTargetId}-${session.id}',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    if (session.pinned) ...[
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.push_pin_rounded,
                                        size: 13,
                                        color: colors.primary,
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    _SessionTooltip(
                                      message: updated == null
                                          ? 'Last update unavailable'
                                          : 'Last updated ${localizations.formatFullDate(updated)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(updated))}',
                                      child: Text(
                                        _sessionUpdatedLabel(updated),
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  session.title,
                                  key: ValueKey(
                                    'session-title-${session.runtimeTargetId}-${session.id}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: chatTextStyleOf(context).copyWith(
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ],
                            ),
                            onTap: controller.runtimeBusy
                                ? null
                                : () => unawaited(
                                    controller.switchSession(
                                      session.id,
                                      runtimeTargetId: session.runtimeTargetId,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewAgentMenu extends StatelessWidget {
  const _NewAgentMenu({required this.controller});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final busy = controller.sessionBusy || controller.runtimeBusy;
      final targets = controller.visibleRuntimeTargets;
      final firstCreatable = targets
          .where(controller.canCreateSession)
          .firstOrNull;
      final runtimeStyle = MenuItemButton.styleFrom(
        minimumSize: const Size(0, kMinInteractiveDimension),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.standard,
      );
      final actionStyle = MenuItemButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.standard,
      );
      return MenuAnchor(
        consumeOutsideTap: true,
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerLow),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shadowColor: const WidgetStatePropertyAll(
            zommiOverlayPanelShadowColor,
          ),
          elevation: const WidgetStatePropertyAll(zommiOverlayPanelElevation),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(vertical: 4),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(zommiOverlayPanelRadius),
            ),
          ),
        ),
        menuChildren: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
            child: Row(
              children: [
                const Text(
                  'New agent',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                Text(
                  '${targets.length} available',
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (final target in targets)
            MenuItemButton(
              key: ValueKey('create-session-${target.id}'),
              autofocus: target.id == firstCreatable?.id,
              onPressed: busy || !controller.canCreateSession(target)
                  ? null
                  : () => unawaited(
                      controller.createSession(runtimeTargetId: target.id),
                    ),
              style: runtimeStyle,
              child: SizedBox(
                width: 256,
                child: Row(
                  children: [
                    RuntimeLogo(runtimeId: target.runtimeId, size: 16),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            target.displayName,
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            controller.canCreateSession(target)
                                ? '${target.protocolName} · ${target.executionHost['displayName'] ?? 'Local'}'
                                : 'New chats unavailable',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 9),
          for (final target in targets)
            if (target.status == 'sign-in-required')
              MenuItemButton(
                key: ValueKey('runtime-sign-in-${target.id}'),
                style: runtimeStyle,
                onPressed: busy
                    ? null
                    : () => unawaited(
                        controller.openRuntimeSignIn(
                          runtimeTargetId: target.id,
                        ),
                      ),
                child: Text('Sign in to ${target.displayName}'),
              ),
          if (controller.runtimeDiscoveryError case final error?)
            SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 3, 12, 5),
                child: Text(
                  error,
                  key: const ValueKey('runtime-discovery-error'),
                  style: TextStyle(fontSize: 11, color: colors.error),
                ),
              ),
            ),
          MenuItemButton(
            key: const ValueKey('refresh-runtimes'),
            autofocus: firstCreatable == null,
            closeOnActivate: false,
            style: actionStyle,
            onPressed:
                busy ||
                    controller.runtimeDiscoveryBusy ||
                    controller.anyTurnActive
                ? null
                : () => unawaited(controller.refreshRuntimes()),
            leadingIcon: controller.runtimeDiscoveryBusy
                ? const SizedBox.square(
                    key: ValueKey('runtime-discovery-progress'),
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 16),
            child: Text(
              controller.runtimeDiscoveryBusy
                  ? 'Refreshing agents…'
                  : 'Refresh agents',
            ),
          ),
          if (controller.runtimeOverridesSupported)
            MenuItemButton(
              key: const ValueKey('open-runtime-setup'),
              style: actionStyle,
              onPressed: busy
                  ? null
                  : () => controller.toggleRuntimeSetupPanel(true),
              leadingIcon: const Icon(Icons.tune_rounded, size: 16),
              child: const Text('Agent setup'),
            ),
        ],
        builder: (context, menu, _) => IconButton(
          key: const ValueKey('new-session'),
          tooltip: 'New agent',
          onPressed: busy
              ? null
              : () => menu.isOpen ? menu.close() : menu.open(),
          icon: const Icon(Icons.add_rounded, size: 20),
        ),
      );
    },
  );
}

String _sessionWorkspaceLabel(String? cwd) {
  final path = cwd?.trim() ?? '';
  if (path.isEmpty) return 'No workspace';
  final segments = path
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String _sessionUpdatedLabel(DateTime? updated) {
  if (updated == null) return '—';
  final elapsed = DateTime.now().difference(updated);
  if (elapsed.inMinutes < 1) return 'now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h';
  return '${elapsed.inDays}d';
}

class _SessionStatusIcon extends StatelessWidget {
  const _SessionStatusIcon({required this.presence});

  final SessionPresence presence;

  @override
  Widget build(BuildContext context) {
    return switch (presence) {
      SessionPresence.running => const SizedBox.square(
        dimension: 15,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      ),
      SessionPresence.unread => Icon(
        Icons.circle,
        size: 10,
        color: Theme.of(context).colorScheme.primary,
      ),
      SessionPresence.active => const Icon(
        Icons.visibility_outlined,
        size: 17,
        color: Color(0xff5f8c6a),
      ),
      SessionPresence.done => Icon(
        Icons.check_circle_outline_rounded,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
  }
}

class RuntimeSetupPanel extends StatefulWidget {
  const RuntimeSetupPanel({required this.controller, this.onAdded, super.key});

  final ZommiController controller;
  final ValueChanged<String>? onAdded;

  @override
  State<RuntimeSetupPanel> createState() => _RuntimeSetupPanelState();
}

class _RuntimeSetupPanelState extends State<RuntimeSetupPanel> {
  String _adapterId = '';
  String _hostId = '';
  String? _executablePath;
  String? _error;
  final _wslPath = TextEditingController();

  @override
  void dispose() {
    _wslPath.dispose();
    super.dispose();
  }

  Map<String, Object?>? get _adapter {
    final adapters = widget.controller.configurableRuntimeAdapters;
    if (adapters.isEmpty) return null;
    return adapters.firstWhere(
      (value) => value['adapterId'] == _adapterId,
      orElse: () => adapters.first,
    );
  }

  List<Map<String, Object?>> get _hosts {
    final kinds = (_adapter?['hostKinds'] as List<Object?>? ?? const [])
        .map((value) => value.toString())
        .toSet();
    return widget.controller.runtimeOverrideHosts
        .where((host) => kinds.contains(host['kind']))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final adapters = widget.controller.configurableRuntimeAdapters;
    final busy = widget.controller.runtimeOverrideBusy;
    final selectedAdapter = _adapter;
    final adapterId = selectedAdapter?['adapterId']?.toString() ?? '';
    final hosts = _hosts;
    final selectedHost = hosts.any((host) => host['id'] == _hostId)
        ? _hostId
        : (hosts.isEmpty ? '' : hosts.first['id']?.toString() ?? '');
    final wslHost = hosts.any(
      (host) => host['id'] == selectedHost && host['kind'] == 'wsl',
    );
    return Material(
      key: const ValueKey('runtime-setup-panel'),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      elevation: 10,
      shadowColor: const Color(0x330d172a),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 520,
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 18),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Advanced agent runtime',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Add a supported CLI that automatic discovery missed',
                          style: TextStyle(
                            fontSize: 10,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('close-runtime-setup'),
                    tooltip: 'Close advanced runtime setup',
                    onPressed: () =>
                        widget.controller.toggleRuntimeSetupPanel(false),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: !widget.controller.runtimeOverridesSupported
                  ? const Center(
                      child: Text(
                        'Runtime setup is unavailable in this core version.',
                      ),
                    )
                  : ListView(
                      key: const ValueKey('runtime-setup-options'),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      children: [
                        const _RuntimeSetupSectionLabel('Agent'),
                        RadioGroup<String>(
                          groupValue: adapterId,
                          onChanged: (value) {
                            if (busy) return;
                            setState(() {
                              _adapterId = value ?? '';
                              _hostId = '';
                              _executablePath = null;
                              _wslPath.clear();
                              _error = null;
                            });
                          },
                          child: Column(
                            key: const ValueKey('runtime-setup-adapter-list'),
                            children: [
                              for (final adapter in adapters)
                                _RuntimeSetupOption(
                                  key: ValueKey(
                                    'runtime-setup-adapter-${adapter['adapterId']}',
                                  ),
                                  value: adapter['adapterId']?.toString() ?? '',
                                  title:
                                      adapter['displayName']?.toString() ?? '',
                                  subtitle:
                                      adapter['protocolName']?.toString() ?? '',
                                  selected:
                                      adapter['adapterId']?.toString() ==
                                      adapterId,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        const _RuntimeSetupSectionLabel('Run on'),
                        RadioGroup<String>(
                          groupValue: selectedHost,
                          onChanged: (value) {
                            if (busy) return;
                            setState(() {
                              _hostId = value ?? '';
                              _executablePath = null;
                              _wslPath.clear();
                              _error = null;
                            });
                          },
                          child: Column(
                            key: const ValueKey('runtime-setup-host-list'),
                            children: [
                              for (final host in hosts)
                                _RuntimeSetupOption(
                                  key: ValueKey(
                                    'runtime-setup-host-${host['id']}',
                                  ),
                                  value: host['id']?.toString() ?? '',
                                  title:
                                      host['displayName']?.toString() ??
                                      'Local',
                                  subtitle: host['kind']?.toString() ?? '',
                                  selected: host['id'] == selectedHost,
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        const _RuntimeSetupSectionLabel('CLI executable'),
                        if (wslHost)
                          TextFormField(
                            key: ValueKey(
                              'runtime-wsl-path-$adapterId-$selectedHost',
                            ),
                            controller: _wslPath,
                            enabled: !busy,
                            style: const TextStyle(fontSize: 12),
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                              hintText: '~/.hermes/bin/codex',
                              labelText: 'Path in WSL',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(12),
                                ),
                              ),
                            ),
                            onChanged: (value) => setState(() {
                              _executablePath = value.trim().isEmpty
                                  ? null
                                  : value.trim();
                            }),
                          )
                        else
                          Container(
                            key: const ValueKey('runtime-override-path'),
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.terminal_rounded, size: 17),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _executablePath ??
                                        'Choose the installed CLI executable',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: _executablePath == null
                                          ? Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                          : Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton(
                                  key: const ValueKey(
                                    'select-runtime-executable',
                                  ),
                                  onPressed: busy || selectedHost.isEmpty
                                      ? null
                                      : () async {
                                          final path = await widget.controller
                                              .chooseRuntimeExecutable(
                                                executionHostId: selectedHost,
                                              );
                                          if (mounted && path != null) {
                                            setState(
                                              () => _executablePath = path,
                                            );
                                          }
                                        },
                                  child: const Text('Choose…'),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 10),
                        if (_error case final error?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              error,
                              key: const ValueKey('runtime-setup-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.tonal(
                            key: const ValueKey('save-runtime-override'),
                            onPressed:
                                widget.controller.runtimeOverrideBusy ||
                                    adapterId.isEmpty ||
                                    _executablePath == null ||
                                    selectedHost.isEmpty
                                ? null
                                : () async {
                                    setState(() => _error = null);
                                    final added = await widget.controller
                                        .saveRuntimeOverride(
                                          adapterId: adapterId,
                                          locator: _executablePath!,
                                          executionHostId: selectedHost,
                                        );
                                    if (!mounted) return;
                                    if (added != null) {
                                      widget.onAdded?.call(added);
                                      widget.controller.toggleRuntimeSetupPanel(
                                        false,
                                      );
                                    } else {
                                      setState(
                                        () => _error = widget.controller.status,
                                      );
                                    }
                                  },
                            child: busy
                                ? const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox.square(
                                        dimension: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                      SizedBox(width: 8),
                                      Text('Detecting…'),
                                    ],
                                  )
                                : const Text('Add runtime'),
                          ),
                        ),
                        if (widget.controller.runtimeOverrides.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          const _RuntimeSetupSectionLabel(
                            'Configured runtimes',
                          ),
                          for (final override
                              in widget.controller.runtimeOverrides)
                            ListTile(
                              key: ValueKey(
                                'runtime-override-${override['id']}',
                              ),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.terminal_rounded,
                                size: 17,
                              ),
                              title: Text(
                                runtimeAdapterDisplayName(
                                  widget.controller,
                                  override['adapterId']?.toString() ?? '',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              subtitle: Text(
                                override['executablePath']?.toString() ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10),
                              ),
                              trailing: IconButton(
                                tooltip: 'Remove runtime',
                                onPressed: widget.controller.runtimeOverrideBusy
                                    ? null
                                    : () => unawaited(
                                        widget.controller.removeRuntimeOverride(
                                          override['id']?.toString() ?? '',
                                        ),
                                      ),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 17,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeSetupSectionLabel extends StatelessWidget {
  const _RuntimeSetupSectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
}

class _RuntimeSetupOption extends StatelessWidget {
  const _RuntimeSetupOption({
    required this.value,
    required this.title,
    required this.subtitle,
    required this.selected,
    super.key,
  });

  final String value;
  final String title;
  final String subtitle;
  final bool selected;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    borderRadius: BorderRadius.circular(12),
    clipBehavior: Clip.antiAlias,
    child: RadioListTile<String>(
      value: value,
      dense: true,
      visualDensity: const VisualDensity(vertical: -3),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10),
      ),
    ),
  );
}

String runtimeAdapterDisplayName(
  ZommiController controller,
  String adapterId,
) =>
    controller.runtimeOverrideAdapters
        .cast<Map<String, Object?>?>()
        .firstWhere(
          (adapter) => adapter?['adapterId'] == adapterId,
          orElse: () => null,
        )?['displayName']
        ?.toString() ??
    adapterId;

enum _ModelSettingsPage { model, profile }

class ModelSettingsPanel extends StatefulWidget {
  const ModelSettingsPanel({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<ModelSettingsPanel> createState() => _ModelSettingsPanelState();
}

class _ModelSettingsPanelState extends State<ModelSettingsPanel> {
  _ModelSettingsPage? _page;
  late int _overviewEpoch = widget.controller.sessionSettingsOverviewEpoch;

  void _setPage(_ModelSettingsPage? page) {
    if (_page == page) return;
    setState(() => _page = page);
    widget.controller.setSessionSettingsDetailOpen(page != null);
  }

  @override
  void didUpdateWidget(covariant ModelSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextEpoch = widget.controller.sessionSettingsOverviewEpoch;
    if (_overviewEpoch != nextEpoch) {
      _overviewEpoch = nextEpoch;
      _page = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.modelSelectionSupported &&
        !widget.controller.profileSelectionSupported) {
      return ModelPanel(
        key: const ValueKey('model-settings-panel'),
        controller: widget.controller,
      );
    }
    final detail = switch (_page) {
      _ModelSettingsPage.model => ModelPanel(
        key: const ValueKey('model-panel'),
        controller: widget.controller,
        onBack: () => _setPage(null),
      ),
      _ModelSettingsPage.profile => ProfilePanel(
        key: const ValueKey('profile-panel'),
        controller: widget.controller,
        onBack: () => _setPage(null),
      ),
      null => null,
    };
    final page =
        detail ??
        Align(
          key: const ValueKey('settings-overview-page'),
          alignment: Alignment.topLeft,
          child: _SettingsOverview(
            controller: widget.controller,
            selected: _page,
            onSelected: _setPage,
          ),
        );
    return AnimatedSize(
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topLeft,
      child: SizedBox(
        key: const ValueKey('model-settings-panel'),
        width: detail == null ? 286 : 390,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 190),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topLeft,
            clipBehavior: Clip.none,
            children: [...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.10, 0),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: page,
        ),
      ),
    );
  }
}

class _SettingsOverview extends StatelessWidget {
  const _SettingsOverview({
    required this.controller,
    required this.selected,
    required this.onSelected,
  });

  final ZommiController controller;
  final _ModelSettingsPage? selected;
  final ValueChanged<_ModelSettingsPage> onSelected;

  @override
  Widget build(BuildContext context) {
    return ZommiOverlayPanelSurface(
      width: 286,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Model settings',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 12),
            _SettingsRow(
              key: const ValueKey('settings-model'),
              icon: Icons.auto_awesome_outlined,
              label: 'Model / reasoning',
              value: controller.modelSummary,
              selected: selected == _ModelSettingsPage.model,
              enabled: controller.modelSelectionSupported,
              onTap: () => onSelected(_ModelSettingsPage.model),
            ),
            if (controller.profileSelectionSupported) ...[
              const SizedBox(height: 5),
              _SettingsRow(
                key: const ValueKey('settings-profile'),
                icon: Icons.person_outline_rounded,
                label: 'Hermes profile',
                value: controller.profileSummary,
                selected: selected == _ModelSettingsPage.profile,
                onTap: () => onSelected(_ModelSettingsPage.profile),
              ),
            ],
            if (controller.sessionSettingsBusy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: LinearProgressIndicator(
                  key: ValueKey('settings-loading'),
                  minHeight: 3,
                  borderRadius: BorderRadius.all(Radius.circular(99)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RuntimePermissionSetting extends StatelessWidget {
  const RuntimePermissionSetting({
    required this.preferences,
    required this.onChanged,
    super.key,
  });
  final AppPreferences preferences;
  final ValueChanged<AppPreferences>? onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: const ValueKey('runtime-full-access'),
    contentPadding: EdgeInsets.zero,
    title: const Text('Full access (YOLO)', style: TextStyle(fontSize: 12)),
    subtitle: Text(
      '${preferences.fullAccessRuntimes ? "Automatically allow tool permissions; agents may change files and run commands without asking." : "Use each agent’s permission settings and show its approval requests."} '
      'Applies to newly started runtimes. Quit and reopen Zommi to change agents already running. '
      'Pi already runs tools without approval. Remote gateway policies still apply.',
      style: const TextStyle(fontSize: 10),
    ),
    value: preferences.fullAccessRuntimes,
    onChanged: onChanged == null
        ? null
        : (value) =>
              onChanged!(preferences.copyWith(fullAccessRuntimes: value)),
  );
}

class AppSettingsPanel extends StatelessWidget {
  const AppSettingsPanel({
    required this.controller,
    required this.preferences,
    required this.onChanged,
    super.key,
  });

  final ZommiController controller;
  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onChanged;

  @override
  Widget build(BuildContext context) {
    return ZommiOverlayPanelSurface(
      key: const ValueKey('app-settings-panel'),
      width: 310,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'App settings',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Text(
                'Build ${String.fromEnvironment('ZOMMI_BUILD_REVISION', defaultValue: 'development')}',
                key: ValueKey('build-revision'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10),
              ),
              RuntimePermissionSetting(
                preferences: preferences,
                onChanged: onChanged,
              ),
              if (controller.desktop case final CapturePermissionBridge bridge
                  when bridge.supportsCapturePermissions)
                CapturePermissionSetup(bridge: bridge),
              if (controller.desktop case final GnomeDesktopSettings bridge
                  when bridge.supportsGnomeIntegration)
                GnomeIntegrationSetup(bridge: bridge),
              if (controller.desktop
                  case final CaptureShortcutSettings settings)
                CaptureShortcutSetting(
                  settings: settings,
                  value: preferences.selectionShortcut,
                  onChanged: (shortcut) => onChanged(
                    preferences.copyWith(selectionShortcut: shortcut),
                  ),
                ),
              if (controller.desktop case final BrowserCaptureSettings settings
                  when settings.supportsBrowserPageDetails)
                SwitchListTile(
                  key: const ValueKey('browser-page-details'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Full webpage details',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  subtitle: const Text(
                    'May ask for browser permission. Off keeps images, screen positions and accessible text; some links may be unavailable.',
                    style: TextStyle(fontSize: 10),
                  ),
                  value: preferences.browserPageDetails,
                  onChanged: (enabled) => onChanged(
                    preferences.copyWith(browserPageDetails: enabled),
                  ),
                ),
              const SizedBox(height: 14),
              const Text(
                'Chat message size',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              SegmentedButton<double>(
                key: const ValueKey('chat-font-size-control'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 12, label: Text('Small')),
                  ButtonSegment(value: 14, label: Text('Default')),
                  ButtonSegment(value: 15, label: Text('Large')),
                  ButtonSegment(value: 17, label: Text('XL')),
                ],
                selected: {preferences.chatFontSize},
                onSelectionChanged: (selection) => onChanged(
                  preferences.copyWith(chatFontSize: selection.single),
                ),
                style: const ButtonStyle(
                  visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(fontSize: 10, fontFamily: codexUiFontFamily),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Theme type',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              SegmentedButton<ThemeMode>(
                key: const ValueKey('theme-mode-control'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {preferences.themeMode},
                onSelectionChanged: (selection) => onChanged(
                  preferences.copyWith(themeMode: selection.single),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Theme color',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 7),
              Row(
                key: const ValueKey('theme-color-control'),
                children: [
                  for (final color in ZommiThemeColor.values) ...[
                    if (color != ZommiThemeColor.values.first)
                      const SizedBox(width: 7),
                    Expanded(
                      child: _ThemeColorChoice(
                        color: color,
                        seed: color == ZommiThemeColor.custom
                            ? preferences.customThemeColor
                            : color.seed,
                        selected: preferences.themeColor == color,
                        onTap: () async {
                          if (color == ZommiThemeColor.custom) {
                            final chosen = await showDialog<Color>(
                              context: context,
                              builder: (_) => ThemeColorPicker(
                                initialColor: preferences.customThemeColor,
                              ),
                            );
                            if (chosen != null) {
                              onChanged(
                                preferences.copyWith(
                                  themeColor: color,
                                  customThemeColor: chosen,
                                ),
                              );
                            }
                          } else {
                            onChanged(preferences.copyWith(themeColor: color));
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeColorChoice extends StatelessWidget {
  const _ThemeColorChoice({
    required this.color,
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final ZommiThemeColor color;
  final Color seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: color.label,
      child: InkWell(
        key: ValueKey('theme-color-${color.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 34,
          decoration: BoxDecoration(
            color: selected ? seed.withValues(alpha: 0.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? seed
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Center(
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(color: seed, shape: BoxShape.circle),
              child: color == ZommiThemeColor.custom
                  ? Icon(
                      Icons.palette_outlined,
                      size: 15,
                      color:
                          ThemeData.estimateBrightnessForColor(seed) ==
                              Brightness.dark
                          ? Colors.white
                          : Colors.black87,
                    )
                  : selected
                  ? Icon(
                      Icons.check_rounded,
                      color:
                          ThemeData.estimateBrightnessForColor(seed) ==
                              Brightness.dark
                          ? Colors.white
                          : Colors.black87,
                      size: 11,
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: enabled
                          ? Theme.of(context).colorScheme.onSurface
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled ? value : 'Not available',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 17,
              color: enabled
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({
    required this.controller,
    required this.onBack,
    super.key,
  });

  final ZommiController controller;
  final VoidCallback onBack;

  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  late final TextEditingController _path = TextEditingController(
    text: widget.controller.selectedWorkspace,
  );
  final FocusNode _focus = FocusNode();
  bool _dirty = false;

  @override
  void dispose() {
    _path.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_dirty && _path.text != widget.controller.selectedWorkspace) {
      _path.text = widget.controller.selectedWorkspace;
    }
    return ZommiOverlayPanelSurface(
      width: 286,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Workspace',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Close workspace',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('workspace-path'),
              controller: _path,
              focusNode: _focus,
              autofocus: true,
              style: const TextStyle(fontSize: 11.5),
              onChanged: (_) {
                _dirty = true;
                widget.controller.clearWorkspaceError();
              },
              onSubmitted: widget.controller.sessionSettingsBusy
                  ? null
                  : (value) => unawaited(_applyWorkspace()),
              decoration: InputDecoration(
                labelText: 'Folder path',
                errorText: widget.controller.workspaceError,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  key: const ValueKey('browse-workspace'),
                  onPressed: widget.controller.sessionSettingsBusy
                      ? null
                      : () => unawaited(_browseWorkspace()),
                  icon: const Icon(Icons.folder_open_outlined, size: 16),
                  label: const Text('Browse', style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  key: const ValueKey('apply-workspace'),
                  onPressed: widget.controller.sessionSettingsBusy
                      ? null
                      : () => unawaited(_applyWorkspace()),
                  child: const Text('Apply', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _browseWorkspace() async {
    final selected = await widget.controller.chooseWorkspace();
    if (!mounted || selected == null) return;
    setState(() {
      _path.value = TextEditingValue(
        text: selected,
        selection: TextSelection.collapsed(offset: selected.length),
      );
      _dirty = true;
    });
    _focus.requestFocus();
  }

  Future<void> _applyWorkspace() async {
    final applied = await widget.controller.setWorkspace(_path.text);
    if (!mounted || !applied) return;
    setState(() => _dirty = false);
    widget.onBack();
  }
}

class ProfilePanel extends StatelessWidget {
  const ProfilePanel({
    required this.controller,
    required this.onBack,
    super.key,
  });

  final ZommiController controller;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return _SettingsDetailShell(
      title: 'Hermes profile',
      onBack: onBack,
      child: Expanded(
        child: ListView.builder(
          key: const ValueKey('profile-list'),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
          itemCount: controller.profiles.length,
          itemBuilder: (context, index) {
            final profile = controller.profiles[index];
            final name = profile['name']?.toString() ?? '';
            final description = profile['description']?.toString().trim();
            final model = profile['model']?.toString().trim();
            final subtitle = description?.isNotEmpty == true
                ? description!
                : model?.isNotEmpty == true
                ? model!
                : 'Hermes profile';
            return RadioGroup<String>(
              groupValue: controller.selectedProfile,
              onChanged: (value) {
                if (!controller.sessionSettingsBusy && value != null) {
                  unawaited(controller.setProfile(value));
                }
              },
              child: RadioListTile<String>(
                key: ValueKey('profile-$name'),
                value: name,
                dense: true,
                visualDensity: const VisualDensity(vertical: -3),
                contentPadding: const EdgeInsets.symmetric(horizontal: 7),
                title: Text(
                  name,
                  style: const TextStyle(fontSize: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitle,
                  style: const TextStyle(fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsDetailShell extends StatelessWidget {
  const _SettingsDetailShell({
    required this.title,
    required this.onBack,
    required this.child,
    this.width = 390,
    this.height = 390,
  });

  final String title;
  final VoidCallback? onBack;
  final Widget child;
  final double width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return ZommiOverlayPanelSurface(
      width: width,
      height: height,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                if (onBack != null)
                  IconButton(
                    key: const ValueKey('settings-back'),
                    tooltip: 'Back to model settings',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded, size: 17),
                  )
                else
                  const SizedBox(width: 16),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          child,
        ],
      ),
    );
  }
}

class ModelPanel extends StatefulWidget {
  const ModelPanel({required this.controller, this.onBack, super.key});

  final ZommiController controller;
  final VoidCallback? onBack;

  @override
  State<ModelPanel> createState() => _ModelPanelState();
}

class _ModelPanelState extends State<ModelPanel> {
  @override
  Widget build(BuildContext context) {
    final models = widget.controller.models;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: (MediaQuery.sizeOf(context).height - 90).clamp(160.0, 390.0),
      ),
      child: _SettingsDetailShell(
        title: 'Model / reasoning',
        onBack: widget.onBack,
        width: 320,
        height: null,
        child: Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: models.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No models available'),
                      )
                    : ListView.builder(
                        key: const ValueKey('model-list'),
                        shrinkWrap: true,
                        primary: false,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: models.length,
                        itemBuilder: (context, index) {
                          final model = models[index];
                          final id =
                              model['model']?.toString() ??
                              model['id']?.toString() ??
                              '';
                          final selected =
                              id == widget.controller.selectedModel;
                          return RadioGroup<String>(
                            groupValue: widget.controller.selectedModel,
                            onChanged: (value) {
                              if (value != null) {
                                widget.controller.setModel(value);
                                setState(() {});
                              }
                            },
                            child: RadioListTile<String>(
                              key: ValueKey('model-$id'),
                              value: id,
                              dense: true,
                              visualDensity: const VisualDensity(
                                horizontal: -4,
                                vertical: -4,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              title: Text(
                                model['displayName']?.toString() ?? id,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: selected,
                            ),
                          );
                        },
                      ),
              ),
              if (widget.controller.selectedModelEfforts.isNotEmpty) ...[
                const Divider(height: 1),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                    child: Text(
                      'Reasoning',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      key: const ValueKey('reasoning-options-row'),
                      children: [
                        for (
                          var index = 0;
                          index < widget.controller.selectedModelEfforts.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(width: 5),
                          ChoiceChip(
                            key: ValueKey(
                              'effort-${widget.controller.selectedModelEfforts[index]}',
                            ),
                            label: Text(
                              widget.controller.selectedModelEfforts[index],
                            ),
                            labelStyle: const TextStyle(fontSize: 10),
                            visualDensity: const VisualDensity(
                              horizontal: -3,
                              vertical: -3,
                            ),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            selected:
                                widget.controller.selectedModelEfforts[index] ==
                                widget.controller.selectedEffort,
                            onSelected: (_) {
                              widget.controller.setEffort(
                                widget.controller.selectedModelEfforts[index],
                              );
                              setState(() {});
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ContextPreviewPanel extends StatelessWidget {
  const ContextPreviewPanel({
    required this.attachment,
    required this.onClose,
    required this.onPointerEnter,
    required this.onPointerExit,
    super.key,
  });

  final ContextAttachment attachment;
  final VoidCallback onClose;
  final VoidCallback onPointerEnter;
  final VoidCallback onPointerExit;

  @override
  Widget build(BuildContext context) {
    final summary = attachment.captureSummary;
    final capturedDetails = attachment.capturedDetailsText;
    final preview = attachment.previewText.isNotEmpty
        ? attachment.previewText
        : capturedDetails;
    final image = attachment.imageDataUrl == null
        ? null
        : decodeImageDataUrl(attachment.imageDataUrl!);
    return MouseRegion(
      onEnter: (_) => onPointerEnter(),
      onExit: (_) => onPointerExit(),
      child: Material(
        key: const ValueKey('context-preview'),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        elevation: 18,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 380,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: 'Close context preview',
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (image != null)
                          SizedBox(
                            key: const ValueKey('context-preview-image-frame'),
                            width: double.infinity,
                            height: 220,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Image.memory(
                                image,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                semanticLabel:
                                    'Attached visual context preview',
                              ),
                            ),
                          ),
                        ExpansionTile(
                          key: ValueKey(
                            'context-captured-details-${attachment.id}',
                          ),
                          title: const Text('Details'),
                          childrenPadding: const EdgeInsets.fromLTRB(
                            16,
                            0,
                            16,
                            16,
                          ),
                          expandedCrossAxisAlignment:
                              CrossAxisAlignment.stretch,
                          children: [
                            SelectableText(
                              '${attachment.reference}. ${attachment.sourceTitle}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (summary.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: SelectableText(
                                  summary,
                                  key: const ValueKey(
                                    'context-capture-summary',
                                  ),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            if (preview.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: SelectableText(
                                  preview,
                                  key: const ValueKey('context-preview-text'),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                            if (attachment.previewText.isNotEmpty &&
                                capturedDetails.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: SelectableText(
                                  capturedDetails,
                                  key: const ValueKey('context-captured-json'),
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10.5,
                                    height: 1.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
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

class ApprovalDialogCard extends StatelessWidget {
  const ApprovalDialogCard({required this.controller, super.key});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final request = controller.approval!;
    return _ModalCard(
      semanticLabel: 'Agent requests permission',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${controller.approvalSource}${controller.pendingApprovalCount > 1 ? " · ${controller.pendingApprovalCount} pending" : ""}',
            key: const ValueKey('approval-source'),
            style: const TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 6),
          Text(
            request.title,
            key: const ValueKey('approval-title'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          if (request.detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: SingleChildScrollView(
                child: SelectableText(
                  request.detail,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in request.options)
                FilledButton.tonal(
                  key: ValueKey('approval-${option.id}'),
                  autofocus:
                      option.isReject &&
                      identical(
                        option,
                        request.options.where((item) => item.isReject).first,
                      ),
                  onPressed: controller.resolvingPrompt
                      ? null
                      : () => unawaited(controller.resolveApproval(option.id)),
                  style: option.isReject
                      ? FilledButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                        )
                      : null,
                  child: Text(option.label),
                ),
              if (!request.options.any((option) => option.isReject))
                TextButton(
                  key: const ValueKey('approval-deny'),
                  onPressed: controller.resolvingPrompt
                      ? null
                      : () => unawaited(controller.resolveApproval(null)),
                  child: const Text('Deny'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class QuestionDialogCard extends StatefulWidget {
  const QuestionDialogCard({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<QuestionDialogCard> createState() => _QuestionDialogCardState();
}

class _QuestionDialogCardState extends State<QuestionDialogCard> {
  final TextEditingController _input = TextEditingController();
  final Map<String, Set<String>> _answers = {};
  final Map<String, TextEditingController> _other = {};

  PendingQuestion get request => widget.controller.question!;

  @override
  void initState() {
    super.initState();
    _input.text = request.sensitive ? '' : request.prefill;
    for (final question in request.questions) {
      _answers[question.id] = {};
      _other[question.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    for (final controller in _other.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            unawaited(_submit()),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
            unawaited(_submit()),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(widget.controller.resolveQuestion({})),
      },
      child: _ModalCard(
        semanticLabel: 'Agent asks a question',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              request.title,
              key: const ValueKey('question-title'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(request.message),
            ],
            const SizedBox(height: 12),
            if (request.questions.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 390),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final question in request.questions.take(3))
                        _structuredQuestion(question),
                    ],
                  ),
                ),
              )
            else if (request.method == 'confirm')
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const ValueKey('question-yes'),
                    onPressed: () => unawaited(
                      widget.controller.resolveQuestion({'confirmed': true}),
                    ),
                    child: const Text('Yes'),
                  ),
                  FilledButton.tonal(
                    key: const ValueKey('question-no'),
                    onPressed: () => unawaited(
                      widget.controller.resolveQuestion({'confirmed': false}),
                    ),
                    child: const Text('No'),
                  ),
                ],
              )
            else if (request.method == 'select')
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in request.options)
                    FilledButton.tonal(
                      key: ValueKey('question-option-${option.value}'),
                      onPressed: () => unawaited(
                        widget.controller.resolveQuestion({
                          'value': option.value,
                        }),
                      ),
                      child: Text(option.label),
                    ),
                ],
              )
            else
              TextField(
                key: const ValueKey('question-input'),
                controller: _input,
                autofocus: true,
                obscureText: request.sensitive,
                minLines: request.sensitive ? 1 : 2,
                maxLines: request.sensitive ? 1 : 4,
                decoration: InputDecoration(
                  hintText: request.placeholder,
                  border: const OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('question-cancel'),
                  onPressed: widget.controller.resolvingPrompt
                      ? null
                      : () => unawaited(widget.controller.resolveQuestion({})),
                  child: const Text('Cancel'),
                ),
                if (request.questions.isNotEmpty ||
                    !{'confirm', 'select'}.contains(request.method)) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('question-submit'),
                    onPressed: widget.controller.resolvingPrompt
                        ? null
                        : () => unawaited(_submit()),
                    child: const Text('Submit'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _structuredQuestion(StructuredQuestion question) {
    final selected = _answers[question.id]!;
    return Container(
      key: ValueKey('structured-question-${question.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            question.header,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (question.question.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(question.question),
          ],
          const SizedBox(height: 6),
          for (final option in question.options.take(4))
            if (question.multiSelect)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: selected.contains(option.value),
                title: Text(option.label),
                subtitle: option.detail == null ? null : Text(option.detail!),
                onChanged: (checked) => setState(() {
                  checked == true
                      ? selected.add(option.value)
                      : selected.remove(option.value);
                }),
              )
            else
              RadioGroup<String>(
                groupValue: selected.firstOrNull,
                onChanged: (value) => setState(() {
                  selected
                    ..clear()
                    ..addAll(value == null ? const [] : [value]);
                }),
                child: RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: option.value,
                  title: Text(option.label),
                  subtitle: option.detail == null ? null : Text(option.detail!),
                ),
              ),
          if (question.allowOther || question.options.isEmpty)
            TextField(
              controller: _other[question.id],
              obscureText: question.secret,
              decoration: InputDecoration(
                hintText: question.options.isEmpty
                    ? 'Your answer'
                    : 'Other answer',
                isDense: true,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _submit() {
    if (request.questions.isEmpty) {
      return widget.controller.resolveQuestion({'value': _input.text});
    }
    final result = <String, List<String>>{};
    for (final question in request.questions) {
      final values = List<String>.of(_answers[question.id] ?? const {});
      final other = _other[question.id]?.text.trim() ?? '';
      if (other.isNotEmpty) values.add(other);
      result[question.id] = values;
    }
    return widget.controller.resolveQuestion({'answers': result});
  }
}

class ArtifactViewerDialog extends StatelessWidget {
  const ArtifactViewerDialog({required this.controller, super.key});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final artifact = controller.previewArtifact!;
    return Positioned.fill(
      top: 64,
      left: 24,
      right: 24,
      bottom: 24,
      child: TapRegion(
        consumeOutsideTaps: true,
        onTapOutside: (_) => controller.closeArtifact(),
        child: Material(
          key: const ValueKey('artifact-viewer'),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          elevation: 22,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 9, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        artifact.title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      autofocus: true,
                      tooltip: 'Close artifact preview',
                      onPressed: controller.closeArtifact,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child:
                    (artifact.kind == 'html' || artifact.kind == 'markdown') &&
                        artifact.html != null
                    ? DocumentPreview(
                        key: ValueKey(artifact.id),
                        artifact: artifact,
                        onDismiss: controller.closeArtifact,
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(18),
                        child: ArtifactSurface(artifact: artifact),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModalCard extends StatelessWidget {
  const _ModalCard({required this.semanticLabel, required this.child});

  final String semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        elevation: 24,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
          child: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    );
  }
}

// Keep sibling portal anchors separate inside a ListView item. Flutter 3.47
// can otherwise drop an anchor while merging the item's semantics, freezing
// the native accessibility tree (flutter/flutter#182444 and #190344).
class _SessionTooltip extends StatelessWidget {
  const _SessionTooltip({required this.message, required this.child});

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Tooltip(message: message, child: child),
  );
}
