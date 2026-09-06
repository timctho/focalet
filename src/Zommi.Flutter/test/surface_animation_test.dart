import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/desktop/surface_animation.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets(
    'real chat retains its editor and unscaled controls on the canvas',
    (tester) async {
      await tester.binding.setSurfaceSize(largeWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final desktop = FakeDesktopBridge();
      await tester.pumpWidget(
        ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
      );
      await tester.pumpAndSettle();
      final editor = find.byType(EditableText);
      await tester.enterText(editor, 'Draft survives resizing');
      final state = tester.state(editor);
      final send = find.byKey(const ValueKey('send-message'));
      final originalCenter = tester.getCenter(send);
      final originalSize = tester.getSize(send);
      desktop.surfaceAnimation.value = const Rect.fromLTWH(100, 140, 720, 620);
      await tester.pump();
      expect(tester.state(editor), same(state));
      expect(
        tester.widget<EditableText>(editor).controller.text,
        'Draft survives resizing',
      );
      expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
      expect(tester.getSize(send), originalSize);
      expect(tester.getCenter(send), originalCenter - const Offset(100, 0));
      desktop.surfaceAnimation.value = null;
      await tester.pump();
      expect(tester.state(editor), same(state));
      expect(tester.getCenter(send), originalCenter);
    },
  );

  testWidgets(
    'canvas resize keeps content and visual edges in the same frame',
    (tester) async {
      final animation = SurfaceAnimationController();
      addTearDown(animation.dispose);
      const standard = Rect.fromLTWH(300, 240, 720, 620);
      const wide = Rect.fromLTWH(200, 100, 920, 760);
      const maximized = Rect.fromLTWH(0, 0, 1400, 1000);
      final nativeResizes = <Rect>[];
      final freezes = <bool>[];
      for (final endpoints in [
        (standard, wide),
        (wide, standard),
        (standard, maximized),
        (maximized, wide),
      ]) {
        nativeResizes.clear();
        freezes.clear();
        var viewport = endpoints.$1.size;
        Future<void> render() => tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: viewport,
                child: SurfaceAnimationHost(
                  animation: animation,
                  builder: (context, size) => const ColoredBox(
                    key: ValueKey('visual-panel'),
                    color: Color(0xffeeeeee),
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: SizedBox(
                        key: ValueKey('content-anchor'),
                        width: 40,
                        height: 40,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await render();
        var complete = false;
        final operation = animation
            .animate(
              from: endpoints.$1,
              to: endpoints.$2,
              maximized: endpoints.$2 == maximized,
              duration: surfaceTransitionDuration,
              ease: symmetricSurfaceEase,
              freeze: (remember) async => freezes.add(remember),
              resize: (bounds, maximized) async {
                nativeResizes.add(bounds);
                viewport = bounds.size;
              },
            )
            .then((_) => complete = true);
        final visualFrames = <Rect>[];
        for (var frame = 0; frame < 30 && !complete; frame++) {
          await render();
          await tester.pump(const Duration(milliseconds: 16));
          if (complete) break;
          final panel = tester.getRect(
            find.byKey(const ValueKey('visual-panel')),
          );
          final content = tester.getRect(
            find.byKey(const ValueKey('content-anchor')),
          );
          expect(content.bottomRight, panel.bottomRight);
          expect(content.size, const Size(40, 40));
          visualFrames.add(panel);
          expect(nativeResizes.length, lessThanOrEqualTo(2));
        }
        await operation;
        await render();
        expect(
          tester.getSize(find.byKey(const ValueKey('visual-panel'))),
          endpoints.$2.size,
        );
        expect(visualFrames.toSet().length, greaterThan(10));
        expect(nativeResizes, [
          endpoints.$1.expandToInclude(endpoints.$2),
          endpoints.$2,
        ]);
        expect(freezes, [true, false]);
        expect(animation.value, isNull);
      }
    },
  );
}
