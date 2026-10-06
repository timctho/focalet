import 'package:flutter/material.dart';

class CommandResult extends StatelessWidget {
  const CommandResult({required this.text, required this.onClose, super.key});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Card(
      margin: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(text),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close command result',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    ),
  );
}
