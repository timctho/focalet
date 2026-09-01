import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/content_views.dart';

class SessionSidebar extends StatelessWidget {
  const SessionSidebar({
    required this.controller,
    required this.onPointerEnter,
    required this.onPointerExit,
    super.key,
  });

  final ZommiController controller;
  final VoidCallback onPointerEnter;
  final VoidCallback onPointerExit;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onPointerEnter(),
      onExit: (_) => onPointerExit(),
      child: Semantics(
        container: true,
        label: 'Chat sessions',
        child: Material(
          key: const ValueKey('session-sidebar'),
          color: const Color(0xf6f6f8fc),
          elevation: 14,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: 250,
            height: 250,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Chats',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (controller.sessionCreationSupported)
                        IconButton(
                          key: const ValueKey('new-session'),
                          tooltip: 'Create new chat',
                          onPressed: controller.sessionBusy
                              ? null
                              : () => unawaited(controller.createSession()),
                          icon: const Icon(Icons.add_rounded),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: controller.sessions.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(18),
                            child: Text(
                              'No provider-owned chats are available.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Color(0xff737887)),
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: const ValueKey('session-list'),
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                          itemCount: controller.sessions.length,
                          itemBuilder: (context, index) {
                            final session = controller.sessions[index];
                            final presence = controller.presenceFor(session.id);
                            final selected =
                                session.id == controller.activeSessionId;
                            return Semantics(
                              selected: selected,
                              label:
                                  '${session.title}, ${presence.name} session',
                              child: ListTile(
                                key: ValueKey('session-${session.id}'),
                                dense: true,
                                visualDensity: const VisualDensity(
                                  vertical: -3,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                selected: selected,
                                selectedTileColor: const Color(0xffebe9f7),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                leading: _SessionStatusIcon(presence: presence),
                                title: Text(
                                  session.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onTap: controller.sessionBusy
                                    ? null
                                    : () => unawaited(
                                        controller.switchSession(session.id),
                                      ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionStatusIcon extends StatelessWidget {
  const _SessionStatusIcon({required this.presence});

  final SessionPresence presence;

  @override
  Widget build(BuildContext context) {
    return switch (presence) {
      SessionPresence.running => const SizedBox.square(
        dimension: 15,
        child: CircularProgressIndicator(strokeWidth: 1.6),
      ),
      SessionPresence.unread => const Icon(
        Icons.circle,
        size: 10,
        color: Color(0xff887cc8),
      ),
      SessionPresence.active => const Icon(
        Icons.visibility_outlined,
        size: 17,
        color: Color(0xff5f8c6a),
      ),
      SessionPresence.done => const Icon(
        Icons.check_circle_outline_rounded,
        size: 16,
        color: Color(0xff8b909d),
      ),
    };
  }
}

class RuntimePanel extends StatelessWidget {
  const RuntimePanel({required this.controller, super.key});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Choose agent runtime',
      child: Material(
        key: const ValueKey('runtime-panel'),
        color: const Color(0xfaf7f9fd),
        elevation: 18,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 420,
          height: 410,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Agent runtime',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('refresh-runtimes'),
                      tooltip: 'Refresh agent runtimes',
                      onPressed: controller.runtimeBusy
                          ? null
                          : () => unawaited(controller.refreshRuntimes()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: controller.runtimeTargets.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'No supported agent found',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              SizedBox(height: 6),
                              Text(
                                'Install and sign in to Codex, Pi, Hermes, OpenClaw, or a compatible CLI, then refresh.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xff737887)),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        key: const ValueKey('runtime-list'),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        itemCount: controller.runtimeTargets.length,
                        itemBuilder: (context, index) {
                          final target = controller.runtimeTargets[index];
                          final selected =
                              target.id == controller.activeRuntime?.id;
                          final host =
                              target.executionHost['displayName']?.toString() ??
                              target.executionHost['name']?.toString() ??
                              'Local';
                          return Semantics(
                            selected: selected,
                            label:
                                '${target.displayName}, ${target.protocolName}, $host, ${target.status}',
                            child: ListTile(
                              key: ValueKey('runtime-${target.id}'),
                              dense: true,
                              visualDensity: const VisualDensity(vertical: -3),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              selected: selected,
                              selectedTileColor: const Color(0xffebe9f7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              leading: _RuntimeStatusDot(status: target.status),
                              title: Text(
                                target.displayName,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              subtitle: Text(
                                '${target.protocolName} · $host',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10),
                              ),
                              trailing: Text(
                                target.adapterId == 'pty-compatibility'
                                    ? 'Compatible'
                                    : _runtimeStatus(target.status),
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Color(0xff747988),
                                ),
                              ),
                              onTap: controller.runtimeBusy
                                  ? null
                                  : () => unawaited(
                                      controller.selectRuntime(target.id),
                                    ),
                            ),
                          );
                        },
                      ),
              ),
              if (controller.activeRuntime?.status == 'sign-in-required')
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonal(
                      key: const ValueKey('runtime-sign-in'),
                      onPressed: () =>
                          unawaited(controller.openRuntimeSignIn()),
                      child: Text(
                        'Open ${controller.activeRuntimeName} sign-in',
                      ),
                    ),
                  ),
                ),
              const Divider(height: 1),
              RuntimeOverrideEditor(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

class RuntimeOverrideEditor extends StatefulWidget {
  const RuntimeOverrideEditor({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<RuntimeOverrideEditor> createState() => _RuntimeOverrideEditorState();
}

class _RuntimeOverrideEditorState extends State<RuntimeOverrideEditor> {
  final TextEditingController _locator = TextEditingController();
  String _adapterId = '';
  String _hostId = '';

  @override
  void dispose() {
    _locator.dispose();
    super.dispose();
  }

  Map<String, Object?>? get _adapter {
    final adapters = widget.controller.runtimeOverrideAdapters;
    if (adapters.isEmpty) return null;
    return adapters.firstWhere(
      (value) => value['adapterId'] == _adapterId,
      orElse: () => adapters.first,
    );
  }

  List<Map<String, Object?>> get _hosts {
    final kinds = (_adapter?['hostKinds'] as List<Object?>? ?? const [])
        .map((value) => value.toString())
        .toSet();
    return widget.controller.runtimeOverrideHosts
        .where((host) => kinds.contains(host['kind']))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.runtimeOverridesSupported) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Text(
          'Runtime overrides are unavailable in this core version.',
          style: TextStyle(fontSize: 11, color: Color(0xff737887)),
        ),
      );
    }
    final adapters = widget.controller.runtimeOverrideAdapters;
    final selectedAdapter = _adapter;
    final adapterId = selectedAdapter?['adapterId']?.toString() ?? '';
    final acceptsEndpoint = selectedAdapter?['acceptsEndpoint'] == true;
    final hosts = _hosts;
    final selectedHost = hosts.any((host) => host['id'] == _hostId)
        ? _hostId
        : (hosts.isEmpty ? '' : hosts.first['id']?.toString() ?? '');
    return ExpansionTile(
      key: const ValueKey('runtime-advanced'),
      dense: true,
      leading: const Icon(Icons.tune_rounded, size: 16),
      title: const Text('Advanced overrides', style: TextStyle(fontSize: 12)),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('runtime-override-adapter'),
          initialValue: adapterId.isEmpty ? null : adapterId,
          isDense: true,
          isExpanded: true,
          style: const TextStyle(fontSize: 11),
          decoration: const InputDecoration(labelText: 'Agent', isDense: true),
          items: [
            for (final adapter in adapters)
              DropdownMenuItem(
                value: adapter['adapterId']?.toString(),
                child: Text(
                  '${adapter['displayName']} · ${adapter['protocolName']}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _adapterId = value ?? '';
            _hostId = '';
          }),
        ),
        if (!acceptsEndpoint)
          DropdownButtonFormField<String>(
            key: const ValueKey('runtime-override-host'),
            initialValue: selectedHost.isEmpty ? null : selectedHost,
            isDense: true,
            isExpanded: true,
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
              labelText: 'Execution host',
              isDense: true,
            ),
            items: [
              for (final host in hosts)
                DropdownMenuItem(
                  value: host['id']?.toString(),
                  child: Text(
                    host['displayName']?.toString() ?? 'Local',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
            onChanged: (value) => setState(() => _hostId = value ?? ''),
          ),
        TextField(
          key: const ValueKey('runtime-override-locator'),
          controller: _locator,
          autocorrect: false,
          enableSuggestions: false,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: acceptsEndpoint ? 'Gateway endpoint' : 'Executable path',
            hintText: acceptsEndpoint
                ? 'ws://127.0.0.1:18789'
                : 'Absolute native or WSL path',
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            key: const ValueKey('save-runtime-override'),
            onPressed:
                widget.controller.runtimeOverrideBusy ||
                    adapterId.isEmpty ||
                    _locator.text.trim().isEmpty ||
                    (!acceptsEndpoint && selectedHost.isEmpty)
                ? null
                : () async {
                    await widget.controller.saveRuntimeOverride(
                      adapterId: adapterId,
                      locator: _locator.text,
                      executionHostId: selectedHost,
                    );
                    if (mounted) _locator.clear();
                  },
            child: const Text('Add override'),
          ),
        ),
        for (final override in widget.controller.runtimeOverrides)
          ListTile(
            key: ValueKey('runtime-override-${override['id']}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${override['adapterId']} · ${override['endpoint'] ?? override['executablePath'] ?? ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: TextButton(
              onPressed: widget.controller.runtimeOverrideBusy
                  ? null
                  : () => unawaited(
                      widget.controller.removeRuntimeOverride(
                        override['id']?.toString() ?? '',
                      ),
                    ),
              child: const Text('Remove'),
            ),
          ),
      ],
    );
  }
}

class _RuntimeStatusDot extends StatelessWidget {
  const _RuntimeStatusDot({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status.toLowerCase()) {
      'ready' || 'detected' => const Color(0xff63a078),
      'sign-in-required' => const Color(0xffd19750),
      'degraded' => const Color(0xffc27a62),
      _ => const Color(0xff9297a4),
    };
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

String _runtimeStatus(String value) => switch (value.toLowerCase()) {
  'sign-in-required' => 'Sign-in required',
  'unreachable' => 'Unavailable',
  'ready' => 'Ready',
  _ => 'Detected',
};

class ModelPanel extends StatefulWidget {
  const ModelPanel({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<ModelPanel> createState() => _ModelPanelState();
}

class _ModelPanelState extends State<ModelPanel> {
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final models = widget.controller.models
        .where((model) {
          if (query.isEmpty) return true;
          final name =
              '${model['displayName'] ?? ''} ${model['model'] ?? model['id'] ?? ''}'
                  .toLowerCase();
          return name.contains(query);
        })
        .toList(growable: false);
    return Material(
      key: const ValueKey('model-panel'),
      color: const Color(0xfaf7f9fd),
      elevation: 18,
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        width: 390,
        height: 380,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                key: const ValueKey('model-search'),
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 11.5),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded, size: 17),
                  prefixIconConstraints: BoxConstraints(minWidth: 34),
                  hintText: 'Search models',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Expanded(
              child: models.isEmpty
                  ? const Center(child: Text('No matching models'))
                  : ListView.builder(
                      key: const ValueKey('model-list'),
                      itemCount: models.length,
                      itemBuilder: (context, index) {
                        final model = models[index];
                        final id =
                            model['model']?.toString() ??
                            model['id']?.toString() ??
                            '';
                        final selected = id == widget.controller.selectedModel;
                        return RadioGroup<String>(
                          groupValue: widget.controller.selectedModel,
                          onChanged: (value) {
                            if (value != null) {
                              widget.controller.setModel(value);
                              setState(() {});
                            }
                          },
                          child: RadioListTile<String>(
                            key: ValueKey('model-$id'),
                            value: id,
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -3),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            title: Text(
                              model['displayName']?.toString() ?? id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            subtitle: model['description'] == null
                                ? null
                                : Text(
                                    model['description'].toString(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 10),
                                  ),
                            selected: selected,
                          ),
                        );
                      },
                    ),
            ),
            if (widget.controller.selectedModelEfforts.isNotEmpty) ...[
              const Divider(height: 1),
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Text(
                    'Reasoning',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    key: const ValueKey('reasoning-options-row'),
                    children: [
                      for (
                        var index = 0;
                        index < widget.controller.selectedModelEfforts.length;
                        index++
                      ) ...[
                        if (index > 0) const SizedBox(width: 5),
                        ChoiceChip(
                          key: ValueKey(
                            'effort-${widget.controller.selectedModelEfforts[index]}',
                          ),
                          label: Text(
                            widget.controller.selectedModelEfforts[index],
                          ),
                          labelStyle: const TextStyle(fontSize: 10),
                          visualDensity: const VisualDensity(
                            horizontal: -3,
                            vertical: -3,
                          ),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          selected:
                              widget.controller.selectedModelEfforts[index] ==
                              widget.controller.selectedEffort,
                          onSelected: (_) {
                            widget.controller.setEffort(
                              widget.controller.selectedModelEfforts[index],
                            );
                            setState(() {});
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ContextPreviewPanel extends StatelessWidget {
  const ContextPreviewPanel({
    required this.attachment,
    required this.onClose,
    required this.onPointerEnter,
    required this.onPointerExit,
    super.key,
  });

  final ContextAttachment attachment;
  final VoidCallback onClose;
  final VoidCallback onPointerEnter;
  final VoidCallback onPointerExit;

  @override
  Widget build(BuildContext context) {
    final image = attachment.imageDataUrl == null
        ? null
        : decodeImageDataUrl(attachment.imageDataUrl!);
    return MouseRegion(
      onEnter: (_) => onPointerEnter(),
      onExit: (_) => onPointerExit(),
      child: Material(
        key: const ValueKey('context-preview'),
        color: const Color(0xfaf7f9fd),
        elevation: 18,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 380,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 430),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 7, 7),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          attachment.token,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close context preview',
                        onPressed: onClose,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                if (image != null)
                  SizedBox(
                    key: const ValueKey('context-preview-image-frame'),
                    width: double.infinity,
                    height: 220,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Image.memory(
                        image,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        semanticLabel: 'Attached visual context preview',
                      ),
                    ),
                  ),
                if (attachment.previewText.isNotEmpty)
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                      child: SelectableText(
                        attachment.previewText,
                        key: const ValueKey('context-preview-text'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ApprovalDialogCard extends StatelessWidget {
  const ApprovalDialogCard({required this.controller, super.key});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final request = controller.approval!;
    return _ModalCard(
      semanticLabel: 'Agent requests permission',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            request.title,
            key: const ValueKey('approval-title'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          if (request.detail.isNotEmpty) ...[
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: SingleChildScrollView(
                child: SelectableText(
                  request.detail,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in request.options)
                FilledButton.tonal(
                  key: ValueKey('approval-${option.id}'),
                  autofocus: identical(option, request.options.first),
                  onPressed: controller.resolvingPrompt
                      ? null
                      : () => unawaited(controller.resolveApproval(option.id)),
                  style: option.isReject
                      ? FilledButton.styleFrom(
                          foregroundColor: const Color(0xff9b4050),
                        )
                      : null,
                  child: Text(option.label),
                ),
              if (!request.options.any((option) => option.isReject))
                TextButton(
                  key: const ValueKey('approval-deny'),
                  onPressed: controller.resolvingPrompt
                      ? null
                      : () => unawaited(controller.resolveApproval(null)),
                  child: const Text('Deny'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class QuestionDialogCard extends StatefulWidget {
  const QuestionDialogCard({required this.controller, super.key});

  final ZommiController controller;

  @override
  State<QuestionDialogCard> createState() => _QuestionDialogCardState();
}

class _QuestionDialogCardState extends State<QuestionDialogCard> {
  final TextEditingController _input = TextEditingController();
  final Map<String, Set<String>> _answers = {};
  final Map<String, TextEditingController> _other = {};

  PendingQuestion get request => widget.controller.question!;

  @override
  void initState() {
    super.initState();
    _input.text = request.sensitive ? '' : request.prefill;
    for (final question in request.questions) {
      _answers[question.id] = {};
      _other[question.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _input.dispose();
    for (final controller in _other.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            unawaited(_submit()),
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
            unawaited(_submit()),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(widget.controller.resolveQuestion({})),
      },
      child: _ModalCard(
        semanticLabel: 'Agent asks a question',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              request.title,
              key: const ValueKey('question-title'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (request.message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(request.message),
            ],
            const SizedBox(height: 12),
            if (request.questions.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 390),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final question in request.questions.take(3))
                        _structuredQuestion(question),
                    ],
                  ),
                ),
              )
            else if (request.method == 'confirm')
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    key: const ValueKey('question-yes'),
                    onPressed: () => unawaited(
                      widget.controller.resolveQuestion({'confirmed': true}),
                    ),
                    child: const Text('Yes'),
                  ),
                  FilledButton.tonal(
                    key: const ValueKey('question-no'),
                    onPressed: () => unawaited(
                      widget.controller.resolveQuestion({'confirmed': false}),
                    ),
                    child: const Text('No'),
                  ),
                ],
              )
            else if (request.method == 'select')
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in request.options)
                    FilledButton.tonal(
                      key: ValueKey('question-option-${option.value}'),
                      onPressed: () => unawaited(
                        widget.controller.resolveQuestion({
                          'value': option.value,
                        }),
                      ),
                      child: Text(option.label),
                    ),
                ],
              )
            else
              TextField(
                key: const ValueKey('question-input'),
                controller: _input,
                autofocus: true,
                obscureText: request.sensitive,
                minLines: request.sensitive ? 1 : 2,
                maxLines: request.sensitive ? 1 : 4,
                decoration: InputDecoration(
                  hintText: request.placeholder,
                  border: const OutlineInputBorder(),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('question-cancel'),
                  onPressed: widget.controller.resolvingPrompt
                      ? null
                      : () => unawaited(widget.controller.resolveQuestion({})),
                  child: const Text('Cancel'),
                ),
                if (request.questions.isNotEmpty ||
                    !{'confirm', 'select'}.contains(request.method)) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('question-submit'),
                    onPressed: widget.controller.resolvingPrompt
                        ? null
                        : () => unawaited(_submit()),
                    child: const Text('Submit'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _structuredQuestion(StructuredQuestion question) {
    final selected = _answers[question.id]!;
    return Container(
      key: ValueKey('structured-question-${question.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffe1e4ec)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            question.header,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (question.question.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(question.question),
          ],
          const SizedBox(height: 6),
          for (final option in question.options.take(4))
            if (question.multiSelect)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: selected.contains(option.value),
                title: Text(option.label),
                subtitle: option.detail == null ? null : Text(option.detail!),
                onChanged: (checked) => setState(() {
                  checked == true
                      ? selected.add(option.value)
                      : selected.remove(option.value);
                }),
              )
            else
              RadioGroup<String>(
                groupValue: selected.firstOrNull,
                onChanged: (value) => setState(() {
                  selected
                    ..clear()
                    ..addAll(value == null ? const [] : [value]);
                }),
                child: RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: option.value,
                  title: Text(option.label),
                  subtitle: option.detail == null ? null : Text(option.detail!),
                ),
              ),
          if (question.allowOther || question.options.isEmpty)
            TextField(
              controller: _other[question.id],
              obscureText: question.secret,
              decoration: InputDecoration(
                hintText: question.options.isEmpty
                    ? 'Your answer'
                    : 'Other answer',
                isDense: true,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _submit() {
    if (request.questions.isEmpty) {
      return widget.controller.resolveQuestion({'value': _input.text});
    }
    final result = <String, List<String>>{};
    for (final question in request.questions) {
      final values = List<String>.of(_answers[question.id] ?? const {});
      final other = _other[question.id]?.text.trim() ?? '';
      if (other.isNotEmpty) values.add(other);
      result[question.id] = values;
    }
    return widget.controller.resolveQuestion({'answers': result});
  }
}

class ArtifactViewerDialog extends StatelessWidget {
  const ArtifactViewerDialog({required this.controller, super.key});

  final ZommiController controller;

  @override
  Widget build(BuildContext context) {
    final artifact = controller.previewArtifact!;
    return Positioned.fill(
      top: 64,
      left: 24,
      right: 24,
      bottom: 24,
      child: Material(
        key: const ValueKey('artifact-viewer'),
        color: const Color(0xfff8f9fc),
        elevation: 22,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 9, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      artifact.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    autofocus: true,
                    tooltip: 'Close artifact preview',
                    onPressed: controller.closeArtifact,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(18),
                child: ArtifactSurface(artifact: artifact),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModalCard extends StatelessWidget {
  const _ModalCard({required this.semanticLabel, required this.child});

  final String semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Material(
        color: const Color(0xfffbfbfd),
        elevation: 24,
        borderRadius: BorderRadius.circular(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 540),
          child: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    );
  }
}
