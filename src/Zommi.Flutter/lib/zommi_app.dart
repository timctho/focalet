import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/core/core_bridge.dart';

const compactOrbSize = 56.0;
const expandedPanelWidth = 720.0;
const expandedPanelHeight = 620.0;
const bottomAnchorInset = 18.0;
const hoverCollapseDelay = Duration(milliseconds: 500);

class ZommiApp extends StatelessWidget {
  const ZommiApp({required this.core, super.key});

  final CoreBridge core;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Zommi',
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff8178c9),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: ZommiShell(core: core),
    );
  }
}

class ZommiShell extends StatefulWidget {
  const ZommiShell({required this.core, super.key});

  final CoreBridge core;

  @override
  State<ZommiShell> createState() => _ZommiShellState();
}

class _ZommiShellState extends State<ZommiShell> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode(debugLabel: 'Zommi composer');
  final List<_ChatMessage> _messages = [];
  Timer? _collapseTimer;
  bool _expanded = false;
  bool _submitting = false;
  String _status = 'Connecting to Rust core…';
  String? _lastHandoff;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeCore());
  }

  Future<void> _initializeCore() async {
    try {
      final status = await widget.core.initialize();
      if (!mounted) return;
      setState(() => _status = 'Rust core ${status.version} ready');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Rust core unavailable · $error');
    }
  }

  void _expand() {
    _collapseTimer?.cancel();
    if (_expanded) return;
    setState(() => _expanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(hoverCollapseDelay, () {
      if (!mounted) return;
      _composerFocus.unfocus();
      setState(() => _expanded = false);
    });
  }

  Future<void> _submit() async {
    final message = _composer.text.trim();
    if (message.isEmpty || _submitting) return;
    _composer.clear();
    setState(() {
      _messages.add(_ChatMessage(message, isUser: true));
      _submitting = true;
      _status = 'Preparing context handoff…';
    });
    try {
      final handoff = await widget.core.buildContextHandoff(message: message);
      if (!mounted) return;
      setState(() {
        _lastHandoff = handoff;
        _status = 'Context handoff prepared by Rust core';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Core request failed · $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    _composer.dispose();
    _composerFocus.dispose();
    unawaited(widget.core.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffe9edf4),
      body: Stack(
        children: [
          const _PreviewBackdrop(),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: bottomAnchorInset),
              child: MouseRegion(
                onEnter: (_) => _expand(),
                onExit: (_) => _scheduleCollapse(),
                child: AnimatedContainer(
                  key: const ValueKey('zommi-surface'),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: _expanded ? expandedPanelWidth : compactOrbSize,
                  height: _expanded ? expandedPanelHeight : compactOrbSize,
                  child: ClipRect(
                    child: _expanded
                        ? OverflowBox(
                            alignment: Alignment.bottomCenter,
                            minWidth: expandedPanelWidth,
                            maxWidth: expandedPanelWidth,
                            minHeight: expandedPanelHeight,
                            maxHeight: expandedPanelHeight,
                            child: SizedBox(
                              width: expandedPanelWidth,
                              height: expandedPanelHeight,
                              child: _buildPanel(),
                            ),
                          )
                        : const ZommiOrb(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel() {
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
              _PanelHeader(status: _status, busy: _submitting),
              Expanded(child: _buildTranscript()),
              if (_lastHandoff != null)
                Semantics(
                  label: 'Core handoff prepared',
                  child: SizedBox.shrink(),
                ),
              _Composer(
                controller: _composer,
                focusNode: _composerFocus,
                busy: _submitting,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTranscript() {
    if (_messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ZommiOrb(size: 44),
            SizedBox(height: 18),
            Text(
              'Point, ask, keep moving.',
              style: TextStyle(
                color: Color(0xff43495a),
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('zommi-transcript'),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        return Align(
          alignment: message.isUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              color: message.isUser
                  ? const Color(0xffe9e7f8)
                  : const Color(0xb3ffffff),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              message.text,
              style: const TextStyle(color: Color(0xff272b38), fontSize: 15),
            ),
          ),
        );
      },
    );
  }
}

class ZommiOrb extends StatelessWidget {
  const ZommiOrb({this.size = compactOrbSize, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'ZommiOrb',
      button: true,
      child: DecoratedBox(
        key: const ValueKey('zommi-orb'),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            center: Alignment(-0.22, -0.28),
            radius: 0.82,
            colors: [
              Color(0xfff7f6ff),
              Color(0xffb9b8e8),
              Color(0xff7d88c5),
              Color(0xff6e668e),
            ],
            stops: [0, 0.38, 0.72, 1],
          ),
          border: Border.all(color: const Color(0xd9ffffff), width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x404c4b78),
              blurRadius: 18,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Color(0x80ffffff),
              blurRadius: 3,
              offset: Offset(-1, -1),
            ),
          ],
        ),
        child: SizedBox.square(dimension: size),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.status, required this.busy});

  final String status;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(
        children: [
          const ZommiOrb(size: 30),
          const SizedBox(width: 12),
          const Text(
            'Zommi',
            style: TextStyle(
              color: Color(0xff272b38),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: busy ? const Color(0xff8f83ce) : const Color(0xff66a27b),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              status,
              key: const ValueKey('core-status'),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xff6d7280), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(22, 10, 22, 22),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
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
          Expanded(
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.enter): () {
                  unawaited(onSubmit());
                },
              },
              child: TextField(
                key: const ValueKey('zommi-composer'),
                focusNode: focusNode,
                controller: controller,
                minLines: 1,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: 'Ask about what you are pointing at…',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: busy ? 'Preparing context' : 'Send message',
            button: true,
            child: IconButton.filled(
              key: const ValueKey('send-message'),
              onPressed: busy ? null : () => unawaited(onSubmit()),
              icon: Icon(busy ? Icons.more_horiz : Icons.arrow_upward_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBackdrop extends StatelessWidget {
  const _PreviewBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xfff7f8fb), Color(0xffdfe5ee)],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

final class _ChatMessage {
  const _ChatMessage(this.text, {required this.isUser});

  final String text;
  final bool isUser;
}
