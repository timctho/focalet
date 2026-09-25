import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:window_manager/window_manager.dart';
import 'package:zommi_flutter/desktop/capture_permissions.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/region_selection.dart';

/// Opt-in packaged acceptance. Only interactive mode opens the capture editor.
/// A permission-limited result is deliberately distinct from capture success.
Future<void> runMacCaptureProbe() async {
  final path = Platform.environment['ZOMMI_MACOS_CAPTURE_PROBE']?.trim();
  if (!Platform.isMacOS || path == null || path.isEmpty) return;
  stdout.writeln('macOS probe: process $pid');
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
      if (status.accessibility && status.screenRecording) {
        try {
          report['context'] = await _probeRegion();
        } on Object catch (error) {
          report['context'] = {'status': 'failed', 'error': '$error'};
        }
      }
      stdout.writeln('macOS probe: capturing pixels');
      report['pixels'] = {'status': 'permission-required'};
      if (status.screenRecording) {
        final backend = NativeUnixRegionBackend();
        try {
          final displays = await backend.captureDisplays();
          try {
            if (displays.isEmpty) {
              throw StateError('No display pixels were returned.');
            }
            report['pixels'] = {
              'status': 'captured',
              'width': displays.first.image.width,
              'height': displays.first.image.height,
              'displayCount': displays.length,
            };
          } finally {
            for (final display in displays) {
              display.image.dispose();
            }
          }
        } on Object catch (error) {
          report['pixels'] = {'status': 'failed', 'error': '$error'};
        } finally {
          await backend.close();
        }
      }
      if (Platform.environment['ZOMMI_MACOS_INTERACTIVE_PROBE'] == '1' &&
          status.screenRecording) {
        final provider = UnixCaptureProvider();
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
        final mapping = image.alignment?['mapping'] as Map?;
        final expected = mapping?['imageBounds'] as Map?;
        final sizeMatches =
            expected?['width'] == frame.image.width &&
            expected?['height'] == frame.image.height &&
            frame.image.width > 0 &&
            frame.image.height > 0;
        report['interactiveRegionSelection'] = {
          ...(report['interactiveRegionSelection']! as Map<String, Object?>),
          'bounds': image.bounds,
          'alignment': image.alignment,
          'annotations': image.snapshot?['imageAnnotations'],
        };
        frame.image.dispose();
        codec.dispose();
        if (!sizeMatches) {
          throw StateError(
            'The selected PNG does not match its region mapping.',
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
        await provider.close();
      }
      final context = report['context']! as Map;
      final pixels = report['pixels']! as Map;
      report['captureVerified'] =
          context['status'] == 'captured' &&
          context['expectedTextFound'] == true &&
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

/// Exercise the production region enrichment on a known fixture, without
/// injecting mouse input or equating a screenshot/window title with AX success.
Future<Map<String, Object?>> _probeRegion() async {
  final title =
      Platform.environment['ZOMMI_MACOS_PROBE_WINDOW_TITLE'] ??
      'zommi-capture-fixture';
  final expectedText =
      Platform.environment['ZOMMI_MACOS_PROBE_EXPECTED_TEXT'] ??
      'Zommi macOS capture acceptance fixture';
  final requireDom = Platform.environment['ZOMMI_MACOS_PROBE_DOM'] == '1';
  final observations = <Map<String, Object?>>[];
  final backend = NativeUnixRegionBackend();
  final browser = ProcessNativeCaptureClient(
    '${File(Platform.resolvedExecutable).parent.path}/browser-capture/zommi-browser-capture',
  );
  final displays = await backend.captureDisplays();
  try {
    for (final display in displays) {
      final matches = display.windows
          .where(
            (window) =>
                (window['windowTitle']?.toString() ?? '').contains(title),
          )
          .toList();
      if (matches.length != 1) continue;
      final window = regionRect(matches.single['bounds']);
      // Stay inside the document, away from title bars, scroll bars and the
      // insertion caret at the left edge. AX still reports the intersected text.
      var bounds = ui.Rect.fromLTWH(
        window.left + 80,
        window.top + 100,
        (window.width - 160).clamp(4, 600),
        (window.height - 180).clamp(4, 300),
      ).intersect(display.bounds);
      if (Platform.environment['ZOMMI_MACOS_PROBE_BOUNDS']
          case final specified?) {
        bounds = regionRect(jsonDecode(specified)).intersect(display.bounds);
      }
      if (bounds.isEmpty) {
        throw StateError('Fixture region is outside the display.');
      }
      final scaleX = display.image.width / display.bounds.width;
      final scaleY = display.image.height / display.bounds.height;
      final pixels = ui.Rect.fromLTRB(
        ((bounds.left - display.bounds.left) * scaleX).roundToDouble(),
        ((bounds.top - display.bounds.top) * scaleY).roundToDouble(),
        ((bounds.right - display.bounds.left) * scaleX).roundToDouble(),
        ((bounds.bottom - display.bounds.top) * scaleY).roundToDouble(),
      );
      final selected = SelectedRegion(display, pixels);
      final image = await enrichSelectedRegion(selected, (region) async {
        final value = await backend.observe(region);
        observations.add({
          for (final key in [
            'stable',
            'source',
            'limitation',
            'browserViewport',
            'regionContext',
          ])
            if (value.containsKey(key)) key: value[key],
          'pixelsMatch':
              value['dataUrl'] is String &&
              await sameCapturedPixels(
                'data:image/png;base64,${base64Encode(await selected.render(annotated: false))}',
                value['dataUrl'] as String,
              ),
        });
        return value;
      }, browser: browser);
      final snapshot = image.snapshot;
      final elements =
          (snapshot?['regionContext'] as Map?)?['elements'] as List? ?? [];
      final found = elements.any(
        (element) =>
            element is Map &&
            ['text', 'value', 'name', 'description'].any(
              (key) => (element[key]?.toString() ?? '').contains(expectedText),
            ),
      );
      final dom = snapshot?['dom'] is Map;
      return {
        'status': found && (!requireDom || dom) ? 'captured' : 'failed',
        'expectedTextFound': found,
        'domCaptured': dom,
        'elementCount': elements.length,
        'application': snapshot?['application'],
        'windowTitle': snapshot?['windowTitle'],
        'bounds': image.bounds,
        'alignment': image.alignment,
        'snapshot': snapshot,
        'observations': observations,
      };
    }
    throw StateError('No unique visible fixture window matched "$title".');
  } finally {
    for (final display in displays) {
      display.image.dispose();
    }
    await browser.close();
    await backend.close();
  }
}
