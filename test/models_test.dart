import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MessageModel', () {
    final timestamp = DateTime(2026, 10, 4, 9, 30);

    test('toJson/fromJson round-trip preserves serialized fields', () {
      final msg = MessageModel(
        id: 'm1',
        text: 'hello',
        isSentByMe: true,
        timestamp: timestamp,
        imagePath: '/tmp/a.jpg',
        isTransferring: true,
        transferCurrent: 50,
        transferTotal: 100,
        transferKind: 'bytes',
      );

      final restored = MessageModel.fromJson(msg.toJson());
      expect(restored.text, 'hello');
      expect(restored.isSentByMe, true);
      expect(restored.timestamp, timestamp);
      expect(restored.imagePath, '/tmp/a.jpg');
    });

    test('copyWith overrides only the provided fields', () {
      final msg = MessageModel(
        text: 'a',
        isSentByMe: false,
        timestamp: timestamp,
        transferKind: 'bytes',
      );

      final updated = msg.copyWith(text: 'b', isTransferring: true);
      expect(updated.text, 'b');
      expect(updated.isTransferring, true);
      expect(updated.isSentByMe, false);
      expect(updated.timestamp, timestamp);
      expect(updated.transferKind, 'bytes');
    });

    test('id is preserved through copyWith', () {
      final msg = MessageModel(
        id: 'bubble-1',
        text: 'a',
        isSentByMe: true,
        timestamp: timestamp,
        isTransferring: true,
      );

      final updated = msg.copyWith(isTransferring: false);
      expect(updated.id, 'bubble-1');
    });
  });

  group('ChatSessionModel', () {
    test('toJson/fromJson round-trip preserves messages and device', () {
      final session = ChatSessionModel(
        id: 'addr-1',
        name: 'Peer Phone',
        createdAt: DateTime(2026, 10, 4, 9, 0),
        updatedAt: DateTime(2026, 10, 4, 9, 30),
        messages: [
          MessageModel(
            text: 'hi',
            isSentByMe: true,
            timestamp: DateTime(2026, 10, 4, 9, 30),
          ),
        ],
        device: {'name': 'Peer Phone', 'address': 'addr-1'},
      );

      final restored = ChatSessionModel.fromJson(session.toJson());
      expect(restored.id, 'addr-1');
      expect(restored.name, 'Peer Phone');
      expect(restored.createdAt, session.createdAt);
      expect(restored.updatedAt, session.updatedAt);
      expect(restored.messages, hasLength(1));
      expect(restored.messages.single.text, 'hi');
      expect(restored.messages.single.isSentByMe, true);
      expect(restored.device['address'], 'addr-1');
    });

    test('transport tag survives the round-trip (nearby)', () {
      final session = ChatSessionModel(
        id: 'uid-1',
        name: 'POCO X7',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {'name': 'POCO X7', 'address': 'uid-1'},
        transport: ChatSessionModel.transportNearby,
      );

      final restored = ChatSessionModel.fromJson(session.toJson());
      expect(restored.transport, ChatSessionModel.transportNearby);
      expect(restored.transportKind, ChatSessionModel.transportNearby);
    });

    test('reboundTo refreshes the address and re-tags the transport', () {
      final session = ChatSessionModel(
        id: 'DC:6A:E7:41:74:E6',
        name: 'Redmi Note 10 Pro',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {
          'name': 'Redmi Note 10 Pro',
          'address': '65eab5b0-4d42-493f-acfa-74c315e46cc6',
        },
        transport: ChatSessionModel.transportNearby,
      );

      final rebound = session.reboundTo(
        address: 'DC:6A:E7:41:74:E6',
        peerName: 'Redmi Note 10 Pro',
        transport: ChatSessionModel.transportBluetooth,
      );

      expect(rebound.device['address'], 'DC:6A:E7:41:74:E6');
      expect(rebound.transport, ChatSessionModel.transportBluetooth);
      expect(rebound.transportKind, ChatSessionModel.transportBluetooth);
      // The re-keyed id stays: only the stored address was stale.
      expect(rebound.id, 'DC:6A:E7:41:74:E6');
      expect(rebound.device['name'], 'Redmi Note 10 Pro');
      expect(rebound.messages, isEmpty);
    });

    test('reboundTo keeps the old address when no live one is available', () {
      final session = ChatSessionModel(
        id: 'addr-2',
        name: 'Peer Phone',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {'name': null, 'address': 'DC:6A:E7:41:74:E6'},
        transport: ChatSessionModel.transportBluetooth,
      );

      final rebound = session.reboundTo(
        peerName: 'Peer Phone',
        transport: ChatSessionModel.transportBluetooth,
      );

      expect(rebound.device['address'], 'DC:6A:E7:41:74:E6');
      // A missing device name is filled from the live connection.
      expect(rebound.device['name'], 'Peer Phone');
    });
  });
}