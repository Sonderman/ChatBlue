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

    test('reboundTo re-keys the session when the computed key changes', () {
      final session = ChatSessionModel(
        id: 'uid-1',
        name: 'Redmi Note 10 Pro',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {'name': 'Redmi Note 10 Pro', 'address': 'uid-1'},
        transport: ChatSessionModel.transportWifiDirect,
      );

      final rebound = session.reboundTo(
        newId: 'DC:6A:E7:41:74:E6',
        address: 'DC:6A:E7:41:74:E6',
        peerName: 'Redmi Note 10 Pro',
        transport: ChatSessionModel.transportBluetooth,
      );

      expect(rebound.id, 'DC:6A:E7:41:74:E6');
      expect(rebound.device['address'], 'DC:6A:E7:41:74:E6');

      // No new key — or an empty one — keeps the current id.
      expect(
        session.reboundTo(transport: ChatSessionModel.transportBluetooth).id,
        'uid-1',
      );
      expect(
        session
            .reboundTo(
              newId: '',
              transport: ChatSessionModel.transportBluetooth,
            )
            .id,
        'uid-1',
      );
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

    test('reboundTo upgrades a raw model title to the live display name', () {
      final session = ChatSessionModel(
        id: 'uid-1',
        name: 'M2101K6G',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {'name': 'M2101K6G', 'address': 'uid-1'},
        transport: ChatSessionModel.transportNearby,
      );

      final rebound = session.reboundTo(
        peerName: 'Redmi Note 10 Pro',
        transport: ChatSessionModel.transportNearby,
      );

      expect(rebound.name, 'Redmi Note 10 Pro');
      expect(rebound.device['name'], 'Redmi Note 10 Pro');
      // The id and address scheme stay untouched by the name upgrade.
      expect(rebound.id, 'uid-1');
      expect(rebound.device['address'], 'uid-1');
    });

    test('reboundTo never downgrades a display name to a model code', () {
      final session = ChatSessionModel(
        id: 'uid-2',
        name: 'Redmi Note 10 Pro',
        createdAt: DateTime(2026, 10, 8, 0, 0),
        updatedAt: DateTime(2026, 10, 8, 0, 5),
        messages: const [],
        device: {'name': 'Redmi Note 10 Pro', 'address': 'uid-2'},
        transport: ChatSessionModel.transportNearby,
      );

      final rebound = session.reboundTo(
        peerName: 'M2101K6G',
        transport: ChatSessionModel.transportNearby,
      );

      expect(rebound.name, 'Redmi Note 10 Pro');
      expect(rebound.device['name'], 'Redmi Note 10 Pro');
    });

    test('isRawModelCode separates model codes from display names', () {
      expect(ChatSessionModel.isRawModelCode('M2101K6G'), isTrue);
      expect(ChatSessionModel.isRawModelCode('2412DPC0AG'), isTrue);
      expect(ChatSessionModel.isRawModelCode('SM-G610F'), isTrue);
      expect(ChatSessionModel.isRawModelCode('Redmi Note 10 Pro'), isFalse);
      expect(ChatSessionModel.isRawModelCode('POCO X7 Pro'), isFalse);
      expect(ChatSessionModel.isRawModelCode(''), isFalse);
      expect(ChatSessionModel.isRawModelCode(null), isFalse);
    });

    test('shouldReplaceDisplayName blocks downgrades but allows renames', () {
      // Upgrade: raw model → display name.
      expect(
        ChatSessionModel.shouldReplaceDisplayName(
            'M2101K6G', 'Redmi Note 10 Pro'),
        isTrue,
      );
      // Downgrade: display name → raw model code.
      expect(
        ChatSessionModel.shouldReplaceDisplayName(
            'Redmi Note 10 Pro', 'M2101K6G'),
        isFalse,
      );
      // Both display names: a device rename wins.
      expect(
        ChatSessionModel.shouldReplaceDisplayName('Old Name', 'New Name'),
        isTrue,
      );
      // No-ops.
      expect(ChatSessionModel.shouldReplaceDisplayName('Same', 'Same'), isFalse);
      expect(ChatSessionModel.shouldReplaceDisplayName('Same', '  '), isFalse);
    });

    test('per-transport addresses round-trip through toJson/fromJson', () {
      final session = ChatSessionModel(
        id: 'sess-1',
        name: 'Galaxy J7 Prime',
        createdAt: DateTime(2026, 10, 10),
        updatedAt: DateTime(2026, 10, 10),
        messages: const [],
        device: const {'name': 'Galaxy J7 Prime', 'address': '36:8a:7b:b4:5b:9e'},
        transport: ChatSessionModel.transportWifiDirect,
        deviceAddresses: const {
          'wfd': '36:8a:7b:b4:5b:9e',
          'bt': '34:8A:7B:B4:5B:9D',
        },
      );

      final restored = ChatSessionModel.fromJson(session.toJson());
      expect(restored.addressFor('bt'), '34:8A:7B:B4:5B:9D');
      expect(restored.addressFor('wfd'), '36:8a:7b:b4:5b:9e');
      expect(restored.addressFor('nearby'), isNull);
    });

    test(
        'recordingPeerAddress adds/updates one entry and no-ops on no change',
        () {
      final session = ChatSessionModel(
        id: 'sess-1',
        name: 'PeerOne',
        createdAt: DateTime(2026, 10, 10),
        updatedAt: DateTime(2026, 10, 10),
        messages: const [],
        device: const {},
        transport: ChatSessionModel.transportBluetooth,
      );

      final learned = session.recordingPeerAddress('bt', 'AA:BB:CC:DD:EE:FF');
      expect(learned.addressFor('bt'), 'AA:BB:CC:DD:EE:FF');
      // A second transport's entry does not disturb the first.
      final both = learned.recordingPeerAddress('wfd', '66:55:44:33:22:11');
      expect(both.addressFor('bt'), 'AA:BB:CC:DD:EE:FF');
      expect(both.addressFor('wfd'), '66:55:44:33:22:11');
      // No change → the SAME instance (no useless save scheduling).
      expect(
        identical(both.recordingPeerAddress('bt', 'AA:BB:CC:DD:EE:FF'), both),
        isTrue,
      );
      expect(
        identical(session.recordingPeerAddress('bt', '  '), session),
        isTrue,
      );
    });

    test('reboundTo refreshes the map entry for the live transport only', () {
      final session = ChatSessionModel(
        id: '36:8a:7b:b4:5b:9e',
        name: 'Galaxy J7 Prime',
        createdAt: DateTime(2026, 10, 10),
        updatedAt: DateTime(2026, 10, 10),
        messages: const [],
        device: const {'name': 'Galaxy J7 Prime', 'address': '36:8a:7b:b4:5b:9e'},
        transport: ChatSessionModel.transportWifiDirect,
        deviceAddresses: const {'wfd': '36:8a:7b:b4:5b:9e'},
      );

      final rebound = session.reboundTo(
        newId: '34:8A:7B:B4:5B:9D',
        address: '34:8A:7B:B4:5B:9D',
        peerName: 'Galaxy J7 Prime',
        transport: ChatSessionModel.transportBluetooth,
      );

      // BOTH addresses survive the channel switch: the wfd entry from the
      // stored row, the bt entry learned from the live link.
      expect(rebound.addressFor('wfd'), '36:8a:7b:b4:5b:9e');
      expect(rebound.addressFor('bt'), '34:8A:7B:B4:5B:9D');
      expect(rebound.device['address'], '34:8A:7B:B4:5B:9D');
      expect(rebound.transport, ChatSessionModel.transportBluetooth);
    });
  });
}