import 'package:flutter_test/flutter_test.dart';
import 'package:focalet_flutter/state/focalet_controller.dart';
import 'package:focalet_flutter/state/focalet_models.dart';

ConversationTurn turn(String id, String text) =>
    ConversationTurn(id: id, runtimeTurnId: id, userText: text);

void main() {
  test('repeated text keeps distinct native entries when live IDs change', () {
    final merged = mergeSessionHistory(
      [turn('entry-1', 'Again'), turn('entry-2', 'Again')],
      [turn('flutter:1', 'Again'), turn('flutter:2', 'Again')],
      preserveCached: false,
      reconcileLocalTurnIds: true,
    );
    expect(merged.map((turn) => turn.runtimeTurnId), ['entry-1', 'entry-2']);
  });

  test('an incomplete native snapshot cannot collapse repeated live turns', () {
    final merged = mergeSessionHistory(
      [turn('entry-1', 'Again')],
      [turn('flutter:1', 'Again'), turn('flutter:2', 'Again')],
      preserveCached: true,
      reconcileLocalTurnIds: true,
    );
    expect(
      merged.map((turn) => turn.runtimeTurnId),
      containsAll(['flutter:1', 'flutter:2']),
    );
  });

  test('unrelated native identities are not reconciled by default', () {
    final merged = mergeSessionHistory(
      [turn('entry-1', 'Again')],
      [turn('flutter:1', 'Again')],
      preserveCached: false,
    );
    expect(merged, hasLength(2));
  });
}
