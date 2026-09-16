import 'package:flutter/material.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

class SessionContextMenu extends StatelessWidget {
  const SessionContextMenu({
    required this.controller,
    required this.session,
    required this.child,
    super.key,
  });
  final ZommiController controller;
  final SessionSummary session;
  final Widget child;

  Future<void> _show(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    PopupMenuItem<String> item(
      String action,
      String label,
      IconData icon, {
      bool enabled = true,
    }) => PopupMenuItem(
      key: ValueKey('session-action-$action'),
      value: action,
      enabled: enabled,
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
    final action = await showMenu<String>(
      context: context,
      menuPadding: const EdgeInsets.symmetric(vertical: 5),
      position: RelativeRect.fromSize(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        overlay.size,
      ),
      items: [
        item('pin', session.pinned ? 'Unpin' : 'Pin', Icons.push_pin_outlined),
        item('rename', 'Rename', Icons.edit_outlined),
        item(
          'copy',
          'Copy',
          Icons.copy_outlined,
          enabled: !controller.sessionActionBusy,
        ),
        item(
          'duplicate',
          'Duplicate',
          Icons.fork_right_rounded,
          enabled: controller.canForkSession(session),
        ),
        const PopupMenuDivider(height: 9),
        item(
          'delete',
          'Delete',
          Icons.delete_outline,
          enabled: !controller.sessionActionBusy,
        ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case 'pin':
        controller.setSessionPinned(session, !session.pinned);
      case 'rename':
        final title = await showDialog<String>(
          context: context,
          builder: (_) => _RenameDialog(title: session.title),
        );
        if (title != null) controller.renameSession(session, title);
      case 'copy':
        await controller.copySession(session);
      case 'duplicate':
        await controller.duplicateSession(session);
      case 'delete':
        controller.deleteSessionMetadata(session);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onSecondaryTapUp: (details) => _show(context, details.globalPosition),
    onLongPressStart: (details) => _show(context, details.globalPosition),
    child: child,
  );
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title});
  final String title;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _text = TextEditingController(text: widget.title)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.title.length,
    );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    if (_text.text.trim().isNotEmpty) Navigator.pop(context, _text.text.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename chat'),
    content: SizedBox(
      width: 320,
      child: TextField(
        key: const ValueKey('session-rename-input'),
        controller: _text,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(labelText: 'Name'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _text.text.trim().isEmpty ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}
