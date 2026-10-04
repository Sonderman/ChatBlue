import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransferState', () {
    test('exposes direction/current/total/kind', () {
      final state = TransferState(
        direction: 'out',
        current: 42,
        total: 100,
        kind: 'bytes',
      );

      expect(state.direction, 'out');
      expect(state.current, 42);
      expect(state.total, 100);
      expect(state.kind, 'bytes');
    });

    test('allows zero total (unknown length)', () {
      final state = TransferState(
        direction: 'in',
        current: 0,
        total: 0,
        kind: 'text',
      );
      expect(state.total, 0);
      expect(state.current, 0);
    });
  });
}