import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/desktop/desktop_bridge.dart';
import 'package:zommi_flutter/zommi_app.dart';

import 'test_support.dart';

void main() {
  testWidgets('maximize applies on release and cancellation stays inert', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(normalWindowSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final desktop = FakeDesktopBridge();
    await tester.pumpWidget(
      ZommiApp(core: RichFakeCore()..historyCount = 0, desktop: desktop),
    );
    await tester.pumpAndSettle();
    final choice = find.byTooltip('Maximize Zommi');
    final gesture = await tester.startGesture(tester.getCenter(choice));
    await tester.pump();
    expect(desktop.calls.where((call) => call == 'toggleMaximized'), isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(desktop.calls.where((call) => call == 'toggleMaximized'), isEmpty);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(
      desktop.calls.where((call) => call == 'toggleMaximized'),
      hasLength(1),
    );
  });

  testWidgets(
    'real window metrics resize the panel without scaling its editor',
    (tester) async {
      await tester.binding.setSurfaceSize(normalWindowSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ZommiApp(
          core: RichFakeCore()..historyCount = 0,
          desktop: FakeDesktopBridge(),
        ),
      );
      await tester.pumpAndSettle();
      final editor = find.byType(EditableText).first;
      await tester.enterText(editor, 'keep this draft');
      final editorState = tester.state<EditableTextState>(editor);
      final beforeFont = tester.widget<EditableText>(editor).style.fontSize;
      for (final size in [
        largeWindowSize,
        normalWindowSize,
        const Size(1600, 1000),
        largeWindowSize,
        const Size(1600, 1000),
        normalWindowSize,
      ]) {
        await tester.binding.setSurfaceSize(size);
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const ValueKey('zommi-surface'))),
          size,
        );
        expect(tester.state<EditableTextState>(editor), same(editorState));
        expect(
          tester.widget<EditableText>(editor).controller.text,
          'keep this draft',
        );
        expect(tester.widget<EditableText>(editor).style.fontSize, beforeFont);
        expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
