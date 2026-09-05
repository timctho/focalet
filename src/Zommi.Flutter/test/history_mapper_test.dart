import 'package:flutter_test/flutter_test.dart';
import 'package:zommi_flutter/state/history_mapper.dart';
import 'package:zommi_flutter/state/zommi_models.dart';
import 'package:zommi_flutter/widgets/content_views.dart';

void main() {
  test(
    'canonical history maps user, reasoning, tools, markdown, and artifacts',
    () {
      final turns = mapThreadHistory({
        'thread': {
          'id': 'thread-1',
          'cwd': '/workspace',
          'turns': [
            {
              'id': 'turn-1',
              'items': [
                {
                  'type': 'userMessage',
                  'content': [
                    {
                      'type': 'text',
                      'text': '<user_message>compare this</user_message>\nprivate context',
                    },
                  ],
                },
                {
                  'id': 'reason-1',
                  'type': 'reasoning',
                  'summary': ['Inspecting', 'Inspecting the selected table'],
                  'content': ['Inspecting the selected table'],
                  'status': 'completed',
                },
                {
                  'id': 'command-1',
                  'type': 'commandExecution',
                  'command': 'rg table',
                  'aggregatedOutput': 'match',
                  'status': 'completed',
                },
                {
                  'id': 'answer-1',
                  'type': 'agentMessage',
                  'text': 'Done. [Preview](report.html)',
                  'status': 'completed',
                },
              ],
            },
          ],
        },
      });

      expect(turns, hasLength(1));
      expect(turns.single.userText, 'compare this');
      expect(turns.single.blocks, hasLength(3));
      expect(turns.single.blocks[0].kind, TranscriptKind.thinking);
      expect(turns.single.blocks[0].text, 'Inspecting the selected table');
      expect(turns.single.blocks[0].expanded, isFalse);
      expect(turns.single.blocks[1].title, 'Command');
      expect(turns.single.blocks[1].preview, 'rg table');
      expect(turns.single.blocks[1].text, 'match');
      expect(turns.single.blocks[1].expanded, isFalse);
      expect(turns.single.blocks[2].artifacts.single.path, 'report.html');
      expect(turns.single.blocks[2].artifacts.single.cwd, '/workspace');
    },
  );

  test('stream merge deduplicates terminal thinking snapshots', () {
    expect(
      mergeActivityText(
        'Reading context',
        'Reading context',
        TranscriptKind.thinking,
        TranscriptLifecycle.completed,
      ),
      'Reading context',
    );
    expect(
      mergeActivityText(
        'Read',
        'Reading context',
        TranscriptKind.thinking,
        TranscriptLifecycle.completed,
      ),
      'Reading context',
    );
    expect(
      mergeActivityText(
        'part 1',
        ' part 2',
        TranscriptKind.assistant,
        TranscriptLifecycle.delta,
      ),
      'part 1 part 2',
    );
    expect(
      mergeActivityText(
        'Hello',
        'Hello from Codex',
        TranscriptKind.assistant,
        TranscriptLifecycle.delta,
      ),
      'Hello from Codex',
    );
    expect(
      mergeActivityText(
        'The answer is ready',
        'ready now',
        TranscriptKind.assistant,
        TranscriptLifecycle.delta,
      ),
      'The answer is ready now',
    );
  });

  test(
    'explicit deltas preserve repeated characters and snapshots replace',
    () {
      var text = '';
      for (final fragment in ['Book', 'keeper', ' ', '1', '1', ' 世界', '世界']) {
        text = mergeActivityText(
          text,
          fragment,
          TranscriptKind.assistant,
          TranscriptLifecycle.delta,
          append: true,
        );
      }
      expect(text, 'Bookkeeper 11 世界世界');
      expect(
        mergeActivityText(
          text,
          'Corrected final answer',
          TranscriptKind.assistant,
          TranscriptLifecycle.completed,
          replace: true,
        ),
        'Corrected final answer',
      );
    },
  );

  test('thinking and tools preserve their chronological timeline', () {
    final blocks = normalizeTranscriptBlocks([
      TranscriptBlock(
        id: 'commentary',
        kind: TranscriptKind.thinking,
        title: 'Thinking',
        text: 'Reading context',
        lifecycle: TranscriptLifecycle.completed,
        expanded: false,
      ),
      TranscriptBlock(
        id: 'tool-1',
        kind: TranscriptKind.tool,
        title: 'Command',
        text: 'rg context',
        lifecycle: TranscriptLifecycle.completed,
        expanded: false,
      ),
      TranscriptBlock(
        id: 'reasoning',
        kind: TranscriptKind.thinking,
        title: 'Thinking',
        text: 'Comparing context',
        lifecycle: TranscriptLifecycle.completed,
        expanded: false,
      ),
      TranscriptBlock(
        id: 'tool-2',
        kind: TranscriptKind.tool,
        title: 'Read',
        text: 'README.md',
        lifecycle: TranscriptLifecycle.completed,
        expanded: false,
      ),
    ]);

    expect(blocks.map((block) => block.kind), const [
      TranscriptKind.thinking,
      TranscriptKind.tool,
      TranscriptKind.thinking,
      TranscriptKind.tool,
    ]);
    expect(blocks.map((block) => block.text), const [
      'Reading context',
      'rg context',
      'Comparing context',
      'README.md',
    ]);
  });

  test('artifact HTML strips executable and navigation surfaces', () {
    final sanitized = sanitizeArtifactHtml('''
      <script>steal()</script>
      <iframe src="https://bad.example"></iframe>
      <button onclick="steal()">safe text</button>
      <a href="javascript:steal()">link</a>
      <img src="https://tracker.example/pixel.png" srcset="https://tracker.example/2x.png 2x">
      <img src="data:image/png;base64,aGVsbG8=" alt="inline image">
      <ul style="list-style-image: url(https://tracker.example/list.png)"><li>item</li></ul>
      <table><tr><td>kept</td></tr></table>
    ''');
    expect(sanitized, isNot(contains('<script')));
    expect(sanitized, isNot(contains('<iframe')));
    expect(sanitized, isNot(contains('onclick')));
    expect(sanitized, isNot(contains('javascript:')));
    expect(sanitized, isNot(contains('tracker.example')));
    expect(sanitized, contains('data:image/png;base64,aGVsbG8='));
    expect(sanitized, contains('<table>'));
    expect(sanitized, contains('safe text'));
  });

  test('session titles expose user text without private handoff markup', () {
    expect(
      compactSessionTitle(
        '<user_message>Explain the selected cell</user_message>\n<context>private</context>',
      ),
      'Explain the selected cell',
    );
    expect(compactSessionTitle('Zommi · New task'), 'New task');
  });
}
