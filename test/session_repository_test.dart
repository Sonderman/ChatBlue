import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
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
  }) =>
      ChatSessionModel(
        id: id,
        name: name,
        createdAt: createdAt ?? DateTime(2026, 10, 6, 10),
        updatedAt: updatedAt ?? DateTime(2026, 10, 6, 11),
        messages: messages ?? [message()],
        device: device ?? {'name': name, 'address': 'AA:BB:CC:DD:EE:FF'},
        transport: transport,
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

  test('message order survives identical timestamps', () async {
    final t = DateTime(2026, 10, 6, 12);
    await repo.saveChatSession(session(messages: [
      message(id: 'm1', text: 'first', timestamp: t),
      message(id: 'm2', text: 'second', timestamp: t),
      message(id: 'm3', text: 'third', timestamp: t),
    ]));

    final loaded = await repo.loadChatSession('peer-1');
    expect(loaded!.messages.map((m) => m.text).toList(),
        ['first', 'second', 'third']);
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
}
