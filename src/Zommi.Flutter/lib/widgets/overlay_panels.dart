import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/theme/app_preferences.dart';
import 'package:zommi_flutter/widgets/content_views.dart';
import 'package:zommi_flutter/widgets/runtime_logo.dart';

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
      color: zommiOverlayPanelColor,
      surfaceTintColor: Colors.transparent,
      shadowColor: zommiOverlayPanelShadowColor,
      elevation: zommiOverlayPanelElevation,
      borderRadius: BorderRadius.circular(zommiOverlayPanelRadius),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(width: width, height: height, child: child),
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

  @override
  Widget build(BuildContext context) {
    final sessions = controller.visibleSessions;
    return Semantics(
      container: true,
      label: 'Chat sessions',
      child: Material(
        key: const ValueKey('session-sidebar'),
        color: const Color(0xf6f6f8fc),
        elevation: 0,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Chats',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('new-session'),
                    tooltip: 'Create new chat',
                    enabled: !controller.sessionBusy && !controller.runtimeBusy,
                    position: PopupMenuPosition.under,
                    color: zommiOverlayPanelColor,
                    surfaceTintColor: Colors.transparent,
                    elevation: zommiOverlayPanelElevation,
                    shadowColor: zommiOverlayPanelShadowColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        zommiOverlayPanelRadius,
                      ),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 250,
                      maxWidth: 320,
                    ),
                    onSelected: (id) {
                      if (id == 'action:refresh') {
                        unawaited(controller.refreshRuntimes());
                      } else if (id == 'action:setup') {
                        controller.toggleRuntimeSetupPanel(true);
                      } else if (id.startsWith('sign-in:')) {
                        unawaited(
                          controller.openRuntimeSignIn(
                            runtimeTargetId: id.substring('sign-in:'.length),
                          ),
                        );
                      } else {
                        unawaited(
                          controller.createSession(runtimeTargetId: id),
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        enabled: false,
                        height: 36,
                        child: Text(
                          'New chat with',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Color(0xff3c4352),
                          ),
                        ),
                      ),
                      for (final target in controller.visibleRuntimeTargets)
                        PopupMenuItem<String>(
                          key: ValueKey('create-session-${target.id}'),
                          value: target.id,
                          enabled: controller.canCreateSession(target),
                          child: Row(
                            children: [
                              RuntimeLogo(
                                runtimeId: target.runtimeId,
                                size: 16,
                              ),
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
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xff737887),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      for (final target in controller.visibleRuntimeTargets)
                        if (target.status == 'sign-in-required')
                          PopupMenuItem<String>(
                            key: ValueKey('runtime-sign-in-${target.id}'),
                            value: 'sign-in:${target.id}',
                            child: Text('Sign in to ${target.displayName}'),
                          ),
                      const PopupMenuItem<String>(
                        key: ValueKey('refresh-runtimes'),
                        value: 'action:refresh',
                        child: Text('Refresh agents'),
                      ),
                      if (controller.runtimeOverridesSupported)
                        const PopupMenuItem<String>(
                          key: ValueKey('open-runtime-setup'),
                          value: 'action:setup',
                          child: Text('Agent setup'),
                        ),
                    ],
                    icon: controller.sessionBusy || controller.runtimeBusy
                        ? const SizedBox.square(
                            key: ValueKey('session-loading-indicator'),
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded, size: 20),
                  ),
                ],
              ),
            ),
            if (controller.sessionCatalogLoading)
              const LinearProgressIndicator(
                key: ValueKey('session-catalog-loading'),
                minHeight: 2,
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
                      return const Padding(
                        padding: EdgeInsets.all(18),
                        child: Text(
                          'No recent chats are available.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xff737887)),
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
                    return Semantics(
                      selected: selected,
                      label:
                          '${session.title}, ${runtime?.displayName ?? 'Agent'}, ${presence.name} session',
                      child: ListTile(
                        key: ValueKey(
                          'session-${session.runtimeTargetId}-${session.id}',
                        ),
                        dense: true,
                        visualDensity: const VisualDensity(vertical: -3),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                        ),
                        selected: selected,
                        selectedTileColor: const Color(0xffebe9f7),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minLeadingWidth: 0,
                        horizontalTitleGap: 9,
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 18,
                              child: Center(
                                child: _SessionStatusIcon(presence: presence),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Tooltip(
                              message: runtime?.displayName ?? 'Agent runtime',
                              child: RuntimeLogo(
                                key: ValueKey(
                                  'session-runtime-${session.runtimeTargetId}-${session.id}',
                                ),
                                runtimeId: runtime?.runtimeId ?? '',
                              ),
                            ),
                          ],
                        ),
                        title: Text(
                          session.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
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
      SessionPresence.unread => const Icon(
        Icons.circle,
        size: 10,
        color: Color(0xff887cc8),
      ),
      SessionPresence.active => const Icon(
        Icons.visibility_outlined,
        size: 17,
        color: Color(0xff5f8c6a),
      ),
      SessionPresence.done => const Icon(
        Icons.check_circle_outline_rounded,
        size: 16,
        color: Color(0xff8b909d),
      ),
    };
  }
}

class RuntimeSetupPanel extends StatefulWidget {
  const RuntimeSetupPanel({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<RuntimeSetupPanel> createState() => _RuntimeSetupPanelState();
}

class _RuntimeSetupPanelState extends State<RuntimeSetupPanel> {
  String _adapterId = '';
  String _hostId = '';
  String? _executablePath;

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
    final selectedAdapter = _adapter;
    final adapterId = selectedAdapter?['adapterId']?.toString() ?? '';
    final hosts = _hosts;
    final selectedHost = hosts.any((host) => host['id'] == _hostId)
        ? _hostId
        : (hosts.isEmpty ? '' : hosts.first['id']?.toString() ?? '');
    return Material(
      key: const ValueKey('runtime-setup-panel'),
      color: const Color(0xfff8f9fd),
      elevation: 10,
      shadowColor: const Color(0x330d172a),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: Color(0xffe0e3ec)),
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
                  const Expanded(
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
                            color: Color(0xff737887),
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
                          onChanged: (value) => setState(() {
                            _adapterId = value ?? '';
                            _hostId = '';
                            _executablePath = null;
                          }),
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
                          onChanged: (value) => setState(() {
                            _hostId = value ?? '';
                            _executablePath = null;
                          }),
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
                        Container(
                          key: const ValueKey('runtime-override-path'),
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xfff1f2f7),
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
                                        ? const Color(0xff777c89)
                                        : const Color(0xff333744),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                key: const ValueKey(
                                  'select-runtime-executable',
                                ),
                                onPressed: selectedHost.isEmpty
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
                                    await widget.controller.saveRuntimeOverride(
                                      adapterId: adapterId,
                                      locator: _executablePath!,
                                      executionHostId: selectedHost,
                                    );
                                    if (mounted) {
                                      setState(() => _executablePath = null);
                                    }
                                  },
                            child: const Text('Add runtime'),
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
  Widget build(BuildContext context) => RadioListTile<String>(
    value: value,
    dense: true,
    visualDensity: const VisualDensity(vertical: -3),
    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
    selected: selected,
    selectedTileColor: const Color(0xffebe9f7),
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

class AppSettingsPanel extends StatelessWidget {
  const AppSettingsPanel({
    required this.controller,
    required this.preferences,
    required this.onChanged,
    required this.onWindowSizeChanged,
    super.key,
  });

  final ZommiController controller;
  final AppPreferences preferences;
  final ValueChanged<AppPreferences> onChanged;
  final ValueChanged<WindowSizeSetting> onWindowSizeChanged;

  @override
  Widget build(BuildContext context) {
    return ZommiOverlayPanelSurface(
      key: const ValueKey('app-settings-panel'),
      width: 310,
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
                ButtonSegment(value: 13, label: Text('Default')),
                ButtonSegment(value: 14, label: Text('Large')),
                ButtonSegment(value: 15, label: Text('XL')),
              ],
              selected: {preferences.chatFontSize},
              onSelectionChanged: (selection) => onChanged(
                preferences.copyWith(chatFontSize: selection.single),
              ),
              style: const ButtonStyle(
                visualDensity: VisualDensity(horizontal: -3, vertical: -3),
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10)),
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
                      selected: preferences.themeColor == color,
                      onTap: () =>
                          onChanged(preferences.copyWith(themeColor: color)),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Window size',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 7),
            SegmentedButton<WindowSizeSetting>(
              key: const ValueKey('window-size-control'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: WindowSizeSetting.standard,
                  icon: Icon(Icons.crop_portrait_rounded, size: 15),
                  label: Text('Standard'),
                ),
                ButtonSegment(
                  value: WindowSizeSetting.wide,
                  icon: Icon(Icons.open_in_full_rounded, size: 15),
                  label: Text('Wide'),
                ),
                ButtonSegment(
                  value: WindowSizeSetting.maximized,
                  icon: Icon(Icons.crop_square_rounded, size: 15),
                  label: Text('Max', maxLines: 1, softWrap: false),
                ),
              ],
              selected: {controller.windowSize},
              onSelectionChanged: controller.surfaceTransitioning
                  ? null
                  : (selection) {
                      if (selection.single != controller.windowSize) {
                        onWindowSizeChanged(selection.single);
                      }
                    },
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeColorChoice extends StatelessWidget {
  const _ThemeColorChoice({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final ZommiThemeColor color;
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
            color: selected
                ? color.seed.withValues(alpha: 0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color.seed : const Color(0xffd9dde7),
            ),
          ),
          child: Center(
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: color.seed,
                shape: BoxShape.circle,
              ),
              child: selected
                  ? const Icon(
                      Icons.check_rounded,
                      color: Colors.white,
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
          color: selected ? const Color(0xffe9edf8) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17, color: const Color(0xff4f596d)),
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
                          ? const Color(0xff3c4352)
                          : Colors.blueGrey.shade300,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    enabled ? value : 'Not available',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.blueGrey.shade500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 17,
              color: enabled
                  ? Colors.blueGrey.shade400
                  : Colors.blueGrey.shade200,
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
    this.height = 390,
  });

  final String title;
  final VoidCallback onBack;
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ZommiOverlayPanelSurface(
      width: 390,
      height: height,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('settings-back'),
                  tooltip: 'Back to model settings',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_rounded, size: 17),
                ),
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

double modelSettingsPanelHeight(
  int optionCount, {
  required bool showReasoning,
}) {
  final visibleRows = optionCount.clamp(1, 5);
  final height = 110 + (visibleRows * 48) + (showReasoning ? 72 : 12);
  return height.clamp(190, 390).toDouble();
}

class ModelPanel extends StatefulWidget {
  const ModelPanel({required this.controller, required this.onBack, super.key});

  final ZommiController controller;
  final VoidCallback onBack;

  @override
  State<ModelPanel> createState() => _ModelPanelState();
}

class _ModelPanelState extends State<ModelPanel> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final models = widget.controller.models
        .where((model) {
          if (query.isEmpty) return true;
          final name =
              '${model['displayName'] ?? ''} ${model['model'] ?? model['id'] ?? ''}'
                  .toLowerCase();
          return name.contains(query);
        })
        .toList(growable: false);
    return _SettingsDetailShell(
      title: 'Model / reasoning',
      onBack: widget.onBack,
      height: modelSettingsPanelHeight(
        models.length,
        showReasoning: widget.controller.selectedModelEfforts.isNotEmpty,
      ),
      child: Expanded(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const ValueKey('model-search'),
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 11.5),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded, size: 17),
                  prefixIconConstraints: BoxConstraints(minWidth: 34),
                  hintText: 'Search models',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: models.isEmpty
                  ? const Center(child: Text('No matching models'))
                  : ListView.builder(
                      key: const ValueKey('model-list'),
                      itemCount: models.length,
                      itemBuilder: (context, index) {
                        final model = models[index];
                        final id =
                            model['model']?.toString() ??
                            model['id']?.toString() ??
                            '';
                        final selected = id == widget.controller.selectedModel;
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
                            visualDensity: const VisualDensity(vertical: -3),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Text(
                              model['displayName']?.toString() ?? id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            subtitle: model['description'] == null
                                ? null
                                : Text(
                                    model['description'].toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
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
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
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
    final image = attachment.imageDataUrl == null
        ? null
        : decodeImageDataUrl(attachment.imageDataUrl!);
    return MouseRegion(
      onEnter: (_) => onPointerEnter(),
      onExit: (_) => onPointerExit(),
      child: Material(
        key: const ValueKey('context-preview'),
        color: const Color(0xfaf7f9fd),
        elevation: 18,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 380,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 7, 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${attachment.reference} · ${attachment.sourceTitle}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close context preview',
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                if (image != null || attachment.detailsText.isNotEmpty)
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (image != null)
                            SizedBox(
                              key: const ValueKey(
                                'context-preview-image-frame',
                              ),
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
                          if (attachment.detailsText.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                              child: SelectableText(
                                attachment.detailsText,
                                key: const ValueKey('context-preview-text'),
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 10.5,
                                  height: 1.4,
                                ),
                              ),
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
                  autofocus: identical(option, request.options.first),
                  onPressed: controller.resolvingPrompt
                      ? null
                      : () => unawaited(controller.resolveApproval(option.id)),
                  style: option.isReject
                      ? FilledButton.styleFrom(
                          foregroundColor: const Color(0xff9b4050),
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
        border: Border.all(color: const Color(0xffe1e4ec)),
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
      child: Material(
        key: const ValueKey('artifact-viewer'),
        color: const Color(0xfff8f9fc),
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
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: ArtifactSurface(artifact: artifact),
              ),
            ),
          ],
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
        color: const Color(0xfffbfbfd),
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
