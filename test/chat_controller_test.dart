import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/location_message.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_chat_binding.dart';

ChatSessionModel sessionFixture({
  String id = 'sess-1',
  String name = 'PeerOne',
  List<MessageModel> messages = const [],
  String? transport = ChatSessionModel.transportBluetooth,
  Map<String, dynamic>? device,
  Map<String, String> deviceAddresses = const {},
}) =>
    ChatSessionModel(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: List.of(messages),
      device: device ?? {'name': name, 'address': 'AA:BB:CC:DD:EE:FF'},
      transport: transport,
      deviceAddresses: deviceAddresses,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Media persistence writes files through path_provider (+ compute): point
  // it at a temp dir so the sync/media handlers can complete in tests.
  setUpAll(() {
    final tmpDir = Directory.systemTemp.createTempSync('chatblue_cc_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmpDir.path,
    );
  });

  late FakeChatBinding binding;
  AppDatabase? defaultDb;

  ProviderContainer container({
    FakeChatBinding? b,
    Map<String, FakeChatBinding>? byKind,
    AppDatabase? database,
  }) {
    final resolved =
        database ?? (defaultDb = AppDatabase(NativeDatabase.memory()));
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(resolved),
        appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
        chatBindingProvider
            .overrideWith((ref, kind) => byKind?[kind] ?? b ?? binding),
      ],
    );
  }

  setUp(() {
    binding = FakeChatBinding();
  });

  tearDown(() async {
    // Container disposal kicks off an unawaited flush of any pending save;
    // let it land before the in-memory database closes, otherwise drift
    // logs a rollback error for a write racing the close.
    await pumpEventQueue();
    await defaultDb?.close();
    defaultDb = null;
  });

  /// Opens a chat and keeps the autoDispose provider alive for the test.
  ChatController open(ProviderContainer c, ChatOpenArg arg) {
    final sub = c.listen(chatControllerProvider(arg), (_, _) {});
    addTearDown(sub.close);
    return c.read(chatControllerProvider(arg).notifier);
  }

  ChatState stateOf(ProviderContainer c, ChatOpenArg arg) =>
      c.read(chatControllerProvider(arg));

  group('seeding', () {
    test('seeds from arg.session', () async {
      final c = container();
      addTearDown(c.dispose);
      final seed = sessionFixture(
        messages: [
          MessageModel(
            id: 'm1',
            text: 'hi',
            isSentByMe: true,
            timestamp: DateTime.now(),
          ),
        ],
      );
      final arg = ChatOpenArg(transport: seed.transportKind, session: seed);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.chatSession.id, 'sess-1');
      expect(state.messages.map((m) => m.text), ['hi']);
    });

    test('reconstructs the session from the transport identity', () async {
      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.chatSession.id, 'AA:BB:CC:DD:EE:FF');
      expect(state.chatSession.name, 'PeerOne');
    });

    test('unusable identity (dummy MAC) falls back to a uuid key', () async {
      binding.deviceKey = '02:00:00:00:00:00';
      binding.deviceName = 'PeerOne';
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();

      final id = stateOf(c, arg).chatSession.id;
      expect(id, isNot('02:00:00:00:00:00'));
      expect(id, isNot('unknown'));
      expect(id.contains('-'), isTrue);
    });

    test('direct key hit hydrates the stored session from the DB', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await repo.saveChatSession(
        sessionFixture(
          id: 'AA:BB:CC:DD:EE:FF',
          messages: [
            MessageModel(
              id: 'm-stored',
              text: 'stored',
              isSentByMe: false,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.chatSession.id, 'AA:BB:CC:DD:EE:FF');
      expect(state.messages.map((m) => m.text), contains('stored'));
    });

    test('a direct key hit heals a stale model-code title from the live name',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await repo.saveChatSession(
        sessionFixture(
          id: 'uid-1',
          name: 'M2101K6G',
          device: {'name': 'M2101K6G', 'address': 'uid-1'},
          transport: ChatSessionModel.transportNearby,
        ),
      );

      final b = FakeChatBinding(transport: ChatSessionModel.transportNearby)
        ..deviceKey = 'uid-1'
        ..deviceName = 'Redmi Note 10 Pro';
      final c = container(b: b, database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportNearby);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.chatSession.name, 'Redmi Note 10 Pro');
      expect(state.chatSession.device['name'], 'Redmi Note 10 Pro');

      // The upgrade is persisted (debounced save) — a later list load shows
      // the display name instead of the raw model code.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final stored = await repo.loadChatSession('uid-1');
      expect(stored?.name, 'Redmi Note 10 Pro');
      expect(stored?.device['name'], 'Redmi Note 10 Pro');
    });

    test(
        'a direct key hit absorbs a same-peer row from another transport '
        '(one chat per peer across transports)', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      // The peer's BT-era row (keyed by its Bluetooth MAC): the
      // conversation the user had been using over Bluetooth.
      await repo.saveChatSession(
        sessionFixture(
          id: 'DC:6A:E7:41:74:E6',
          name: 'Redmi Note 10 Pro',
          transport: ChatSessionModel.transportBluetooth,
          device: {'name': 'Redmi Note 10 Pro', 'address': 'DC:6A:E7:41:74:E6'},
          messages: [
            MessageModel(
              id: 'm-bt',
              text: 'bluetooth era',
              isSentByMe: true,
              timestamp: DateTime(2026, 10, 10, 14),
            ),
          ],
        ),
      );
      // An older Wi‑Fi Direct row keyed by the peer's stable uid — the key
      // THIS open hits directly (the identity frame's uid).
      await repo.saveChatSession(
        sessionFixture(
          id: 'uid-1',
          name: 'Redmi Note 10 Pro',
          transport: ChatSessionModel.transportWifiDirect,
          device: {'name': 'Redmi Note 10 Pro', 'address': 'be:57:7a:fe:d5:a0'},
          messages: [
            MessageModel(
              id: 'm-wfd',
              text: 'wifi era',
              isSentByMe: false,
              timestamp: DateTime(2026, 10, 10, 15),
            ),
          ],
        ),
      );

      // A Wi‑Fi Direct open with the full identity: key = the peer's uid —
      // a DIRECT hit on the WFD row, with the BT-era row left beside it
      // (device-reported: the Redmi reopened the BT-era chat while the J7
      // opened its old WFD row — one connection, two different chats).
      final b = FakeChatBinding(transport: ChatSessionModel.transportWifiDirect)
        ..deviceId = 'uid-1'
        ..deviceKey = 'be:57:7a:fe:d5:a0'
        ..deviceName = 'Redmi Note 10 Pro';
      final c = container(b: b, database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportWifiDirect);
      open(c, arg);
      // Let the open's DB round-trips (load → sibling search → absorb
      // save/delete) complete.
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      final state = stateOf(c, arg);
      // The hit row stays the session (its uid key is the stable one); the
      // BT-era row is absorbed into it — union of messages, newest-first —
      // so both devices can land on ONE conversation.
      expect(state.chatSession.id, 'uid-1',
          reason: 'the direct hit must stay the live session (stable uid key)');
      expect(state.messages.map((m) => m.id).toList(), ['m-wfd', 'm-bt'],
          reason: 'the BT-era sibling was not absorbed — its history is '
              'missing from the open chat');
      expect(await repo.loadChatSession('DC:6A:E7:41:74:E6'), isNull,
          reason: 'the absorbed duplicate row must be gone (one chat per peer)');

      // Drain the debounced save before the database closes.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final stored = await repo.loadChatSession('uid-1');
      expect(stored!.messages.map((m) => m.id).toList(), ['m-wfd', 'm-bt']);
    });

    test(
        'a re-keyed open moves the history under the computed key — nothing '
        'is wiped', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await pumpEventQueue();
        await database.close();
      });
      final repo = SessionRepository(database);
      // Stored under the peer's stable uid (created over Wi‑Fi Direct),
      // carrying a full history.
      final base = DateTime(2026, 10, 6, 12);
      await repo.saveChatSession(
        sessionFixture(
          id: 'uid-1',
          name: 'Redmi Note 10 Pro',
          transport: ChatSessionModel.transportWifiDirect,
          device: {'name': 'Redmi Note 10 Pro', 'address': 'be:57:7a:fe:d5:a0'},
          messages: [
            for (var i = 29; i >= 0; i--)
              MessageModel(
                id: 'm$i',
                text: 'msg $i',
                isSentByMe: i.isEven,
                timestamp: base.add(Duration(minutes: i)),
              ),
          ],
        ),
      );

      // A Bluetooth reconnect: the wire carries no uid, so the computed key
      // is the MAC — a miss that matches the stored row by name. The re-key
      // must MOVE the row (id + full history) under the MAC: a rebound that
      // kept the old id made the save and the delete below target the SAME
      // row — session and history wiped, the chat open empty.
      binding.deviceKey = 'DC:6A:E7:41:74:E6';
      binding.deviceName = 'Redmi Note 10 Pro';
      binding.emitConnection(true);
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      // The open re-keys the row under the MAC and shows the stored window.
      var state = stateOf(c, arg);
      expect(state.chatSession.id, 'DC:6A:E7:41:74:E6',
          reason: 'the session moves under the computed key (re-key)');
      expect(state.messages, hasLength(20),
          reason: 'the stored history must survive the re-key');
      expect(state.messages.first.text, 'msg 29');
      expect(state.hasMoreOlder, isTrue);

      // The stored row moved: old key gone, full history under the new one,
      // and no split row was left behind.
      expect(await repo.loadChatSession('uid-1'), isNull);
      var stored = await repo.loadChatSession('DC:6A:E7:41:74:E6');
      expect(stored!.messages, hasLength(30),
          reason: 'the re-key must move every stored message');
      expect(await repo.getAllSessionsMeta(), hasLength(1));
      // Per-transport addresses: the re-key keeps the Wi‑Fi Direct era's
      // p2p address AND learns the live Bluetooth MAC — a later pick of
      // either transport dials its own entry.
      expect(stored.addressFor('wfd'), 'be:57:7a:fe:d5:a0');
      expect(stored.addressFor('bt'), 'DC:6A:E7:41:74:E6');

      // A send persists on top — and the history stays intact.
      controller.textController.text = 'hello again';
      controller.sendTextMessage();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await pumpEventQueue();
      stored = await repo.loadChatSession('DC:6A:E7:41:74:E6');
      expect(stored!.messages, hasLength(31));
      expect(stored.messages.first.text, 'hello again');

      // A later reconnect hits the moved row directly — window from the
      // store, no further re-key.
      controller.close();
      c.dispose();
      await pumpEventQueue();

      final c2 = container(database: database);
      addTearDown(c2.dispose);
      final arg2 = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c2, arg2);
      await pumpEventQueue();
      state = stateOf(c2, arg2);
      expect(state.chatSession.id, 'DC:6A:E7:41:74:E6');
      expect(state.messages, hasLength(20));
    });
  });

  group('send queue', () {
    test('serializes sends FIFO while one is in flight', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      binding.holdSendMessage = Completer<void>();
      controller.textController.text = 'a';
      controller.sendTextMessage();
      controller.textController.text = 'b';
      controller.sendTextMessage();
      await pumpEventQueue();
      expect(binding.sentMessages, isEmpty); // first send still held

      binding.holdSendMessage!.complete();
      await pumpEventQueue();
      expect(binding.sentMessages, ['a', 'b']);
    });

    test('close clears the queue; the in-flight send finishes, queued ones do not',
        () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      binding.holdSendMessage = Completer<void>();
      controller.textController.text = 'a';
      controller.sendTextMessage();
      controller.textController.text = 'b';
      controller.sendTextMessage();
      await pumpEventQueue();

      controller.close();
      binding.holdSendMessage!.complete();
      await pumpEventQueue();
      expect(binding.sentMessages, ['a']); // 'b' discarded with the queue
    });

    test('zero-total progress does not finalize or crash (RF-5)', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'm1',
              text: 'hi',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitProgress(
        direction: 'in',
        current: 0,
        total: 0,
        kind: 'bytes',
      );
      await pumpEventQueue();

      final bubble = stateOf(c, arg).messages.first;
      expect(bubble.text, '0%'); // no NaN, no division blowup
      expect(bubble.isTransferring, isTrue); // never finalized
    });
  });

  group('history sync', () {
    test('manifest → request → message flow, dedup, re-arm and malformed '
        'frames (RF-2, RF-4)', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'm1',
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      int manifestCount() => binding.sentMessages
          .where((m) => m.contains('"type":"manifest"'))
          .length;

      // Initial sync: our manifest went out.
      expect(manifestCount(), 1);

      // The peer's manifest is missing a message we do not have → request it.
      final peerHash =
          't:${sha256.convert(utf8.encode('peer-only')).toString()}';
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'manifest',
          'items': [
            {'h': peerHash, 'n': 1},
          ],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        binding.sentMessages
            .any((m) => m.contains('"type":"request"') && m.contains(peerHash)),
        isTrue,
      );

      // The peer requests OUR message → we serve it.
      final myHash = 't:${sha256.convert(utf8.encode('hello')).toString()}';
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'request',
          'items': [
            {'h': myHash, 'n': 1},
          ],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        binding.sentMessages.any((m) =>
            m.contains('"type":"message"') && m.contains('"text":"hello"')),
        isTrue,
      );

      // An incoming peer message integrates (perspective flipped) ...
      final peerMsg = {
        'id': 'p1',
        'text': 'from-peer',
        'sentByMe': true,
        'timestamp': DateTime.now().toIso8601String(),
      };
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'message',
          'messages': [peerMsg],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        stateOf(c, arg)
            .messages
            .any((m) => m.text == 'from-peer' && !m.isSentByMe),
        isTrue,
      );

      // ... and a duplicate of it is deduplicated.
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'message',
          'messages': [peerMsg],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.where((m) => m.text == 'from-peer').length,
        1,
      );

      // RF-2: a drop re-arms the sync; the next connect re-sends the manifest.
      // (The peer's manifest above already triggered one re-delivery, so the
      // absolute count includes it — assert the reconnect's exact +1.)
      final beforeReconnect = manifestCount();
      binding.emitConnection(false);
      binding.emitConnection(true);
      await pumpEventQueue();
      expect(manifestCount(), beforeReconnect + 1);

      // RF-4: a malformed sync frame is ignored silently.
      final before = stateOf(c, arg).messages.length;
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@{broken', kind: 'text');
      await pumpEventQueue();
      expect(stateOf(c, arg).messages.length, before);
    });

    test('manifest carries the sync protocol version; an older peer without '
        'it is read as v1 and still synced', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'm1',
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      // Our manifest advertises the local data-plane protocol version.
      final manifest = binding.sentMessages
          .firstWhere((m) => m.contains('"type":"manifest"'));
      final decoded =
          jsonDecode(manifest.substring('@@CHATBLUE_SYNC@@'.length))
              as Map<String, dynamic>;
      expect(decoded['pv'], syncProtocolVersion);

      // A pre-versioning peer's manifest (no `pv`) is treated as v1 and the
      // flow continues: the missing item is requested.
      final peerHash =
          't:${sha256.convert(utf8.encode('legacy-peer')).toString()}';
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'manifest',
          'items': [
            {'h': peerHash, 'n': 1},
          ],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        binding.sentMessages.any(
          (m) => m.contains('"type":"request"') && m.contains(peerHash),
        ),
        isTrue,
      );
    });
  });

  group('delivery ticks', () {
    test('a text send starts pending and flips to sent once written',
        () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      binding.holdSendMessage = Completer<void>();
      controller.textController.text = 'hi';
      controller.sendTextMessage();
      await pumpEventQueue();
      // The bubble exists (user feedback) but the socket write is still in
      // flight: waiting-to-send.
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliveryPending,
      );

      binding.holdSendMessage!.complete();
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliverySent,
      );
    });

    test('a failed socket write marks the message failed', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      binding.failSendMessage = true;
      controller.textController.text = 'boom';
      controller.sendTextMessage();
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliveryFailed,
      );
    });

    test('a delivery ack flips an outgoing message to delivered and persists',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      binding.connected = true;
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      controller.textController.text = 'hi';
      controller.sendTextMessage();
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliverySent,
      );

      // The peer confirms receipt with the content fingerprint of the
      // message it just stored.
      final fp = 'd:t:${sha256.convert(utf8.encode('hi'))}';
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'ack',
          'items': [fp],
        })}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliveryDelivered,
      );

      controller.close();
      await pumpEventQueue();
      final stored =
          await SessionRepository(database).loadChatSession('sess-1');
      expect(
        stored!.messages.single.delivery,
        MessageModel.deliveryDelivered,
        reason: 'the delivered state must ride the session persistence',
      );
    });

    test('an ack matches a media message by its stored-bytes fingerprint',
        () async {
      final tmp = Directory.systemTemp.createTempSync('chatblue_ack');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final imgPath = '${tmp.path}/img.jpg';
      final imgBytes = Uint8List.fromList(List.generate(64, (i) => i * 3));
      File(imgPath).writeAsBytesSync(imgBytes);

      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'img1',
              text: '[Image] (64 bytes)',
              isSentByMe: true,
              timestamp: DateTime.now(),
              imagePath: imgPath,
              delivery: MessageModel.deliverySent,
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      final fp = 'd:m:${sha256.convert(imgBytes)}';
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@${jsonEncode({
          'type': 'ack',
          'items': [fp],
        })}',
        kind: 'text',
      );
      // The matcher reads the file for the bytes fingerprint (real I/O).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();
      expect(
        stateOf(c, arg).messages.single.delivery,
        MessageModel.deliveryDelivered,
      );
    });

    test('the receiver acks a live text frame', () async {
      ChatController.ackFlushDelay = const Duration(milliseconds: 30);
      addTearDown(() {
        ChatController.ackFlushDelay = const Duration(milliseconds: 400);
      });
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(Uint8List(0), 'yo', kind: 'text');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue();
      final fp = 'd:t:${sha256.convert(utf8.encode('yo'))}';
      expect(
        binding.sentMessages.any(
          (m) => m.contains('"type":"ack"') && m.contains(fp),
        ),
        isTrue,
        reason: 'the receiver must confirm the stored message',
      );
    });

    test('the receiver re-acks sync entries it already holds', () async {
      ChatController.ackFlushDelay = const Duration(milliseconds: 30);
      addTearDown(() {
        ChatController.ackFlushDelay = const Duration(milliseconds: 400);
      });
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      final entry = {
        'id': 'p1',
        'text': 'from-peer',
        'sentByMe': true,
        'timestamp': DateTime.now().toIso8601String(),
      };
      String frame() => '@@CHATBLUE_SYNC@@${jsonEncode({
            'type': 'message',
            'messages': [entry],
          })}';
      final fp = 'd:t:${sha256.convert(utf8.encode('from-peer'))}';
      int ackCount() => binding.sentMessages
          .where((m) => m.contains('"type":"ack"') && m.contains(fp))
          .length;

      binding.emitData(Uint8List(0), frame(), kind: 'text');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue();
      expect(ackCount(), 1);

      // A re-serve of the same entry (e.g. the peer retried because our ack
      // was lost) is deduplicated as a message but acked AGAIN — the
      // sender's tick must still flip.
      binding.emitData(Uint8List(0), frame(), kind: 'text');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pumpEventQueue();
      expect(ackCount(), 2);
    });

    test('queued acks are dropped on disconnect (no socket to answer on)',
        () async {
      ChatController.ackFlushDelay = const Duration(milliseconds: 300);
      addTearDown(() {
        ChatController.ackFlushDelay = const Duration(milliseconds: 400);
      });
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(Uint8List(0), 'yo', kind: 'text');
      await pumpEventQueue(); // the ack is queued, not yet flushed
      binding.emitConnection(false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pumpEventQueue();
      expect(
        binding.sentMessages.any((m) => m.contains('"type":"ack"')),
        isFalse,
      );
    });
  });

  group('transport picker', () {
    testWidgets('same transport delegates to the classic session reconnect',
        (tester) async {
      final c = container();
      addTearDown(c.dispose);

      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final sub = c.listen(chatControllerProvider(arg), (_, _) {});
      addTearDown(sub.close);
      final controller = c.read(chatControllerProvider(arg).notifier);
      // Flush the open microtasks (pumpEventQueue hangs inside testWidgets'
      // fake-async zone — its zero-delay timers never fire).
      await tester.pump();

      await controller.connectViaTransport(
        ChatSessionModel.transportBluetooth,
        ctx,
      );
      await tester.pump();
      expect(binding.connectCalls, [
        (address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      ]);
    });

    test('dialing another transport uses the stored address/name there',
        () async {
      final other =
          FakeChatBinding(transport: ChatSessionModel.transportWifiDirect);
      final c = container(byKind: {
        ChatSessionModel.transportBluetooth: binding,
        ChatSessionModel.transportWifiDirect: other,
      });
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      final ok = await controller.dialTransportPeer(
        ChatSessionModel.transportWifiDirect,
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'PeerOne',
      );
      await pumpEventQueue();
      expect(ok, isTrue);
      expect(other.connectCalls, [
        (address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      ]);
      // A successful dial still waits for the dial to SETTLE (the peer's
      // acceptance / rejection — the scan screens' sequence); the fake's
      // settle future completes immediately.
      expect(other.dialSettledReads, 1);
    });

    test('a dial that still awaits acceptance holds until it settles',
        () async {
      final other =
          FakeChatBinding(transport: ChatSessionModel.transportWifiDirect);
      other.awaiting = true;
      other.holdDialSettled = Completer<void>();
      final c = container(byKind: {
        ChatSessionModel.transportBluetooth: binding,
        ChatSessionModel.transportWifiDirect: other,
      });
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      var dialed = false;
      final dial = controller
          .dialTransportPeer(
            ChatSessionModel.transportWifiDirect,
            address: 'AA:BB:CC:DD:EE:FF',
            name: 'PeerOne',
          )
          .then((v) {
        dialed = true;
        return v;
      });
      await pumpEventQueue();
      expect(other.connectCalls, hasLength(1));
      expect(dialed, isFalse,
          reason: 'the connecting panel must stay up until the dial settles');

      other.holdDialSettled!.complete();
      await dial;
      await pumpEventQueue();
      expect(dialed, isTrue);
      expect(other.dialSettledReads, 1);
    });
  });

  group('per-transport peer addresses', () {
    test('the live link address is recorded into the session map and '
        'persisted', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.deviceKey = '11:22:33:44:55:66';
      binding.deviceName = 'PeerOne';
      binding.emitConnection(true);
      await pumpEventQueue();

      expect(stateOf(c, arg).chatSession.addressFor('bt'), '11:22:33:44:55:66',
          reason: 'a live link teaches the peer\'s address on its channel');

      // The debounced save carries the map into the store.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final stored =
          await SessionRepository(defaultDb!).loadSessionMeta('sess-1');
      expect(stored!.addressFor('bt'), '11:22:33:44:55:66');
    });

    test('the classic reconnect prefers the per-transport map entry over the '
        'single stored address', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          device: const {'name': 'PeerOne', 'address': 'DD:DD:DD:DD:DD:DD'},
          deviceAddresses: const {'bt': 'AA:BB:CC:DD:EE:FF'},
        ),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      await controller.connectToCurrentSession();
      await pumpEventQueue();
      expect(binding.connectCalls, [
        (address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      ]);
    });
  });

  group('deferred-download fetch & transfer identity', () {
    test('an incoming voice adopts the sender-minted id', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_AUDIO@@{"duration":"0:18","id":"voice-id-1"}',
        kind: 'text',
      );
      binding.emitData(Uint8List.fromList([1, 2, 3, 4]), '', kind: 'bytes');
      // The persist runs on a compute isolate: condition-poll until the row
      // lands (pumpEventQueue only drains microtasks and races the isolate).
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (stateOf(c, arg).messages.any((m) => m.id == 'voice-id-1')) break;
      }
      final m =
          stateOf(c, arg).messages.firstWhere((m) => m.id == 'voice-id-1');
      expect(m.transferKind, 'audio');
      expect(m.text, '0:18');
      expect(m.isSentByMe, isFalse);
      expect(m.imagePath, isNotNull);
    });

    test('a fetch with a diverged id is served by the content fallback',
        () async {
      final c = container();
      addTearDown(c.dispose);
      final tmp = File(
        '${Directory.systemTemp.path}/cb_fetch_'
        '${DateTime.now().microsecondsSinceEpoch}.m4a',
      )..writeAsBytesSync(List.filled(297, 7));
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(messages: [
          MessageModel(
            id: 'own-id',
            text: '0:18',
            isSentByMe: true,
            timestamp: DateTime.now(),
            imagePath: tmp.path,
            transferKind: 'audio',
            delivery: MessageModel.deliveryDelivered,
          ),
        ]),
      );
      open(c, arg);
      await pumpEventQueue();

      // The requester's replica carries a DIFFERENT id (the divergence this
      // repairs): the id lookup misses, the content keys resolve it.
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"fetch","id":"peer-side-id",'
            '"kind":"audio","caption":"0:18","size":297}',
        kind: 'text',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(
        binding.sentMessages.any((s) => s.contains('"type":"download"')),
        isTrue,
        reason: 'the held file must be served despite the id mismatch',
      );

      // A size that matches nothing still misses (the fallback is exact).
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"fetch","id":"peer-side-id-2",'
            '"kind":"audio","caption":"0:18","size":298}',
        kind: 'text',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();
      expect(
        binding.sentMessages.any((s) => s.contains('"type":"fetchMiss"')),
        isTrue,
      );
    });

    test('a sent file announces its id and the row keeps it', () async {
      final c = container();
      addTearDown(c.dispose);
      final tmp = File(
        '${Directory.systemTemp.path}/cb_send_'
        '${DateTime.now().microsecondsSinceEpoch}.txt',
      )..writeAsBytesSync(List.filled(64, 3));
      addTearDown(() {
        if (tmp.existsSync()) tmp.deleteSync();
      });
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();
      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.emitConnection(true);
      await pumpEventQueue();

      await controller.sendFile(tmp.path, name: 'notes.txt');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();

      final anon = binding.sentMessages.firstWhere(
        (s) => s.startsWith('@@CHATBLUE_FILE@@'),
      );
      final decoded =
          jsonDecode(anon.substring('@@CHATBLUE_FILE@@'.length)) as Map;
      final id = decoded['id'] as String;
      expect(id, isNotEmpty,
          reason: 'the announcement must carry the sender-minted id so the '
              'receiver adopts it');

      // The transfer's final progress event mints + finalizes the bubble
      // UNDER the announced id.
      binding.emitProgress(
        direction: 'out',
        current: 64,
        total: 64,
        kind: 'bytes',
      );
      await pumpEventQueue();
      final row = stateOf(c, arg).messages.firstWhere((m) => m.id == id);
      expect(row.transferKind, 'file');
      expect(row.delivery, MessageModel.deliverySent);
    });

    test('a fetch request carries the content repair keys', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(messages: [
          MessageModel(
            id: 'ph-1',
            text: '0:18',
            isSentByMe: false,
            timestamp: DateTime.now(),
            remoteMediaSize: 297,
            transferKind: 'audio',
          ),
        ]),
      );
      final controller = open(c, arg);
      await pumpEventQueue();
      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.emitConnection(true);
      await pumpEventQueue();

      final placeholder =
          stateOf(c, arg).messages.firstWhere((m) => m.id == 'ph-1');
      await controller.downloadMedia(placeholder);
      await pumpEventQueue();

      final fetch = binding.sentMessages.firstWhere(
        (s) => s.contains('"type":"fetch"'),
      );
      final decoded =
          jsonDecode(fetch.substring('@@CHATBLUE_SYNC@@'.length)) as Map;
      expect(decoded['id'], 'ph-1');
      expect(decoded['kind'], 'audio');
      expect(decoded['caption'], '0:18');
      expect(decoded['size'], 297);
    });

    test('a diverged download fills the LOCAL placeholder by content',
        () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(messages: [
          MessageModel(
            id: 'local-1',
            text: '0:18',
            isSentByMe: true,
            timestamp: DateTime(2026, 10, 10, 22, 54),
            remoteMediaSize: 297,
            transferKind: 'audio',
            delivery: MessageModel.deliveryDelivered,
          ),
        ]),
      );
      open(c, arg);
      await pumpEventQueue();

      // The served download carries the PEER's id (the divergence): the
      // completion must resolve the local placeholder by content — kind +
      // caption + payload size — and fill IT (local id kept).
      final payload = base64Encode(List.filled(297, 9));
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"download","messages":[{"id":'
            '"remote-side-id","text":"0:18","sentByMe":false,'
            '"timestamp":"2026-10-10T22:54:47.000","type":"audio",'
            '"bytes":"$payload"}]}',
        kind: 'text',
      );
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final m = stateOf(c, arg).messages.firstWhere((m) => m.id == 'local-1');
        if (m.imagePath != null) break;
      }
      final filled =
          stateOf(c, arg).messages.firstWhere((m) => m.id == 'local-1');
      expect(filled.imagePath, isNotNull,
          reason: 'the fetched bytes must land on the local placeholder even '
              'though the entry id differs');
      expect(filled.hasRemoteMedia, isFalse);
      expect(filled.isTransferring, isFalse);
      expect(filled.delivery, MessageModel.deliveryDelivered,
          reason: 'the fetched file must not erase the delivery tick');
      expect(stateOf(c, arg).messages, hasLength(1),
          reason: 'no duplicate bubble may appear for the fetched file');
    });
  });

  group('teardown', () {
    test('close is idempotent; disconnects once; signals stop (RF-1)',
        () async {
      final c = container();
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      controller.close();
      expect(binding.disconnectCalls, 1);
      expect(binding.chatClosedCalls, 1);
      expect(binding.listeners, isEmpty);

      controller.close();
      expect(binding.disconnectCalls, 1); // idempotent

      final before = stateOf(c, arg);
      binding.emitConnection(true);
      binding.emitPeerName('X');
      await pumpEventQueue();
      expect(identical(stateOf(c, arg), before), isTrue); // no state writes

      c.dispose();
      expect(binding.disconnectCalls, 1); // onDispose close was a no-op
    });

    test('close flushes the pending save', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final c = container(database: database);
      addTearDown(c.dispose);
      final seed = sessionFixture(transport: null); // untagged → tag stamp saves
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: seed,
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      controller.close();
      await pumpEventQueue();

      final stored = await SessionRepository(database).loadChatSession('sess-1');
      expect(stored, isNotNull);
      expect(stored!.transport, ChatSessionModel.transportBluetooth);
    });
  });

  group('review-fix regressions', () {
    // Sync/media handlers await real disk writes (compute isolate) —
    // pumpEventQueue alone does not cover them; give them real time.
    Future<void> settleMedia() async {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();
    }

    test('a live frame during a media sync apply is not clobbered', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'm1',
              text: 'old',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      final payload = jsonEncode({
        'type': 'message',
        'messages': [
          {
            'id': 'p1',
            'text': '[Image] (5 bytes)',
            'sentByMe': true,
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'image',
            'bytes': base64Encode(Uint8List.fromList([1, 2, 3, 4, 5])),
          }
        ],
      });
      // The sync handler suspends on the disk write of the image; a live
      // text frame lands while it is suspended.
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@$payload', kind: 'text');
      binding.emitData(Uint8List(0), 'live-msg', kind: 'text');
      await settleMedia();

      final texts = stateOf(c, arg).messages.map((m) => m.text).toList();
      expect(texts, contains('live-msg'),
          reason: 'live frame clobbered by the sync write-back: $texts');
      expect(texts.where((t) => t.startsWith('[Image]')).length, 1);
    });

    test('a live frame during an incoming image finalize survives', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'm1',
              text: 'old',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(Uint8List.fromList([9, 9, 9, 9]), '', kind: 'bytes');
      binding.emitData(Uint8List(0), 'live-msg', kind: 'text');
      await settleMedia();

      final texts = stateOf(c, arg).messages.map((m) => m.text).toList();
      expect(texts, contains('live-msg'),
          reason: 'live frame clobbered by the image finalize: $texts');
    });

    test('two back-to-back image frames both finalize', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(Uint8List.fromList([1, 1, 1, 1]), '', kind: 'bytes');
      binding.emitData(Uint8List.fromList([2, 2, 2, 2]), '', kind: 'bytes');
      await settleMedia();

      final images = stateOf(c, arg)
          .messages
          .where((m) => m.text.startsWith('[Image]'))
          .length;
      expect(images, 2, reason: 'an image was lost');
    });

    test('a deferred-media download fills its placeholder', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              id: 'p1',
              text: '[Image] (5 bytes)',
              isSentByMe: false,
              timestamp: DateTime.now(),
              remoteMediaSize: 5,
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      final payload = jsonEncode({
        'type': 'message',
        'messages': [
          {
            'id': 'p1',
            'text': '[Image] (5 bytes)',
            'sentByMe': true,
            'timestamp': DateTime.now().toIso8601String(),
            'type': 'image',
            'bytes': base64Encode(Uint8List.fromList([1, 2, 3, 4, 5])),
          }
        ],
      });
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@$payload', kind: 'text');
      await settleMedia();

      final msgs = stateOf(c, arg).messages;
      expect(msgs.length, 1);
      expect(msgs.first.imagePath, isNotNull);
      expect(msgs.first.remoteMediaSize, isNull);
    });

    test('a completed outgoing transfer is persisted finalized', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      binding.connected = true;
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      binding.emitProgress(
        direction: 'out',
        current: 50,
        total: 100,
        kind: 'bytes',
      );
      binding.emitProgress(
        direction: 'out',
        current: 100,
        total: 100,
        kind: 'bytes',
      );
      controller.close();
      await pumpEventQueue();

      final stored = await SessionRepository(database).loadChatSession('sess-1');
      final bubble = stored!.messages.first;
      expect(bubble.isTransferring, isFalse,
          reason: 'persisted mid-transfer (save snapshot taken too early)');
      expect(bubble.transferCurrent, 100);
    });

    test('clearing the conversation drops a pending debounced save', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      binding.connected = true;
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      final controller = open(c, arg);
      await pumpEventQueue();

      // An incoming message schedules a debounced save whose snapshot holds
      // it; clearing must drop that pending write, not let it resurrect.
      binding.emitData(Uint8List(0), 'doomed', kind: 'text');
      await pumpEventQueue();
      await controller.clearConversation();

      controller.close();
      await pumpEventQueue();

      final stored = await SessionRepository(database).loadChatSession('sess-1');
      expect(stored!.messages, isEmpty,
          reason: 'a pending save resurrected the cleared conversation');
    });
  });

  group('transfer stall handling', () {
    // The stall watchdog runs on real timers: shrink it to test speed and
    // always restore the production value.
    late Duration originalTimeout;

    setUp(() {
      originalTimeout = ChatController.transferStallTimeout;
    });

    tearDown(() {
      ChatController.transferStallTimeout = originalTimeout;
    });

    /// Media finalizes write through compute: give the isolate real time.
    Future<void> settleMedia() async {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await pumpEventQueue();
    }

    ChatOpenArg arg() => ChatOpenArg(
          transport: ChatSessionModel.transportBluetooth,
          session: sessionFixture(),
        );

    test('a stalled incoming transfer fails visibly after the timeout', () async {
      ChatController.transferStallTimeout = const Duration(milliseconds: 250);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      // Native readings arrive until the wire dies at ~99.7% (which used to
      // render as a deceptive, eternal "100%").
      binding.emitProgress(
          direction: 'in', current: 4096, total: 358000, kind: 'bytes');
      binding.emitProgress(
          direction: 'in', current: 357000, total: 358000, kind: 'bytes');
      await pumpEventQueue();
      expect(stateOf(c, a).messages.first.isTransferring, isTrue);

      // No further event: the watchdog must resolve the bubble.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();

      final bubble = stateOf(c, a).messages.first;
      expect(bubble.isTransferring, isFalse,
          reason: 'the stall watchdog never resolved the bubble');
      expect(bubble.text, '[Failed to receive image]');

      // A late trickle of the SAME stale frame must not re-plant a ghost
      // progress bubble.
      final count = stateOf(c, a).messages.length;
      binding.emitProgress(
          direction: 'in', current: 357500, total: 358000, kind: 'bytes');
      await pumpEventQueue();
      expect(stateOf(c, a).messages.length, count);
      expect(
        stateOf(c, a).messages.any((m) => m.isTransferring),
        isFalse,
        reason: 'a straggler event recreated a stuck bubble',
      );
    });

    test('the exact byte count of the final reading is kept', () async {
      ChatController.transferStallTimeout = const Duration(seconds: 60);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'in', current: 50000, total: 358000, kind: 'bytes');
      binding.emitProgress(
          direction: 'in', current: 358000, total: 358000, kind: 'bytes');
      await pumpEventQueue();

      // The final (current == total) reading must land on the bubble BUT
      // it must stay a progress bubble: only the data frame concludes it.
      // This reading is what tells a complete frame apart from a stalled
      // wire during on-device diagnosis.
      final bubble = stateOf(c, a).messages.first;
      expect(bubble.transferCurrent, 358000);
      expect(bubble.isTransferring, isTrue);

      binding.emitData(Uint8List(200), '', kind: 'bytes');
      await settleMedia();
      final done = stateOf(c, a).messages.first;
      expect(done.imagePath, isNotNull);
      expect(done.isTransferring, isFalse);
    });

    test('a post-finalize straggler event plants no ghost bubble', () async {
      ChatController.transferStallTimeout = const Duration(seconds: 60);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'in', current: 4096, total: 100000, kind: 'bytes');
      binding.emitData(Uint8List(200), '', kind: 'bytes');
      await settleMedia();
      expect(stateOf(c, a).messages.first.imagePath, isNotNull);

      // The native decode path emits one more final progress event right
      // after the data dispatch; with the id consumed it must be ignored.
      binding.emitProgress(
          direction: 'in', current: 100000, total: 100000, kind: 'bytes');
      await pumpEventQueue();

      final msgs = stateOf(c, a).messages;
      expect(msgs.length, 1);
      expect(msgs.any((m) => m.isTransferring), isFalse,
          reason: 'a post-completion final event created a ghost bubble');
    });

    test('a disconnect fails the in-flight transfer immediately', () async {
      ChatController.transferStallTimeout = const Duration(seconds: 60);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'in', current: 10000, total: 358000, kind: 'bytes');
      await pumpEventQueue();
      expect(stateOf(c, a).messages.first.isTransferring, isTrue);

      binding.emitConnection(false);
      await pumpEventQueue();

      final bubble = stateOf(c, a).messages.first;
      expect(bubble.isTransferring, isFalse,
          reason: 'a dropped link left the transfer bubble stuck');
      expect(bubble.text, '[Failed to receive image]');
    });

    test('a late tail resurrects the failed bubble instead of duplicating',
        () async {
      ChatController.transferStallTimeout = const Duration(milliseconds: 250);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'in', current: 4096, total: 358000, kind: 'bytes');
      binding.emitProgress(
          direction: 'in', current: 357000, total: 358000, kind: 'bytes');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(stateOf(c, a).messages.first.text, '[Failed to receive image]');

      // The tail finally arrives: the image lands in the failed bubble.
      binding.emitData(Uint8List(200), '', kind: 'bytes');
      await settleMedia();

      final msgs = stateOf(c, a).messages;
      expect(msgs.length, 1,
          reason: 'failed placeholder plus image: duplicated message');
      expect(msgs.first.imagePath, isNotNull);
    });

    test('a completed incoming transfer is not failed by the watchdog',
        () async {
      ChatController.transferStallTimeout = const Duration(milliseconds: 250);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'in', current: 4096, total: 358000, kind: 'bytes');
      binding.emitProgress(
          direction: 'in', current: 358000, total: 358000, kind: 'bytes');
      binding.emitData(Uint8List(200), '', kind: 'bytes');
      await settleMedia();

      // The data-frame finalize cancelled the watchdog; waiting it out must
      // not corrupt the finished image message.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await pumpEventQueue();

      final msgs = stateOf(c, a).messages;
      expect(msgs.first.imagePath, isNotNull);
      expect(msgs.first.isTransferring, isFalse);
      expect(msgs.first.text.startsWith('[Image]'), isTrue);
    });

    test('an outgoing stalled transfer fails visibly', () async {
      ChatController.transferStallTimeout = const Duration(milliseconds: 250);
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final a = arg();
      open(c, a);
      await pumpEventQueue();

      binding.emitProgress(
          direction: 'out', current: 8192, total: 358000, kind: 'bytes');
      await pumpEventQueue();
      expect(stateOf(c, a).messages.first.isTransferring, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      await pumpEventQueue();
      final bubble = stateOf(c, a).messages.first;
      expect(bubble.isTransferring, isFalse);
      expect(bubble.text, '[Failed to send image]');

      // A blocked write unblocking late emits straggler events: they must
      // not recreate the bubble the watchdog just failed.
      final count = stateOf(c, a).messages.length;
      binding.emitProgress(
          direction: 'out', current: 16384, total: 358000, kind: 'bytes');
      await pumpEventQueue();
      expect(stateOf(c, a).messages.length, count);
    });
  });

  group('stale-state cleanup', () {
    test('a late identity merge keeps the newest-first message order',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      final older = MessageModel(
        id: 'm-old',
        text: 'older',
        isSentByMe: true,
        timestamp: DateTime(2026, 1, 1, 10),
      );
      final newer = MessageModel(
        id: 'm-new',
        text: 'newer',
        isSentByMe: false,
        timestamp: DateTime(2026, 1, 1, 11),
      );
      await repo.saveChatSession(
        sessionFixture(
          id: 'stored-1',
          name: 'PeerOne',
          messages: [newer, older],
        ),
      );

      final c = container(database: database);
      addTearDown(c.dispose);
      // Opened with an unknown identity: the key MISSes and a fresh (empty)
      // session is created — exactly the late-identity scenario.
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();
      expect(stateOf(c, arg).messages, isEmpty);

      // The identity frame lands: the stored session for this peer is
      // adopted into the fresh one.
      binding.deviceName = 'PeerOne';
      binding.emitPeerName('PeerOne');
      await pumpEventQueue();
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(
        state.messages.map((m) => m.id).toList(),
        ['m-new', 'm-old'],
        reason: 'the merge sorted ascending — the rendered (reverse: true) '
            'and persisted list would show the whole chat upside down',
      );
      // The duplicate is gone and the merged history is stored under the
      // live session id, order preserved.
      expect(await repo.loadChatSession('stored-1'), isNull);
      final merged = await repo.loadChatSession(state.chatSession.id);
      expect(merged!.messages.map((m) => m.id).toList(), ['m-new', 'm-old']);

      // Let the debounced merge save land while the database is still open:
      // the dispose-time flush would otherwise race the tearDown close and
      // log a rollback error.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test(
        'the late identity merge finds the name-matched sibling even while '
        'the fresh row already owns the peer MAC (no self-shadow)', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await repo.saveChatSession(
        sessionFixture(
          id: 'bt-era',
          name: 'PeerOne',
          transport: ChatSessionModel.transportBluetooth,
          device: {'name': 'PeerOne', 'address': 'AA:BB:CC:DD:EE:FF'},
          messages: [
            MessageModel(
              id: 'm-old',
              text: 'older',
              isSentByMe: true,
              timestamp: DateTime(2026, 1, 1, 10),
            ),
          ],
        ),
      );

      final c = container(database: database);
      addTearDown(c.dispose);
      // The open started before the name was known: the MAC is present, so
      // the fresh session is keyed — and ADDRESSED — on the peer MAC.
      binding.deviceKey = 'be:57:7a:fe:d5:a0';
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();
      expect(stateOf(c, arg).chatSession.id, 'be:57:7a:fe:d5:a0');
      // The fresh row lands in the store (debounced) — from now on the
      // MAC-keyed search would return the live row itself.
      await Future<void>.delayed(const Duration(milliseconds: 350));

      // The identity frame lands with the display name: the stored sibling
      // must be found (name match) despite the self MAC shadow.
      binding.deviceName = 'PeerOne';
      binding.emitPeerName('PeerOne');
      await pumpEventQueue();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.messages.map((m) => m.id).toList(), ['m-old'],
          reason: 'the late merge matched the live row itself on the MAC and '
              'silently skipped the real sibling');
      expect(await repo.loadChatSession('bt-era'), isNull,
          reason: 'the name-matched sibling must be absorbed into the live '
              'session (one chat per peer)');
      final live = state.chatSession.id;
      expect(
        (await repo.loadChatSession(live))!.messages.map((m) => m.id).toList(),
        ['m-old'],
      );

      // Drain the debounced merge save the same way.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('a voice announcement from a dropped link does not misroute the '
        'next image', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      // Voice announcement arrives…
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_AUDIO@@{"duration":"0:03"}',
        kind: 'text',
      );
      // …and the link drops before the audio bytes.
      binding.emitConnection(false);
      await pumpEventQueue();

      // Reconnect: the peer's next IMAGE bytes must land as an image, not
      // be saved as a .m4a voice message off the stale announcement.
      binding.emitConnection(true);
      binding.emitData(Uint8List.fromList([1, 2, 3, 4]), '', kind: 'bytes');
      await pumpEventQueue();
      await pumpEventQueue();

      final msgs = stateOf(c, arg).messages;
      expect(msgs.any((m) => m.transferKind == 'audio'), isFalse,
          reason: 'stale _pendingAudioMeta routed image bytes to the audio '
              'handler');
      expect(msgs.any((m) => m.imagePath != null), isTrue);

      // Drain the debounced finalize save the same way.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
  });

  group('link panel', () {
    test('link stats accumulate and the rate decays after its window', () {
      final stats = LinkStats();
      stats.recordIn(400);
      stats.recordOut(100);
      expect(stats.bytesIn, 400);
      expect(stats.bytesOut, 100);
      expect(stats.framesIn, 1);
      expect(stats.framesOut, 1);
      final now = DateTime.now();
      expect(stats.currentBytesPerSecond(now: now), closeTo(100, 0.5));
      // Six seconds later the samples left the 5 s window: idle again.
      expect(
        stats.currentBytesPerSecond(now: now.add(const Duration(seconds: 6))),
        0,
      );
    });

    test('panel visibility defaults to hidden and toggles', () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      // No settings store in tests → the fail-open default: hidden.
      expect(stateOf(c, arg).linkPanelVisible, isFalse);
      final controller = c.read(chatControllerProvider(arg).notifier);
      controller.toggleLinkPanel();
      expect(stateOf(c, arg).linkPanelVisible, isTrue);
      controller.toggleLinkPanel();
      expect(stateOf(c, arg).linkPanelVisible, isFalse);
    });

    test('a persisted visible preference shows the panel at open', () async {
      final db = AppDatabase(NativeDatabase.memory());
      SettingsRepository.instance = SettingsRepository(db);
      await SettingsRepository.instance!.load();
      await SettingsRepository.instance!
          .setString('connectionPanelVisible', 'true');
      addTearDown(() async {
        SettingsRepository.instance = null;
        await db.close();
      });

      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      expect(stateOf(c, arg).linkPanelVisible, isTrue,
          reason: 'both roles (dialer and receiver) open the same screen and '
              'read the same device-local preference — an enabled receiver '
              'phone must show the panel too, regardless of who dialed');

      // Toggling off persists the new value (cache updates synchronously).
      c.read(chatControllerProvider(arg).notifier).toggleLinkPanel();
      expect(
        SettingsRepository.instance!.getString('connectionPanelVisible'),
        'false',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('link stats count received and sent traffic', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);
      expect(controller.transportKind, ChatSessionModel.transportBluetooth);

      // Incoming text frame + incoming bytes frame.
      binding.emitData(Uint8List(0), 'hello', kind: 'text');
      await pumpEventQueue();
      binding.emitData(Uint8List.fromList([1, 2, 3, 4]), '', kind: 'bytes');
      await pumpEventQueue();

      final stats = controller.linkStats;
      expect(stats.framesIn, 2);
      expect(stats.bytesIn, 4 + 5); // 5 = 'hello'.length
      expect(stats.currentBytesPerSecond(), greaterThan(0));

      // Outgoing text.
      controller.textController.text = 'ping';
      controller.sendTextMessage();
      await pumpEventQueue();
      expect(stats.framesOut, 1);
      expect(stats.bytesOut, 4);

      // Drain the debounced persist of the received-bytes bubble.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('the link uptime starts on connect and clears on disconnect',
        () async {
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      expect(controller.connectedSince, isNull);
      binding.emitConnection(true);
      expect(controller.connectedSince, isNotNull);
      binding.emitConnection(false);
      expect(controller.connectedSince, isNull);
    });
  });

  group('peer signal sharing', () {
    test('opening a connected chat pushes the dial-time reading', () async {
      final oldDelay = ChatController.linkShareRetryDelay;
      ChatController.linkShareRetryDelay = const Duration(milliseconds: 40);
      addTearDown(() => ChatController.linkShareRetryDelay = oldDelay);

      binding.connected = true;
      binding.deviceRssi = -58;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      List<Map<String, dynamic>> shares() => binding.sentMessages
          .where((m) => m.startsWith('@@CHATBLUE_SYNC@@'))
          .map((m) => jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
              as Map<String, dynamic>)
          .where((d) => d['type'] == 'linkShare')
          .toList();

      expect(shares(), hasLength(1),
          reason: 'the dialer pushes its scan reading for the accepting '
              'side, which never scanned');
      expect(shares().single['rssi'], -58);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(shares(), hasLength(2),
          reason: 'one retry covers the peer chat opening a beat late');
    });

    test('a chat without a local reading shares nothing', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();

      expect(
        binding.sentMessages.where((m) => m.contains('"linkShare"')),
        isEmpty,
        reason: 'the accepting side has no reading — it must not add wire '
            'traffic (which keeps unrelated message-flow assertions clean)',
      );
    });

    test(
        'a live readback is pushed when no scan value exists (Wi‑Fi Direct '
        'client side)', () async {
      final b = FakeChatBinding(transport: ChatSessionModel.transportWifiDirect)
        ..connected = true
        ..liveRssi = -47;
      final c = container(b: b);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportWifiDirect,
        session:
            sessionFixture(transport: ChatSessionModel.transportWifiDirect),
      );
      open(c, arg);
      await pumpEventQueue();
      await pumpEventQueue();

      final shares = b.sentMessages
          .where((m) =>
              m.startsWith('@@CHATBLUE_SYNC@@') && m.contains('"linkShare"'))
          .map((m) => jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
              as Map<String, dynamic>)
          .toList();
      expect(shares, isNotEmpty,
          reason: 'the Wi‑Fi Direct client side holds the only live reading — '
              'without this push the GO side\'s panel shows no signal at all '
              '(device-reported)');
      expect(shares.first['rssi'], -47);
    });

    test('the live reading is re-shared when it moves (change-guarded)',
        () async {
      final oldInterval = ChatController.linkShareRefreshInterval;
      ChatController.linkShareRefreshInterval =
          const Duration(milliseconds: 50);
      addTearDown(() => ChatController.linkShareRefreshInterval = oldInterval);

      final b = FakeChatBinding(transport: ChatSessionModel.transportWifiDirect)
        ..connected = true
        ..liveRssi = -47;
      final c = container(b: b);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportWifiDirect,
        session:
            sessionFixture(transport: ChatSessionModel.transportWifiDirect),
      );
      open(c, arg);
      await pumpEventQueue();
      await pumpEventQueue();

      List<int> shared() => b.sentMessages
          .where((m) =>
              m.startsWith('@@CHATBLUE_SYNC@@') && m.contains('"linkShare"'))
          .map((m) => (jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
              as Map<String, dynamic>)['rssi'] as int)
          .toList();

      expect(shared(), [-47], reason: 'first share at connect');

      // A stable link must not chatter.
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(shared(), [-47]);

      // The link moves: the new reading reaches the peer on the next tick.
      b.liveRssi = -55;
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(shared(), [-47, -55],
          reason: 'the GO side\'s "(peer reading)" must track the live link');
    });

    test('a linkShare from the peer surfaces as peerReportedRssi', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);
      expect(controller.peerReportedRssi, isNull);

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"linkShare","rssi":-54}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(controller.peerReportedRssi, -54,
          reason: 'the dialer\'s scan reading reaches the accepting side');

      // Implausible readings must not poison the panel.
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"linkShare","rssi":3}',
        kind: 'text',
      );
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"linkShare","rssi":-300}',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(controller.peerReportedRssi, -54);
    });

    test(
        'the peer\'s manifest re-delivers our manifest + reading once '
        '(slow-receiver race)', () async {
      // Device-reported: an old slow phone wires its chat controller's
      // socket callback SECONDS after its chat opens (DB round-trips on a
      // weak CPU) — the dialer's first manifest and linkShare both land
      // before that and are dropped, leaving the receiver's panel with no
      // signal at all. The peer's manifest only exists once their wiring
      // is done, so it doubles as their readiness signal: respond.
      binding.connected = true;
      binding.deviceRssi = -58;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      int count(String type) => binding.sentMessages
          .where((m) => m.startsWith('@@CHATBLUE_SYNC@@'))
          .where((m) =>
              (jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
                  as Map<String, dynamic>)['type'] ==
              type)
          .length;

      expect(count('manifest'), 1);
      expect(count('linkShare'), 1);

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"manifest","pv":3,"items":[]}',
        kind: 'text',
      );
      await pumpEventQueue();

      expect(count('manifest'), 2,
          reason: 'their manifest proves they can receive NOW — our first '
              'pass may have raced their wiring and must be re-delivered');
      expect(count('linkShare'), 2,
          reason: 'the reading rides along so the peer panel can show it');
    });

    test('the manifest re-delivery fires once per connection', () async {
      binding.connected = true;
      binding.deviceRssi = -58;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      int count(String type) => binding.sentMessages
          .where((m) => m.startsWith('@@CHATBLUE_SYNC@@'))
          .where((m) =>
              (jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
                  as Map<String, dynamic>)['type'] ==
              type)
          .length;

      const manifest = '@@CHATBLUE_SYNC@@{"type":"manifest","pv":3,"items":[]}';
      binding.emitData(Uint8List(0), manifest, kind: 'text');
      binding.emitData(Uint8List(0), manifest, kind: 'text');
      await pumpEventQueue();

      expect(count('manifest'), 2,
          reason: 'a second peer manifest (their own re-delivery) must not '
              'trigger another round — bounded, no ping-pong');
      expect(count('linkShare'), 2);
    });

    test(
        'a nudge re-delivers when no peer manifest arrives at all '
        '(both first passes raced)', () async {
      final oldDelay = ChatController.syncNudgeDelay;
      ChatController.syncNudgeDelay = const Duration(milliseconds: 60);
      addTearDown(() => ChatController.syncNudgeDelay = oldDelay);

      binding.connected = true;
      binding.deviceRssi = -58;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      int count(String type) => binding.sentMessages
          .where((m) => m.startsWith('@@CHATBLUE_SYNC@@'))
          .where((m) =>
              (jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
                  as Map<String, dynamic>)['type'] ==
              type)
          .length;

      expect(count('manifest'), 1);

      await Future<void>.delayed(const Duration(milliseconds: 140));
      await pumpEventQueue();

      expect(count('manifest'), 2,
          reason: 'silence past the nudge deadline means our first pass may '
              'never have reached the peer — deliver once more');
      expect(count('linkShare'), 2);
    });

    test('the nudge stays quiet once the peer\'s manifest arrived', () async {
      final oldDelay = ChatController.syncNudgeDelay;
      ChatController.syncNudgeDelay = const Duration(milliseconds: 60);
      addTearDown(() => ChatController.syncNudgeDelay = oldDelay);

      binding.connected = true;
      binding.deviceRssi = -58;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(
          messages: [
            MessageModel(
              text: 'hello',
              isSentByMe: true,
              timestamp: DateTime.now(),
            ),
          ],
        ),
      );
      open(c, arg);
      await pumpEventQueue();

      int count(String type) => binding.sentMessages
          .where((m) => m.startsWith('@@CHATBLUE_SYNC@@'))
          .where((m) =>
              (jsonDecode(m.substring('@@CHATBLUE_SYNC@@'.length))
                  as Map<String, dynamic>)['type'] ==
              type)
          .length;

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"manifest","pv":3,"items":[]}',
        kind: 'text',
      );
      await pumpEventQueue();

      await Future<void>.delayed(const Duration(milliseconds: 140));
      await pumpEventQueue();

      expect(count('manifest'), 2,
          reason: 'the re-delivery already covered the peer — the nudge '
              'must not add a third');
    });

    test('linkQuality delegates to the binding (Nearby bandwidth metric)',
        () async {
      final b = FakeChatBinding(transport: ChatSessionModel.transportNearby)
        ..connected = true
        ..linkQualityValue = 3;
      final c = container(b: b);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportNearby,
        session: sessionFixture(transport: ChatSessionModel.transportNearby),
      );
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);
      expect(controller.linkQuality, 3);

      b.linkQualityValue = null;
      expect(controller.linkQuality, isNull,
          reason: 'transports without a quality metric expose null');
    });
  });

  group('file & location sharing', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('chatblue_share_test');
    });

    tearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<File> writeTempFile(String name, int size) async {
      final f = File('${tmpDir.path}/$name');
      await f.writeAsBytes(List<int>.filled(size, 7));
      return f;
    }

    ChatOpenArg shareArg() => ChatOpenArg(
          transport: ChatSessionModel.transportBluetooth,
          session: sessionFixture(),
        );

    test(
        'a file send announces name+size before the bytes and finalizes a '
        'file bubble', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      final file = await writeTempFile('report.pdf', 1024);
      await controller.sendFile(file.path, name: 'report.pdf');
      await pumpEventQueue();

      // The announcement frame precedes the bytes (it carries the name the
      // receiver labels the file with); the bytes stay raw binary.
      expect(binding.sentMessages.length, 1);
      expect(binding.sentMessages.single, startsWith('@@CHATBLUE_FILE@@'));
      expect(binding.sentMessages.single, contains('"name":"report.pdf"'));
      expect(binding.sentMessages.single, contains('"size":1024'));
      expect(binding.sentBytes.length, 1);
      expect(binding.sentBytes.single.length, 1024);

      // The transfer's own final progress event finalizes the bubble as a
      // file message (same contract as images/voice).
      binding.emitProgress(
        direction: 'out',
        current: 1024,
        total: 1024,
        kind: 'bytes',
      );
      final msgs = stateOf(c, arg).messages;
      final fileMsg = msgs.firstWhere((m) => m.transferKind == 'file');
      expect(fileMsg.imagePath, file.path);
      expect(fileMsg.text, contains('report.pdf'));
      expect(fileMsg.isTransferring, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('a file above the cap is refused (nothing is sent)', () async {
      final oldCap = ChatController.maxFileBytes;
      ChatController.maxFileBytes = 512;
      addTearDown(() => ChatController.maxFileBytes = oldCap);

      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      final file = await writeTempFile('big.bin', 4096);
      await controller.sendFile(file.path, name: 'big.bin');
      await pumpEventQueue();

      expect(binding.sentMessages, isEmpty);
      expect(binding.sentBytes, isEmpty);
      expect(
        stateOf(c, arg).messages.any((m) => m.transferKind == 'file'),
        isFalse,
      );
    });

    test(
        'file sending is blocked for a peer on a pre-feature build (pv<2); '
        'location still goes', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      // The peer's sync manifest reports protocol v1 (it cannot render the
      // file announcement/bytes pair).
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"manifest","pv":1,"items":[]}',
        kind: 'text',
      );
      await pumpEventQueue();

      final file = await writeTempFile('doc.txt', 64);
      await controller.sendFile(file.path, name: 'doc.txt');
      await pumpEventQueue();
      expect(
        binding.sentMessages.where((m) => m.startsWith('@@CHATBLUE_FILE@@')),
        isEmpty,
        reason: 'a pre-feature peer must not receive the new wire pair',
      );

      // Location is plain text — safe for every build.
      controller.sendLocation(
        lat: 41.008237,
        lng: 28.978358,
        accuracyMeters: 12,
      );
      await pumpEventQueue();
      expect(binding.sentMessages.any((m) => m.startsWith('📍')), isTrue);
    });

    test('an incoming file lands under its original name with a file bubble',
        () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_FILE@@{"name":"trip plan.pdf","size":4}',
        kind: 'text',
      );
      await pumpEventQueue();
      binding.emitData(Uint8List.fromList([9, 8, 7, 6]), '', kind: 'bytes');
      await pumpEventQueue();
      await pumpEventQueue();

      final msgs = stateOf(c, arg).messages;
      final m = msgs.firstWhere((x) => x.transferKind == 'file');
      expect(m.imagePath, isNotNull);
      expect(m.imagePath!.split(Platform.pathSeparator).last, 'trip plan.pdf');
      expect(File(m.imagePath!).readAsBytesSync(), [9, 8, 7, 6]);
      expect(m.isTransferring, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('a second incoming file with the same name does not overwrite the '
        'first', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();

      for (final payload in [
        [1, 1],
        [2, 2],
      ]) {
        binding.emitData(
          Uint8List(0),
          '@@CHATBLUE_FILE@@{"name":"a.bin","size":2}',
          kind: 'text',
        );
        await pumpEventQueue();
        binding.emitData(Uint8List.fromList(payload), '', kind: 'bytes');
        await pumpEventQueue();
      }

      // The incoming write runs on a background isolate (compute): wait
      // for the messages to land instead of racing a fixed pump window.
      for (var i = 0; i < 50 && stateOf(c, arg).messages.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final files = stateOf(c, arg)
          .messages
          .where((m) => m.transferKind == 'file')
          .toList();
      expect(files.length, 2);
      expect(files[0].imagePath == files[1].imagePath, isFalse);
      final byteSets = files
          .map((m) => File(m.imagePath!).readAsBytesSync().toList())
          .toList();
      expect(byteSets, containsAll([
        [1, 1],
        [2, 2],
      ]));

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test(
        'a file announcement from a dropped link does not misroute the next '
        'bytes', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();

      // Announcement arrives… then the link drops before the bytes.
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_FILE@@{"name":"x.pdf","size":4}',
        kind: 'text',
      );
      binding.emitConnection(false);
      await pumpEventQueue();

      // Reconnect: the peer's next IMAGE bytes must land as an image, not
      // be saved as a file off the stale announcement.
      binding.emitConnection(true);
      binding.emitData(Uint8List.fromList([1, 2, 3, 4]), '', kind: 'bytes');
      await pumpEventQueue();
      await pumpEventQueue();

      final msgs = stateOf(c, arg).messages;
      expect(msgs.any((m) => m.transferKind == 'file'), isFalse,
          reason: 'stale _pendingIncomingFileMeta routed image bytes to the '
              'file handler');
      expect(msgs.any((m) => m.imagePath != null), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('a synced file entry materializes as a file message with its name',
        () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();

      final b64 = base64Encode([9, 9, 9]);
      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"message","messages":[{"id":"f1",'
        '"text":"[File] notes.txt (3 bytes)","sentByMe":true,'
        '"timestamp":"${DateTime.now().toIso8601String()}",'
        '"type":"file","fileName":"notes.txt","bytes":"$b64"}]}',
        kind: 'text',
      );
      await pumpEventQueue();
      await pumpEventQueue();

      final m =
          stateOf(c, arg).messages.firstWhere((x) => x.id == 'f1');
      expect(m.transferKind, 'file');
      expect(m.imagePath!.split(Platform.pathSeparator).last, 'notes.txt');
      expect(File(m.imagePath!).readAsBytesSync(), [9, 9, 9]);

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });

    test('a large synced file arrives as a download placeholder', () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();

      binding.emitData(
        Uint8List(0),
        '@@CHATBLUE_SYNC@@{"type":"message","messages":[{"id":"f2",'
        '"text":"[File] movie.mp4 (10485760 bytes)","sentByMe":false,'
        '"timestamp":"${DateTime.now().toIso8601String()}",'
        '"type":"file","fileName":"movie.mp4","remoteSize":10485760}]}',
        kind: 'text',
      );
      await pumpEventQueue();

      final m =
          stateOf(c, arg).messages.firstWhere((x) => x.id == 'f2');
      expect(m.transferKind, 'file');
      expect(m.hasRemoteMedia, isTrue);
      expect(m.remoteMediaSize, 10485760);
    });

    test(
        'location messages travel as encoded text and reach the bubble state',
        () async {
      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = shareArg();
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      controller.sendLocation(
        lat: 41.008237,
        lng: 28.978358,
        accuracyMeters: 12,
      );
      await pumpEventQueue();

      expect(binding.sentMessages.length, 1);
      expect(binding.sentMessages.single, startsWith('📍'));
      final mine = stateOf(c, arg).messages.first;
      expect(mine.text, binding.sentMessages.single);
      expect(mine.isSentByMe, isTrue);

      // The peer side of the same format: arrives as a plain chat message
      // (the rich bubble is a pure render-time concern).
      final peerText = encodeLocationMessage(
        lat: 40.7128,
        lng: -74.006,
        accuracyMeters: 25,
      );
      binding.emitData(Uint8List(0), peerText, kind: 'text');
      await pumpEventQueue();
      final received = stateOf(c, arg).messages.first;
      expect(received.text, peerText);
      expect(received.isSentByMe, isFalse);
    });
  });

  group('image transfer integrity', () {
    test(
        'an outgoing image stores exactly the bytes that went on the wire '
        '(compression included)', () async {
      final original = Uint8List.fromList(
        List<int>.generate(1000, (i) => i % 251),
      );
      // A compression pass that changes both size and content — the real
      // case (quality-70 re-encode of a picked photo).
      final compressed = Uint8List.fromList(
        List<int>.generate(400, (i) => (i * 7) % 251),
      );
      final oldCompressor = ChatController.imageCompressor;
      ChatController.imageCompressor = (b) async => compressed;
      addTearDown(() => ChatController.imageCompressor = oldCompressor);

      binding.connected = true;
      final c = container();
      addTearDown(c.dispose);
      final arg = ChatOpenArg(
        transport: ChatSessionModel.transportBluetooth,
        session: sessionFixture(),
      );
      open(c, arg);
      await pumpEventQueue();
      final controller = c.read(chatControllerProvider(arg).notifier);

      await controller.enqueuePickedImage(original);
      await pumpEventQueue();

      expect(binding.sentBytes.length, 1);
      expect(binding.sentBytes.single, compressed,
          reason: 'the wire must carry the compressed copy');

      binding.emitProgress(
        direction: 'out',
        current: 400,
        total: 400,
        kind: 'bytes',
      );
      final sent = stateOf(c, arg)
          .messages
          .firstWhere((m) => m.imagePath != null && m.isSentByMe);
      final stored = File(sent.imagePath!).readAsBytesSync();
      expect(stored, compressed,
          reason: 'the stored copy must be byte-identical to the wire bytes '
              '— a divergent copy (stored original vs sent compressed) '
              'defeats the content-hash dedup fallback, so a peer re-serve '
              'cannot be recognised when the ±10 s timestamp window does '
              'not apply (slow transfers / clock skew) and the same image '
              'is added a second time (device-reported duplicate bubbles)');

      await Future<void>.delayed(const Duration(milliseconds: 350));
    });
  });

  group('paged history', () {
    /// Seeds [count] stored messages (oldest → newest, minute-spaced) under
    /// the fixture session key.
    Future<void> seedHistory(AppDatabase database, {required int count}) async {
      final base = DateTime(2026, 10, 6, 12);
      await SessionRepository(database).saveChatSession(
        sessionFixture(
          id: 'AA:BB:CC:DD:EE:FF',
          messages: [
            for (var i = count - 1; i >= 0; i--)
              MessageModel(
                id: 'm$i',
                text: 'msg $i',
                isSentByMe: i.isEven,
                timestamp: base.add(Duration(minutes: i)),
              ),
          ],
        ),
      );
    }

    test('a transport open loads only the newest 20 messages', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await seedHistory(database, count: 30);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.messages, hasLength(20));
      expect(state.messages.first.text, 'msg 29'); // newest first
      expect(state.messages.last.text, 'msg 10');
      expect(state.hasMoreOlder, isTrue);
    });

    test('a seeded open slices to the newest 20 and reports more', () async {
      final c = container();
      addTearDown(c.dispose);
      final base = DateTime(2026, 10, 6, 12);
      final seed = sessionFixture(
        messages: [
          for (var i = 29; i >= 0; i--)
            MessageModel(
              id: 'm$i',
              text: 'msg $i',
              isSentByMe: i.isEven,
              timestamp: base.add(Duration(minutes: i)),
            ),
        ],
      );
      final arg = ChatOpenArg(transport: seed.transportKind, session: seed);
      open(c, arg);
      await pumpEventQueue();

      final state = stateOf(c, arg);
      expect(state.messages, hasLength(20));
      expect(state.messages.first.text, 'msg 29');
      expect(state.hasMoreOlder, isTrue);
    });

    test('loadOlderMessages appends +5 pages until the history is exhausted',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await seedHistory(database, count: 30);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();
      expect(stateOf(c, arg).messages, hasLength(20));

      await controller.loadOlderMessages();
      expect(stateOf(c, arg).messages, hasLength(25));
      expect(stateOf(c, arg).messages.last.text, 'msg 5');
      expect(stateOf(c, arg).hasMoreOlder, isTrue);

      await controller.loadOlderMessages();
      expect(stateOf(c, arg).messages, hasLength(30));
      expect(stateOf(c, arg).messages.last.text, 'msg 0');
      expect(stateOf(c, arg).hasMoreOlder, isFalse);

      // Exhausted: further calls are no-ops.
      await controller.loadOlderMessages();
      expect(stateOf(c, arg).messages, hasLength(30));
    });

    test('a history that fits the window never reports more', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      await seedHistory(database, count: 5);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();

      expect(stateOf(c, arg).messages, hasLength(5));
      expect(stateOf(c, arg).hasMoreOlder, isFalse);
      await controller.loadOlderMessages();
      expect(stateOf(c, arg).messages, hasLength(5));
    });

    test('a windowed save keeps the unloaded history and upserts a send',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await seedHistory(database, count: 30);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      binding.emitConnection(true);
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();

      controller.textController.text = 'fresh send';
      controller.sendTextMessage();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await pumpEventQueue();

      final stored = await repo.loadChatSession('AA:BB:CC:DD:EE:FF');
      expect(stored!.messages, hasLength(31),
          reason: 'the 30 stored messages plus the fresh send');
      expect(stored.messages.first.text, 'fresh send');
      expect(stateOf(c, arg).messages, hasLength(21));
    });

    test('deleteMessage removes the stored row explicitly', () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await seedHistory(database, count: 30);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();

      final victim = stateOf(c, arg).messages[3]; // 'msg 26'
      controller.deleteMessage(victim.id);
      await pumpEventQueue();

      final stored = await repo.loadChatSession('AA:BB:CC:DD:EE:FF');
      expect(stored!.messages, hasLength(29));
      expect(stored.messages.any((m) => m.id == victim.id), isFalse);
      expect(stateOf(c, arg).messages, hasLength(19));
    });

    test('clearConversation empties the store but keeps the session',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await seedHistory(database, count: 25);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      final controller = open(c, arg);
      await pumpEventQueue();

      await controller.clearConversation();
      expect(stateOf(c, arg).messages, isEmpty);
      expect(stateOf(c, arg).hasMoreOlder, isFalse);

      final stored = await repo.loadChatSession('AA:BB:CC:DD:EE:FF');
      expect(stored, isNotNull);
      expect(stored!.messages, isEmpty);
    });

    test('a re-served message below the window is not integrated twice',
        () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repo = SessionRepository(database);
      await seedHistory(database, count: 30);

      binding.deviceKey = 'AA:BB:CC:DD:EE:FF';
      binding.deviceName = 'PeerOne';
      final c = container(database: database);
      addTearDown(c.dispose);
      final arg = ChatOpenArg(transport: ChatSessionModel.transportBluetooth);
      open(c, arg);
      await pumpEventQueue();
      expect(stateOf(c, arg).messages, hasLength(20));

      // The peer re-serves its copy of 'msg 2' — far below the loaded
      // window. Same text + direction + timestamp: the DB-side dedup must
      // skip it (the in-memory window alone used to cover the history).
      final base = DateTime(2026, 10, 6, 12);
      final dupe = jsonEncode({
        'type': 'message',
        'messages': [
          {
            'id': 'dup-copy',
            'text': 'msg 2',
            // Peer saw it as incoming → flips to ours: sent by me.
            'sentByMe': false,
            'timestamp':
                base.add(const Duration(minutes: 2)).toIso8601String(),
          },
        ],
      });
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@$dupe', kind: 'text');
      await pumpEventQueue();

      final stored = await repo.loadChatSession('AA:BB:CC:DD:EE:FF');
      expect(stored!.messages, hasLength(30), reason: 'no duplicate row');
      expect(stateOf(c, arg).messages, hasLength(20));

      // Control: a genuinely new synced text IS integrated and persisted.
      final fresh = jsonEncode({
        'type': 'message',
        'messages': [
          {
            'id': 'fresh-1',
            'text': 'brand new from peer',
            'sentByMe': true,
            'timestamp': DateTime.now().toIso8601String(),
          },
        ],
      });
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@$fresh', kind: 'text');
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await pumpEventQueue();

      final after = await repo.loadChatSession('AA:BB:CC:DD:EE:FF');
      expect(after!.messages, hasLength(31));
      expect(stateOf(c, arg).messages.first.text, 'brand new from peer');
    });
  });
}
