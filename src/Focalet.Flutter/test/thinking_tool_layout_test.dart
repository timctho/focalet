import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';
import 'package:focalet_flutter/widgets/thinking_flow_background.dart';
import 'package:focalet_flutter/widgets/transcript_view.dart';

import 'test_support.dart';

void main() {
  testWidgets('streaming tool output reaches its new height in one frame', (
    tester,
  ) async {
    final controller = FocaletController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    final tool = TranscriptBlock(
      id: 'tool',
      kind: TranscriptKind.tool,
      title: 'Command',
      text: 'First output',
      expanded: true,
    );
    final turn = ConversationTurn(
      id: 'turn',
      userText: 'Inspect',
      activityExpanded: true,
      blocks: [tool],
    );
    await _pumpGroup(tester, controller, turn);
    final card = find.byKey(const ValueKey('activity-tool'));
    final flow = tester.state(find.byType(ThinkingFlowBackground));
    final originalHeight = tester.getSize(card).height;
    tool.text = 'First output\n\nSecond output\n\nThird output';
    controller.setBlockExpanded(tool, true);
    await tester.pump();
    final updatedHeight = tester.getSize(card).height;
    expect(updatedHeight, greaterThan(originalHeight));
    expect(tester.state(find.byType(ThinkingFlowBackground)), same(flow));
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getSize(card).height,
        updatedHeight,
        reason: 'Output deltas must not keep animating transcript layout.',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed tool output retains its folding animation', (
    tester,
  ) async {
    final controller = FocaletController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    final tool = TranscriptBlock(
      id: 'tool',
      kind: TranscriptKind.tool,
      title: 'Command',
      text: 'First output\n\nSecond output\n\nThird output',
      expanded: true,
    );
    final turn = ConversationTurn(
      id: 'turn',
      userText: 'Inspect',
      activityExpanded: true,
      blocks: [tool],
    );
    await _pumpGroup(tester, controller, turn);
    final card = find.byKey(const ValueKey('activity-tool'));
    final expandedHeight = tester.getSize(card).height;
    tool.lifecycle = TranscriptLifecycle.completed;
    controller.setBlockExpanded(tool, true);
    await tester.pump();
    expect(tester.getSize(card).height, expandedHeight);
    await tester.tap(find.byKey(const ValueKey('tool-toggle-tool')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 65));
    final foldingHeight = tester.getSize(card).height;
    expect(foldingHeight, lessThan(expandedHeight));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(card).height, lessThan(foldingHeight));
    expect(find.text('First output'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool header keeps its height as the title and status update', (
    tester,
  ) async {
    final controller = FocaletController(
      core: RichFakeCore(),
      desktop: FakeDesktopBridge(),
    );
    addTearDown(controller.close);
    final tool = TranscriptBlock(
      id: 'tool',
      kind: TranscriptKind.tool,
      title: 'Tool',
    );
    final turn = ConversationTurn(
      id: 'turn',
      userText: 'Inspect',
      activityExpanded: true,
      blocks: [tool],
    );
    await _pumpGroup(tester, controller, turn);
    final header = find.byKey(const ValueKey('tool-toggle-tool'));
    final originalSize = tester.getSize(header);
    tool.title = 'Read source\nInspect command output\nCheck results';
    controller.setBlockExpanded(tool, false);
    await tester.pump();
    expect(tester.getSize(header), originalSize);
    tool.lifecycle = TranscriptLifecycle.completed;
    controller.setBlockExpanded(tool, false);
    await tester.pump();
    expect(tester.getSize(header), originalSize);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpGroup(
  WidgetTester tester,
  FocaletController controller,
  ConversationTurn turn,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => ThinkingActivityGroup(
              turn: turn,
              activities: turn.blocks,
              width: 340,
              controller: controller,
              isResponding: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
