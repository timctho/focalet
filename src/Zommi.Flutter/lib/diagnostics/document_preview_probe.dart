import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/state/zommi_controller.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

ZommiController? _probeController;

/// Opt-in acceptance through the real floating preview panel.
void scheduleDocumentPreviewProbe(ZommiController controller) {
  final path = Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PATH'];
  if (path == null ||
      Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PROBE'] == null) {
    return;
  }
  _probeController = controller;
  // Startup restores the selected chat and dismisses its previous overlays.
  // The caller waits for that restore before opening the acceptance document.
  unawaited(controller.openExternalLink(path));
}

Future<void> recordDocumentPreview(
  ArtifactPreview artifact,
  Future<Object?> Function(String) evaluate,
) async {
  if (artifact.path != Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PATH']) {
    return;
  }
  final output = Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PROBE'];
  if (output == null) return;
  try {
    final document = await evaluate('''(() => {
      const target=document.getElementById(decodeURIComponent(location.hash.slice(1)));
      return {hash:location.hash,ready:document.readyState,
        stylesheets:document.styleSheets.length,scripts:document.scripts.length,
        target:target?{display:getComputedStyle(target).display,
          width:target.getBoundingClientRect().width,height:target.getBoundingClientRect().height}:null,
        tables:document.querySelectorAll('table').length,
        codeBlocks:document.querySelectorAll('pre code').length,
        copyButtons:document.querySelectorAll('pre button').length,
        viewport:{width:innerWidth,height:innerHeight}};
    })()''');
    await File(output).writeAsString(
      jsonEncode({
        'status': 'opened',
        'executable': Platform.resolvedExecutable,
        'renderer': 'floating-panel',
        'document': document is String ? jsonDecode(document) : document,
      }),
    );
    if (Platform.environment['ZOMMI_DOCUMENT_PREVIEW_NOTIFY'] == '1') {
      await Future<void>.delayed(const Duration(seconds: 4));
      final desktop = _probeController?.desktop;
      await desktop?.closeWindow();
      await desktop?.notifyResponseReady(
        runtimeTargetId: 'preview-probe',
        sessionId: 'preview-probe',
        turnId: 'preview-probe',
        runtimeName: 'Document preview',
        sessionTitle: 'Ocean notification check',
      );
    }
  } on Object catch (error) {
    await recordDocumentPreviewFailure(artifact, '$error');
  }
}

Future<void> recordDocumentPreviewFailure(
  ArtifactPreview artifact,
  String error,
) async {
  final output = Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PROBE'];
  if (output == null ||
      artifact.path != Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PATH']) {
    return;
  }
  await File(output)
      .writeAsString(jsonEncode({'status': 'failed', 'error': error}));
}
