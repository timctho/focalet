import 'dart:convert';
import 'dart:io';

import 'package:zommi_flutter/desktop/artifact_loader.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/document_windows.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_models.dart';

/// Opt-in packaged acceptance using a local document selected by the operator.
Future<void> runDocumentPreviewProbe(DesktopBridge desktop) async {
  final output = Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PROBE'];
  final path = Platform.environment['ZOMMI_DOCUMENT_PREVIEW_PATH'];
  if (output == null || path == null) return;
  final report = <String, Object?>{'executable': Platform.resolvedExecutable};
  try {
    await Future<void>.delayed(const Duration(seconds: 2));
    final artifact = await const LocalArtifactLoader().load(
      ArtifactPreview(
        id: 'document-probe',
        kind: artifactKindFromPath(path) ?? 'html',
        title: 'Document preview',
        path: path,
      ),
    );
    final windows = DocumentWindows();
    final view = await windows.open(artifact);
    if (view == null) throw StateError('Document window was closed.');
    await Future<void>.delayed(const Duration(seconds: 3));
    report['document'] = await view.evaluateJavaScript('''(() => {
      const target=document.getElementById(location.hash.slice(1));
      return {hash:location.hash,ready:document.readyState,
        stylesheets:document.styleSheets.length,scripts:document.scripts.length,
        target:target?{display:getComputedStyle(target).display,
          width:target.getBoundingClientRect().width,
          height:target.getBoundingClientRect().height}:null,
        tables:document.querySelectorAll('table').length,
        codeBlocks:document.querySelectorAll('pre code').length,
        copyButtons:document.querySelectorAll('pre button').length,
        viewport:{width:innerWidth,height:innerHeight}};
    })()''');
    report['status'] = 'opened';
    if (Platform.environment['ZOMMI_DOCUMENT_PREVIEW_NOTIFY'] == '1') {
      await desktop.notifyResponseReady(
        runtimeTargetId: 'preview-probe',
        sessionId: 'preview-probe',
        turnId: 'preview-probe',
        runtimeName: 'Document preview',
        sessionTitle: 'Ocean notification check',
      );
    }
  } on Object catch (error) {
    report['status'] = 'failed';
    report['error'] = '$error';
  }
  await File(output)
      .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
}
