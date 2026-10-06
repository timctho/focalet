import 'package:flutter/material.dart';
import 'package:focalet_flutter/desktop/capture_permissions.dart';
import 'package:focalet_flutter/widgets/screen_recording_permission_dialog.dart';

class CapturePermissionSetup extends StatefulWidget {
  const CapturePermissionSetup({required this.bridge, super.key});

  final CapturePermissionBridge bridge;

  @override
  State<CapturePermissionSetup> createState() => _CapturePermissionSetupState();
}

class _CapturePermissionSetupState extends State<CapturePermissionSetup>
    with WidgetsBindingObserver {
  CapturePermissionStatus? _status;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh([CapturePermission? permission]) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (permission == CapturePermission.screenRecording) {
        await showScreenRecordingPermissionDialog(
          context,
          bridge: widget.bridge,
        );
      }
      final status =
          permission == null || permission == CapturePermission.screenRecording
          ? await widget.bridge.capturePermissions()
          : await widget.bridge.requestCapturePermission(permission);
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _error = 'Could not check capture permissions.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Row(
        children: [
          const Expanded(child: Text('Capture permissions')),
          IconButton(
            tooltip: 'Check capture permissions',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded, size: 17),
          ),
        ],
      ),
      for (final permission in CapturePermission.values)
        Row(
          children: [
            Expanded(
              child: Text(switch (permission) {
                CapturePermission.accessibility =>
                  'Accessibility · app context',
                CapturePermission.screenRecording =>
                  'Screen Recording · images',
              }, style: const TextStyle(fontSize: 11)),
            ),
            if (_status?.granted(permission) == true)
              const Icon(Icons.check_circle_outline_rounded, size: 18)
            else
              TextButton(
                key: ValueKey('allow-${permission.name}'),
                onPressed: _busy ? null : () => _refresh(permission),
                child: const Text('Allow'),
              ),
          ],
        ),
      Text(
        _error ??
            'You can enable these later. macOS may ask you to restart Focalet.',
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}
