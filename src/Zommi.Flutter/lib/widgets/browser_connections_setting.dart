import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zommi_flutter/desktop/browser_connections.dart';

class BrowserConnectionsSetting extends StatefulWidget {
  const BrowserConnectionsSetting({
    required this.settings,
    required this.enabled,
    super.key,
  });

  final BrowserConnectionSettings settings;
  final bool enabled;

  @override
  State<BrowserConnectionsSetting> createState() =>
      _BrowserConnectionsSettingState();
}

class _BrowserConnectionsSettingState extends State<BrowserConnectionsSetting> {
  final Map<CaptureBrowser, BrowserConnectionStatus> _statuses = {};
  CaptureBrowser? _connecting;
  String? _error;
  bool _loading = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(covariant BrowserConnectionsSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.settings != widget.settings) {
      _connecting = null;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final statuses = await widget.settings.browserConnections();
      if (!mounted || generation != _generation) return;
      setState(() {
        _statuses
          ..clear()
          ..addEntries(
            statuses.map((status) => MapEntry(status.browser, status)),
          );
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _statuses.clear();
          _error = 'Could not check browser access. Try refreshing.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _reconnect(CaptureBrowser browser) async {
    final generation = ++_generation;
    setState(() {
      _connecting = browser;
      _error = null;
    });
    try {
      final status = await widget.settings.reconnectBrowser(browser);
      if (!mounted || generation != _generation) return;
      setState(() => _statuses[browser] = status);
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _statuses.clear();
          _error = 'Could not connect to ${browser.label}. Try again.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _connecting = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('browser-connections'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Browser connections',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
            IconButton(
              key: const ValueKey('refresh-browser-connections'),
              tooltip: 'Refresh browser status',
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              onPressed: _loading || _connecting != null ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const Text(
          'Zommi uses the browser you select. Both can stay connected.',
          style: TextStyle(fontSize: 10),
        ),
        for (final browser in CaptureBrowser.values) _browserRow(browser),
        if (_statuses.values.any((status) => status.explicitEndpoint))
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'A custom browser connection overrides automatic discovery. Remove ZOMMI_BROWSER_CDP_ENDPOINT from Zommi’s launch environment and restart Zommi to discover both browsers.',
              key: ValueKey('browser-endpoint-override'),
              style: TextStyle(fontSize: 10),
            ),
          ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  Widget _browserRow(CaptureBrowser browser) {
    final status = _statuses[browser];
    final connecting = _connecting == browser;
    return Padding(
      key: ValueKey('browser-${browser.name}'),
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            browser.label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          Text(
            !widget.enabled
                ? 'Off'
                : connecting
                ? 'Connecting… Check your browser for permission.'
                : _loading
                ? 'Checking…'
                : status?.label ?? 'Status unavailable',
            key: ValueKey('browser-${browser.name}-status'),
            style: const TextStyle(fontSize: 10),
          ),
          if (widget.enabled && !connecting && !_loading && status != null)
            Text(status.message, style: const TextStyle(fontSize: 10)),
          Row(
            children: [
              TextButton(
                key: ValueKey('setup-browser-${browser.name}'),
                onPressed: () => _showSetup(browser),
                child: const Text('Set up'),
              ),
              TextButton(
                key: ValueKey('reconnect-browser-${browser.name}'),
                onPressed: !widget.enabled || _loading || _connecting != null
                    ? null
                    : () => _reconnect(browser),
                child: Text(
                  status?.state == 'available' ||
                          status?.state == 'setup-required'
                      ? 'Connect'
                      : 'Reconnect',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showSetup(CaptureBrowser browser) async {
    final chrome = browser == CaptureBrowser.chrome;
    final value = chrome
        ? 'chrome://inspect/#remote-debugging'
        : '--remote-debugging-port=0';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Connect ${browser.label}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chrome
                      ? 'Open this address in Chrome and enable remote debugging. Return to Zommi, choose Connect, and allow Chrome’s permission prompt.'
                      : 'Follow Microsoft’s guide to enable remote debugging in Edge. Use the startup option below for an automatically assigned port that Zommi can discover. Edge may need to be fully closed before the option takes effect. Then return to Zommi and choose Connect.',
                ),
                const SizedBox(height: 12),
                SelectableText(value),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: value)),
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(chrome ? 'Copy address' : 'Copy startup option'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Use the browser profile containing the page you want to capture. Each browser is connected separately.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              var opened = false;
              try {
                opened = await launchUrl(
                  Uri.parse(
                    chrome
                        ? 'https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session'
                        : 'https://learn.microsoft.com/en-us/microsoft-edge/devtools/protocol/',
                  ),
                  mode: LaunchMode.externalApplication,
                );
              } catch (_) {
                /* Keep the setup instructions available. */
              }
              if (!opened && context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(
                    content: Text('Could not open the setup guide.'),
                  ),
                );
              }
            },
            child: const Text('Setup guide'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
