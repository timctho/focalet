import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:screen_capturer/screen_capturer.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';

/// Opt-in packaged acceptance. Never requests permissions or opens a selector.
/// A permission-limited result is deliberately distinct from capture success.
Future<void> runMacCaptureProbe() async {
  final path = Platform.environment['ZOMMI_MACOS_CAPTURE_PROBE']?.trim();
  if (!Platform.isMacOS || path == null || path.isEmpty) return;
  stdout.writeln('macOS probe: entered');
  final report = <String, Object?>{
    'executable': Platform.resolvedExecutable,
    'processId': pid,
    'timestamp': DateTime.now().toUtc().toIso8601String(),
    'captureVerified': false,
    'interactiveRegionSelection': 'not-tested',
  };
  final output = File(path);
  try {
    await Future<void>.delayed(const Duration(seconds: 3));
    stdout.writeln('macOS probe: checking permissions');
    final status = await MacCapturePermissions().capturePermissions();
    report['permissions'] = {
      'accessibility': status.accessibility,
      'screenRecording': status.screenRecording,
    };
    stdout.writeln('macOS probe: reading window');
    final bounds = await windowManager.getBounds();
    report['window'] = {'width': bounds.width, 'height': bounds.height};
    stdout.writeln('macOS probe: hiding window');
    await hideDesktopForCapture();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      stdout.writeln('macOS probe: reading external context');
      report['context'] = {'status': 'permission-required'};
      if (status.accessibility) {
        try {
          final context = await PortableCaptureProvider().capture();
          final snapshot = context.snapshot;
          report['context'] = {
            'status': snapshot == null ? 'failed' : 'captured',
            'application': snapshot?['application'],
            'windowTitle': snapshot?['windowTitle'],
          };
        } on Object catch (error) {
          report['context'] = {'status': 'failed', 'error': '$error'};
        }
      }
      stdout.writeln('macOS probe: capturing pixels');
      report['pixels'] = {'status': 'permission-required'};
      if (status.screenRecording) {
        final imageFile = File('${output.path}.png');
        try {
          final capture = await screenCapturer.capture(
            mode: CaptureMode.screen,
            imagePath: imageFile.path,
            copyToClipboard: false,
            silent: true,
          );
          final bytes = capture?.imageBytes;
          if (bytes == null || bytes.isEmpty) {
            throw StateError('The native capture plugin returned no pixels.');
          }
          final codec = await ui.instantiateImageCodec(bytes);
          try {
            final frame = await codec.getNextFrame();
            report['pixels'] = {
              'status': 'captured',
              'width': frame.image.width,
              'height': frame.image.height,
              'bytes': bytes.length,
            };
            frame.image.dispose();
          } finally {
            codec.dispose();
          }
        } on Object catch (error) {
          report['pixels'] = {'status': 'failed', 'error': '$error'};
        } finally {
          if (await imageFile.exists()) await imageFile.delete();
        }
      }
      if (Platform.environment['ZOMMI_MACOS_INTERACTIVE_PROBE'] == '1' &&
          status.screenRecording) {
        final provider = PortableCaptureProvider();
        stdout.writeln('macOS probe: select region');
        final selected = await provider.selectContext().timeout(
          const Duration(seconds: 25),
        );
        if (selected.length != 1 || selected.single.image == null) {
          throw StateError('The interactive selector returned no image.');
        }
        final image = selected.single.image!;
        final bytes = base64Decode(image.dataUrl.split(',').last);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final scale =
            ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
        report['interactiveRegionSelection'] = {
          'width': frame.image.width,
          'height': frame.image.height,
          'scale': scale,
          'application': image.snapshot?['application'],
          'windowTitle': image.snapshot?['windowTitle'],
        };
        // The macOS selector may include the final edge pixel of the drag.
        final expectedWidth = (120 * scale).round();
        final expectedHeight = (80 * scale).round();
        final sizeMatches =
            frame.image.width >= expectedWidth &&
            frame.image.width <= expectedWidth + 1 &&
            frame.image.height >= expectedHeight &&
            frame.image.height <= expectedHeight + 1;
        frame.image.dispose();
        codec.dispose();
        if (!sizeMatches) {
          throw StateError(
            'The selected PNG does not match the dragged rectangle.',
          );
        }
        stdout.writeln('macOS probe: cancel region');
        final cancelled = await provider.selectContext().timeout(
          const Duration(seconds: 25),
        );
        if (cancelled.isNotEmpty) {
          throw StateError('Cancellation produced an attachment.');
        }
        report['interactiveRegionCancellation'] = 'passed';
      }
      final context = report['context']! as Map;
      final pixels = report['pixels']! as Map;
      report['captureVerified'] =
          context['status'] == 'captured' &&
          context['application'] == 'TextEdit' &&
          (context['windowTitle'] as String? ?? '').contains(
            'zommi-capture-fixture',
          ) &&
          pixels['status'] == 'captured';
      report['status'] = 'completed';
    } finally {
      await windowManager.show();
    }
  } on Object catch (error) {
    report['status'] = 'failed';
    report['error'] = '$error';
  }
  await output.parent.create(recursive: true);
  final temporary = File('${output.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  await temporary.rename(output.path);
}
