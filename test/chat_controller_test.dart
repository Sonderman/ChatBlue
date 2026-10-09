import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Chat-controller contract: seeding, the FIFO send queue, the history-sync
/// manifest flow and teardown. The fake binding records every transport call
/// and lets the test fire signals/events synchronously.
class FakeChatBinding implements ChatTransportBinding {
  FakeChatBinding({this.transport = ChatSessionModel.transportBluetooth});

  final String transport;
  bool connected = false;
  String? deviceKey;
  String? deviceId;
  String? deviceName;
  bool awaiting = false;
  String? connectError;

  final List<String> sentMessages = [];
  final List<Uint8List> sentBytes = [];
  int disconnectCalls = 0;
  int chatOpenedCalls = 0;
  int chatClosedCalls = 0;
  Completer<void>? holdSendMessage;
  void Function(Uint8List bytes, String text, {required String kind})?
      dataCallback;
  void Function({
    required String direction,
    required int current,
    required int total,
    required String kind,
  })? progressCallback;
  final List<ChatTransportListener> listeners = [];

  @override
  bool get isConnected => connected;

  @override
  String? get connectedDeviceKey => deviceKey;

  @override
  String? get connectedDeviceId => deviceId;

  @override
  String? get connectedDeviceName => deviceName;

  @override
  String get transportType => transport;

  @override
  bool get isAwaitingAcceptance => awaiting;

  @override
  String? get lastConnectError => connectError;

  @override
  void addListener(ChatTransportListener listener) => listeners.add(listener);

  @override
  void removeListener(ChatTransportListener listener) =>
      listeners.remove(listener);

  @override
  Future<bool> connectToSessionPeer(
          {required String? address, String? name}) async =>
      true;

  @override
  Future<void> disconnectFromDevice() async {
    disconnectCalls++;
  }

  @override
  Future<void> sendMessage(String message) async {
    final hold = holdSendMessage;
    if (hold != null) await hold.future;
    sentMessages.add(message);
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sentBytes.add(bytes);
  }

  @override
  void onChatOpened() => chatOpenedCalls++;

  @override
  void onChatClosed() => chatClosedCalls++;

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      dataCallback = callback;

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      progressCallback = callback;

  void emitConnection(bool c) {
    connected = c;
    for (final l in List.of(listeners)) {
      l.onTransportConnectionChanged(c);
    }
  }

  void emitReason(String r) {
    for (final l in List.of(listeners)) {
      l.onTransportDisconnectReason(r);
    }
  }

  void emitPeerName(String n) {
    for (final l in List.of(listeners)) {
      l.onTransportPeerName(n);
    }
  }

  void emitData(Uint8List bytes, String text, {required String kind}) =>
      dataCallback?.call(bytes, text, kind: kind);

  void emitProgress({
    required String direction,
    required int current,
    required int total,
    required String kind,
  }) =>
      progressCallback?.call(
        direction: direction,
        current: current,
        total: total,
        kind: kind,
      );
}

ChatSessionModel sessionFixture({
  String id = 'sess-1',
  String name = 'PeerOne',
  List<MessageModel> messages = const [],
  String? transport = ChatSessionModel.transportBluetooth,
  Map<String, dynamic>? device,
}) =>
    ChatSessionModel(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: List.of(messages),
      device: device ?? {'name': name, 'address': 'AA:BB:CC:DD:EE:FF'},
      transport: transport,
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

  ProviderContainer container({FakeChatBinding? b, AppDatabase? database}) {
    final resolved =
        database ?? (defaultDb = AppDatabase(NativeDatabase.memory()));
    return ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(resolved),
        appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
        chatBindingProvider.overrideWith((ref, kind) => b ?? binding),
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
      binding.emitConnection(false);
      binding.emitConnection(true);
      await pumpEventQueue();
      expect(manifestCount(), 2);

      // RF-4: a malformed sync frame is ignored silently.
      final before = stateOf(c, arg).messages.length;
      binding.emitData(Uint8List(0), '@@CHATBLUE_SYNC@@{broken', kind: 'text');
      await pumpEventQueue();
      expect(stateOf(c, arg).messages.length, before);
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
}
