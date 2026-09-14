import 'package:flutter/material.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

class MessageQueue extends StatelessWidget {
  const MessageQueue({
    required this.messages,
    required this.paused,
    required this.onRemove,
    this.onResume,
    super.key,
  });

  final List<QueuedMessage> messages;
  final bool paused;
  final ValueChanged<String> onRemove;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 7, 7, 7),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                paused ? Icons.pause_rounded : Icons.schedule_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                '${messages.length} queued',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  paused ? 'Paused' : 'Sends after this response',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (paused)
                TextButton(
                  key: const ValueKey('resume-message-queue'),
                  onPressed: onResume,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 26),
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Resume'),
                )
              else
                const SizedBox(height: 26),
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 108),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final message = messages[index];
                return Padding(
                  key: ValueKey('queued-message-${message.id}'),
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 20,
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Tooltip(
                          message: message.text,
                          child: Text(
                            message.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                      if (message.attachments.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.attach_file_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        Text(
                          '${message.attachments.length}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      IconButton(
                        key: ValueKey('remove-queued-message-${message.id}'),
                        tooltip: 'Remove queued message ${index + 1}',
                        onPressed: () => onRemove(message.id),
                        style: IconButton.styleFrom(
                          minimumSize: const Size(30, 30),
                          maximumSize: const Size(30, 30),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: scheme.onSurfaceVariant,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 14),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
