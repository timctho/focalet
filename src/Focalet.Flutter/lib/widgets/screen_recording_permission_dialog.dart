import 'package:flutter/material.dart';
import 'package:focalet_flutter/desktop/capture_permissions.dart';

Future<bool> showScreenRecordingPermissionDialog(
  BuildContext context, {
  required CapturePermissionBridge bridge,
  bool continueToSelection = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ScreenRecordingPermissionDialog(
        bridge: bridge,
        continueToSelection: continueToSelection,
      ),
    ) ??
    false;

class _ScreenRecordingPermissionDialog extends StatefulWidget {
  const _ScreenRecordingPermissionDialog({
    required this.bridge,
    required this.continueToSelection,
  });

  final CapturePermissionBridge bridge;
  final bool continueToSelection;

  @override
  State<_ScreenRecordingPermissionDialog> createState() =>
      _ScreenRecordingPermissionDialogState();
}

class _ScreenRecordingPermissionDialogState
    extends State<_ScreenRecordingPermissionDialog>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _granted = false;
  bool _openedSettings = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check({bool openSettings = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _openedSettings |= openSettings;
    });
    try {
      final status = openSettings
          ? await widget.bridge.requestCapturePermission(
              CapturePermission.screenRecording,
            )
          : await widget.bridge.capturePermissions();
      if (mounted) setState(() => _granted = status.screenRecording);
    } on Object {
      if (mounted) {
        setState(() {
          _error = openSettings
              ? 'Could not open System Settings. Open it from the Apple menu and follow the steps above.'
              : 'Could not check permission. Try Check again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('screen-recording-permission-dialog'),
    icon: const Icon(Icons.screenshot_monitor_rounded),
    title: Text(_granted ? 'Screenshots are ready' : 'Allow screenshots'),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_granted)
            const Text(
              'Screen Recording is enabled for Focalet. You can now drag to select an area.',
            )
          else ...[
            const Text(
              'macOS requires Screen Recording permission to capture the area you select.',
            ),
            const SizedBox(height: 16),
            const Text('1. Click Open System Settings below.'),
            const SizedBox(height: 8),
            const Text(
              '2. In Privacy & Security → Screen & System Audio Recording, turn on Focalet. On older macOS versions, this is called Screen Recording.',
            ),
            const SizedBox(height: 8),
            const Text(
              '3. If macOS asks, choose Quit & Reopen. Then try Select again.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Focalet missing from the list? Click + and choose Focalet in Applications.',
            ),
            if (_openedSettings) ...[
              const SizedBox(height: 12),
              const Text(
                'Already enabled it? Click Check again. If it still is not detected, quit and reopen Focalet.',
              ),
            ],
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (!_granted) ...[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not now'),
        ),
        if (_openedSettings || _error != null)
          TextButton(
            onPressed: _busy ? null : _check,
            child: const Text('Check again'),
          ),
        FilledButton(
          onPressed: _busy ? null : () => _check(openSettings: true),
          child: const Text('Open System Settings'),
        ),
      ] else
        FilledButton(
          onPressed: _busy ? null : () => Navigator.pop(context, true),
          child: Text(widget.continueToSelection ? 'Start selecting' : 'Done'),
        ),
    ],
  );
}
