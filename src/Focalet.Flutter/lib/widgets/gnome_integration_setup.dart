import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:focalet_flutter/desktop/gnome_integration.dart';

class GnomeIntegrationSetup extends StatefulWidget {
  const GnomeIntegrationSetup({required this.bridge, super.key});
  final GnomeDesktopSettings bridge;
  @override
  State<GnomeIntegrationSetup> createState() => _GnomeIntegrationSetupState();
}

class _GnomeIntegrationSetupState extends State<GnomeIntegrationSetup> {
  bool _busy = false;
  bool _ready = false;
  bool _canEnable = true;
  String _enableLabel = 'Enable desktop integration';
  String? _diagnostics;
  String _message =
      'Enable desktop integration for Alt+A and app context. You choose which screens to share when selecting content.';
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check({bool enable = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.bridge.gnomeIntegrationStatus(enable: enable);
      if (mounted) {
        setState(() {
          _ready = result['ready'] == true;
          _message = result['message']?.toString() ?? _message;
          _canEnable = result['canEnable'] != false;
          _enableLabel =
              result['enableLabel']?.toString() ?? 'Enable desktop integration';
          _diagnostics = result['diagnostics'] is Map
              ? const JsonEncoder.withIndent('  ').convert(result)
              : null;
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _ready = false;
          _canEnable = true;
          _enableLabel = 'Retry desktop integration';
          _diagnostics = null;
          _message = '$error'.replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Divider(),
      Row(
        children: [
          const Expanded(
            child: Text(
              'Ubuntu desktop integration',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
          if (_ready) const Icon(Icons.check_circle_outline, size: 18),
          if (_diagnostics != null)
            IconButton(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _diagnostics!)),
              tooltip: 'Copy desktop diagnostics',
              icon: const Icon(Icons.copy_outlined, size: 16),
            ),
          IconButton(
            onPressed: _busy ? null : _check,
            tooltip: 'Check desktop integration',
            icon: const Icon(Icons.refresh, size: 17),
          ),
        ],
      ),
      Text(_message, style: const TextStyle(fontSize: 10)),
      if (!_ready && _canEnable)
        TextButton(
          key: const ValueKey('enable-gnome-integration'),
          onPressed: _busy ? null : () => _check(enable: true),
          child: Text(_busy ? 'Checking…' : _enableLabel),
        ),
    ],
  );
}
