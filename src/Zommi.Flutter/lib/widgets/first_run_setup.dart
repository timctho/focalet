import 'package:flutter/material.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/widgets/capture_permission_setup.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/widgets/overlay_panels.dart';
import 'package:zommi_flutter/widgets/runtime_logo.dart';

/// First-install setup stays open until the user connects or explicitly skips.
class FirstRunSetup extends StatefulWidget {
  const FirstRunSetup({
    required this.controller,
    required this.onCompleted,
    super.key,
  });

  final ZommiController controller;
  final Future<void> Function() onCompleted;

  @override
  State<FirstRunSetup> createState() => _FirstRunSetupState();
}

class _FirstRunSetupState extends State<FirstRunSetup> {
  String? _selectedTarget;
  bool _saving = false;
  String? _error;

  Future<void> _finish({String? targetId}) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (targetId != null &&
          (widget.controller.activeRuntime?.id != targetId ||
              widget.controller.activeSessionId == null) &&
          !await widget.controller.connectRuntimeForSetup(targetId)) {
        return;
      }
      await widget.onCompleted();
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not save setup. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.runtimeSetupPanelOpen) {
      return RuntimeSetupPanel(controller: controller);
    }
    final targets = controller.visibleRuntimeTargets;
    final selected = targets.any((target) => target.id == _selectedTarget)
        ? _selectedTarget
        : targets.firstOrNull?.id;
    final busy =
        controller.starting ||
        controller.runtimeBusy ||
        controller.runtimeDiscoveryBusy ||
        _saving;
    final colors = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
      child: Material(
        key: const ValueKey('first-run-setup'),
        color: colors.surfaceContainerLow,
        elevation: 8,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.waving_hand_outlined,
                      size: 30,
                      color: colors.primary,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Welcome to Zommi',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Choose an agent to connect. Your agent keeps its own account and settings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (controller.starting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Column(
                          children: [
                            SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(height: 12),
                            Text('Finding installed agents…'),
                          ],
                        ),
                      )
                    else if (targets.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'No agents found. Install your preferred agent, then scan again, or choose an installed executable below.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      RadioGroup<String>(
                        groupValue: selected,
                        onChanged: busy
                            ? (_) {}
                            : (value) =>
                                  setState(() => _selectedTarget = value),
                        child: Column(
                          children: [
                            for (final target in targets)
                              RadioListTile<String>(
                                key: ValueKey('setup-runtime-${target.id}'),
                                value: target.id,
                                enabled: !busy,
                                contentPadding: EdgeInsets.zero,
                                title: Row(
                                  children: [
                                    RuntimeLogo(runtimeId: target.runtimeId),
                                    const SizedBox(width: 9),
                                    Expanded(child: Text(target.displayName)),
                                    Text(
                                      target.status == 'sign-in-required'
                                          ? 'Sign in needed'
                                          : 'Detected',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                                subtitle: Text(
                                  target.executionHost['displayName']
                                          ?.toString() ??
                                      'This computer',
                                  style: const TextStyle(fontSize: 10.5),
                                ),
                                secondary: target.status == 'sign-in-required'
                                    ? TextButton(
                                        onPressed: busy
                                            ? null
                                            : () =>
                                                  controller.openRuntimeSignIn(
                                                    runtimeTargetId: target.id,
                                                  ),
                                        child: const Text('Sign in'),
                                      )
                                    : null,
                              ),
                          ],
                        ),
                      ),
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton.icon(
                          key: const ValueKey('setup-rescan'),
                          onPressed: busy ? null : controller.refreshRuntimes,
                          icon: controller.runtimeDiscoveryBusy
                              ? const SizedBox.square(
                                  dimension: 17,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                  ),
                                )
                              : const Icon(Icons.refresh_rounded, size: 17),
                          label: Text(
                            controller.runtimeDiscoveryBusy
                                ? 'Scanning…'
                                : 'Scan again',
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('setup-configure'),
                          onPressed: busy
                              ? null
                              : () => controller.toggleRuntimeSetupPanel(true),
                          icon: const Icon(Icons.tune_rounded, size: 17),
                          label: const Text('Configure runtime'),
                        ),
                      ],
                    ),
                    if (_error != null ||
                        controller.runtimeDiscoveryError != null ||
                        controller.statusWarning)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          _error ??
                              controller.runtimeDiscoveryError ??
                              controller.status,
                          key: const ValueKey('setup-error'),
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (controller.desktop
                        case final CapturePermissionBridge permissions)
                      if (permissions.supportsCapturePermissions)
                        CapturePermissionSetup(bridge: permissions),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton(
                    key: const ValueKey('setup-continue'),
                    onPressed: busy || selected == null
                        ? null
                        : () => _finish(targetId: selected),
                    child: Text(
                      _saving ? 'Connecting…' : 'Connect and continue',
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('setup-skip'),
                    onPressed: busy ? null : () => _finish(),
                    child: const Text('Set up later'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
