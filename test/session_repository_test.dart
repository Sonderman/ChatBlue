import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SessionRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = SessionRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  MessageModel message({
    String? id,
    String text = 'hello',
    bool isSentByMe = true,
    DateTime? timestamp,
    String? imagePath,
    int? remoteMediaSize,
    bool isTransferring = false,
    int? transferCurrent,
    int? transferTotal,
    String? transferKind,
  }) =>
      MessageModel(
        id: id,
        text: text,
        isSentByMe: isSentByMe,
        timestamp: timestamp ?? DateTime(2026, 10, 6, 12),
        imagePath: imagePath,
        remoteMediaSize: remoteMediaSize,
        isTransferring: isTransferring,
        transferCurrent: transferCurrent,
        transferTotal: transferTotal,
        transferKind: transferKind,
      );

  ChatSessionModel session({
    String id = 'peer-1',
    String name = 'Redmi',
    DateTime? createdAt,
    DateTime? updatedAt,
    List<MessageModel>? messages,
    String? transport = 'bt',
    Map<String, dynamic>? device,
    Map<String, String> deviceAddresses = const {},
  }) =>
      ChatSessionModel(
        id: id,
        name: name,
        createdAt: createdAt ?? DateTime(2026, 10, 6, 10),
        updatedAt: updatedAt ?? DateTime(2026, 10, 6, 11),
        messages: messages ?? [message()],
        device: device ?? {'name': name, 'address': 'AA:BB:CC:DD:EE:FF'},
        transport: transport,
        deviceAddresses: deviceAddresses,
      );

  test('save -> load round-trips every message field', () async {
    final msg = message(
      id: 'm1',
      text: 'with everything',
      isSentByMe: false,
      // Millisecond precision: drift's default seconds-based storage would
      // lose it, so the column goes through DateTimeMillisConverter.
      timestamp: DateTime(2026, 10, 6, 12, 34, 56, 789),
      imagePath: '/data/img.jpg',
      remoteMediaSize: 4096,
      transferKind: 'audio',
    );
    await repo.saveChatSession(session(messages: [msg]));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Redmi');
    expect(loaded.transport, 'bt');
    expect(loaded.device['address'], 'AA:BB:CC:DD:EE:FF');
    expect(loaded.messages, hasLength(1));

    final restored = loaded.messages.single;
    expect(restored.id, 'm1');
    expect(restored.text, 'with everything');
    expect(restored.isSentByMe, false);
    expect(restored.timestamp, DateTime(2026, 10, 6, 12, 34, 56, 789));
    expect(restored.imagePath, '/data/img.jpg');
    expect(restored.remoteMediaSize, 4096);
    expect(restored.transferKind, 'audio');
  });

  test('getAllChatSessions sorts by updatedAt DESC and filters by chatID',
      () async {
    await repo.saveChatSession(
        session(id: 'a', updatedAt: DateTime(2026, 1, 1)));
    await repo.saveChatSession(
        session(id: 'b', updatedAt: DateTime(2026, 3, 1)));
    await repo.saveChatSession(
        session(id: 'c', updatedAt: DateTime(2026, 2, 1)));

    final all = await repo.getAllChatSessions();
    expect(all.map((s) => s.id).toList(), ['b', 'c', 'a']);

    final filtered = await repo.getAllChatSessions(chatID: 'a');
    expect(filtered.map((s) => s.id).toList(), ['a']);
  });

  test('identical timestamps round-trip in the deterministic id order',
      () async {
    // The tiebreak is `id DESC` alongside `timestamp DESC`: the read order
    // matches the keyset pagination predicate exactly, so identical-
    // timestamp messages can neither be skipped nor repeated across pages.
    // `seq` (the legacy write index) is no longer authoritative — windowed
    // upserts cannot maintain global positions.
    final t = DateTime(2026, 10, 6, 12);
    await repo.saveChatSession(session(messages: [
      message(id: 'm1', text: 'first', timestamp: t),
      message(id: 'm2', text: 'second', timestamp: t),
      message(id: 'm3', text: 'third', timestamp: t),
    ]));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages.map((m) => m.text).toList(),
        ['third', 'second', 'first']);
  });

  test('save replaces the stored message list (removals are dropped)',
      () async {
    await repo.saveChatSession(session(messages: [
      message(id: 'm1', text: 'one'),
      message(id: 'm2', text: 'two'),
    ]));
    await repo.saveChatSession(session(messages: [
      message(id: 'm2', text: 'two'),
    ]));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages.map((m) => m.id).toList(), ['m2']);
  });

  test('messages with null/empty ids get a generated, distinct id', () async {
    await repo.saveChatSession(session(messages: [
      message(id: null, text: 'no id'),
      message(id: '', text: 'empty id'),
    ]));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages, hasLength(2));
    final ids = loaded.messages.map((m) => m.id).toList();
    expect(ids[0], isNotNull);
    expect(ids[0]!.isNotEmpty, true);
    expect(ids[1]!.isNotEmpty, true);
    expect(ids[0] == ids[1], false);
  });

  test('deleting a session removes its messages (FK cascade)', () async {
    await repo.saveChatSession(session());
    await repo.deleteChatSession('peer-1');

    expect(await repo.loadChatSession('peer-1'), isNull);
    expect(await db.select(db.messages).get(), isEmpty);
  });

  test('re-key flow: save under new id, delete old key, messages survive',
      () async {
    // Mirrors the chat controller's session re-key: the message rows move to
    // the new session id on save, then the old session is deleted.
    await repo.saveChatSession(
        session(id: 'old-key', messages: [message(id: 'm1')]));
    final loaded = await repo.loadChatSession('old-key');
    final reKeyed = ChatSessionModel(
      id: 'new-key',
      name: loaded!.name,
      createdAt: loaded.createdAt,
      updatedAt: loaded.updatedAt,
      messages: loaded.messages,
      device: loaded.device,
      transport: loaded.transport,
    );

    await repo.saveChatSession(reKeyed);
    await repo.deleteChatSession('old-key');

    final after = await repo.loadChatSession('new-key');
    expect(after, isNotNull);
    expect(after!.messages.single.id, 'm1');
    expect(await repo.loadChatSession('old-key'), isNull);
  });

  test('clearing all sessions empties both tables', () async {
    await repo.saveChatSession(session(id: 'a'));
    await repo.saveChatSession(session(id: 'b'));

    await repo.clearAllChatSessions();

    expect(await repo.getAllChatSessions(), isEmpty);
    expect(await db.select(db.messages).get(), isEmpty);
  });

  test('watchSessions emits the updated list after a save', () async {
    final emissions = expectLater(
      repo.watchSessions(),
      emitsThrough(
        predicate<List<ChatSessionModel>>(
          (sessions) => sessions.any((s) => s.id == 'w1'),
        ),
      ),
    );
    // Let the initial (empty) emission flow before the save lands.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await repo.saveChatSession(session(id: 'w1'));
    await emissions;
  });

  // ── Paged reads / windowed writes (chat message window) ────────────────

  test('loadRecentMessages returns the newest N, newest-first', () async {
    final base = DateTime(2026, 10, 6, 12);
    await repo.saveChatSession(session(messages: [
      for (var i = 0; i < 25; i++)
        message(
          id: 'm$i',
          text: 'msg $i',
          timestamp: base.add(Duration(minutes: i)),
        ),
    ]));

    final page = await repo.loadRecentMessages('peer-1', limit: 20);
    expect(page, hasLength(20));
    expect(page.first.text, 'msg 24');
    expect(page.last.text, 'msg 5');
  });

  test('loadMessagesBefore pages strictly older than the keyset cursor',
      () async {
    final base = DateTime(2026, 10, 6, 12);
    await repo.saveChatSession(session(messages: [
      message(
          id: 'm5',
          text: 'newest',
          timestamp: base.add(const Duration(minutes: 5))),
      message(
          id: 'm4',
          text: 'tie-b',
          timestamp: base.add(const Duration(minutes: 3))),
      message(
          id: 'm3',
          text: 'tie-a',
          timestamp: base.add(const Duration(minutes: 3))),
      message(id: 'm2', text: 'mid', timestamp: base),
      message(id: 'm1', text: 'oldest', timestamp: base),
    ]));

    // Store read order: m5, m4, m3, m2, m1 (identical timestamps by id DESC).
    final all = await repo.loadRecentMessages('peer-1', limit: 10);
    expect(all.map((m) => m.id).toList(), ['m5', 'm4', 'm3', 'm2', 'm1']);

    // Keyset page strictly older than m3: the same-timestamp m4 (larger id)
    // stays out; m2/m1 come in.
    final page = await repo.loadMessagesBefore(
      'peer-1',
      before: base.add(const Duration(minutes: 3)),
      beforeId: 'm3',
      limit: 2,
    );
    expect(page.map((m) => m.id).toList(), ['m2', 'm1']);

    // Legacy row without an id: timestamp-only comparison (<= cursor).
    final fallback = await repo.loadMessagesBefore(
      'peer-1',
      before: base.add(const Duration(minutes: 3)),
      limit: 10,
    );
    expect(fallback.map((m) => m.id).toList(), ['m4', 'm3', 'm2', 'm1']);
  });

  test('saveChatSessionWindow upserts the window without deleting older rows',
      () async {
    final base = DateTime(2026, 10, 6, 12);
    final all = [
      for (var i = 30; i >= 1; i--)
        message(
          id: 'm$i',
          text: 'msg $i',
          timestamp: base.add(Duration(minutes: i)),
        ),
    ];
    await repo.saveChatSession(session(messages: all));

    // A window save carrying only the newest three, with one row edited.
    await repo.saveChatSessionWindow(session(
      name: 'Redmi 2',
      messages: [
        all[0].copyWith(text: 'msg 30 (edited)'),
        all[1],
        all[2],
      ],
    ));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.name, 'Redmi 2');
    expect(loaded.messages, hasLength(30),
        reason: 'the unloaded part of the history must survive');
    expect(loaded.messages.first.text, 'msg 30 (edited)');
    expect(loaded.messages[1].id, 'm29');
  });

  test('deleteMessageRow removes one row; clearSessionMessages one session',
      () async {
    await repo.saveChatSession(session(id: 'a', messages: [
      message(id: 'a1'),
      message(id: 'a2', timestamp: DateTime(2026, 10, 6, 12, 5)),
    ]));
    await repo.saveChatSession(
        session(id: 'b', messages: [message(id: 'b1')]));

    await repo.deleteMessageRow('a1');
    var a = await repo.loadChatSession('a');
    expect(a!.messages.map((m) => m.id).toList(), ['a2']);

    await repo.clearSessionMessages('a');
    a = await repo.loadChatSession('a');
    expect(a!.messages, isEmpty);
    final b = await repo.loadChatSession('b');
    expect(b!.messages, hasLength(1), reason: 'other sessions are untouched');
  });

  test('hasMessageNear matches text+direction within the tolerance window',
      () async {
    final t = DateTime(2026, 10, 6, 12);
    await repo.saveChatSession(session(messages: [
      message(id: 'm1', text: 'hello', isSentByMe: false, timestamp: t),
    ]));

    expect(
        await repo.hasMessageNear('peer-1',
            text: 'hello',
            isSentByMe: false,
            timestamp: t.add(const Duration(seconds: 9))),
        isTrue);
    expect(
        await repo.hasMessageNear('peer-1',
            text: 'hello',
            isSentByMe: false,
            timestamp: t.add(const Duration(seconds: 11))),
        isFalse);
    expect(
        await repo.hasMessageNear('peer-1',
            text: 'hello', isSentByMe: true, timestamp: t),
        isFalse);
    expect(
        await repo.hasMessageNear('peer-1',
            text: 'other', isSentByMe: false, timestamp: t),
        isFalse);
    expect(
        await repo.hasMessageNear('peer-2',
            text: 'hello', isSentByMe: false, timestamp: t),
        isFalse);
  });

  test('meta reads return session rows without their messages', () async {
    await repo.saveChatSession(
        session(id: 'a', messages: [message(id: 'a1')]));

    final metas = await repo.getAllSessionsMeta();
    expect(metas.single.id, 'a');
    expect(metas.single.messages, isEmpty);

    final meta = await repo.loadSessionMeta('a');
    expect(meta!.name, 'Redmi');
    expect(meta.device['address'], 'AA:BB:CC:DD:EE:FF');
    expect(meta.messages, isEmpty);
    expect(await repo.loadSessionMeta('missing'), isNull);
  });

  test('per-transport addresses round-trip; legacy rows seed the map from '
      'the single stored address', () async {
    await repo.saveChatSession(session(
      transport: 'wfd',
      device: const {'name': 'Galaxy J7 Prime', 'address': '36:8a:7b:b4:5b:9e'},
      deviceAddresses: const {
        'wfd': '36:8a:7b:b4:5b:9e',
        'bt': '34:8A:7B:B4:5B:9D',
      },
    ));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.addressFor('bt'), '34:8A:7B:B4:5B:9D');
    expect(loaded.addressFor('wfd'), '36:8a:7b:b4:5b:9e');

    // A row written BEFORE the column existed (v4 format): the single
    // stored address serves as the entry for the session's transport.
    await (db.update(db.sessions)..where((t) => t.id.equals('peer-1')))
        .write(const SessionsCompanion(deviceAddresses: Value<String?>(null)));
    final legacy = await repo.loadChatSession('peer-1');
    expect(legacy!.addressFor('wfd'), '36:8a:7b:b4:5b:9e',
        reason: 'the legacy single address seeds its transport entry');
    expect(legacy.addressFor('bt'), isNull);
  });
}
