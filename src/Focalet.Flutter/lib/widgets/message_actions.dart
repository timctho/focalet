import 'dart:async';

import 'package:flutter/material.dart';

/// Message actions live below the content, including image-only messages.
class MessageActions extends StatefulWidget {
  const MessageActions({
    required this.text,
    required this.onCopy,
    this.timestamp,
    this.showTimestamp = true,
    this.isUser = false,
    this.onEdit,
    super.key,
  });

  final String text;
  final Future<void> Function(String) onCopy;
  final DateTime? timestamp;
  final bool showTimestamp;
  final bool isUser;
  final VoidCallback? onEdit;

  @override
  State<MessageActions> createState() => _MessageActionsState();
}

class _MessageActionsState extends State<MessageActions> {
  Timer? _feedbackTimer;
  bool _copied = false;

  @override
  void dispose() {
    _feedbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = widget.timestamp?.toLocal();
    final time = local == null
        ? '—'
        : '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final timestamp = Tooltip(
      message: local == null
          ? 'Timestamp unavailable for this message'
          : '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $time',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Text(
          time,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.isUser && widget.showTimestamp) timestamp,
          IconButton(
            key: ValueKey('copy-${widget.text.hashCode}'),
            tooltip: _copied
                ? 'Copied'
                : widget.isUser
                ? 'Copy message'
                : 'Copy response',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(
              foregroundColor: scheme.onSurfaceVariant,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: widget.text.isEmpty
                ? null
                : () async {
                    await widget.onCopy(widget.text);
                    if (!mounted) return;
                    _feedbackTimer?.cancel();
                    setState(() => _copied = true);
                    _feedbackTimer = Timer(const Duration(seconds: 1), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
            icon: Icon(
              _copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 14,
            ),
          ),
          if (widget.isUser)
            IconButton(
              tooltip: 'Edit and resend',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              style: IconButton.styleFrom(
                foregroundColor: scheme.onSurfaceVariant,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_outlined, size: 15),
            ),
          if (!widget.isUser && widget.showTimestamp) timestamp,
        ],
      ),
    );
  }
}
