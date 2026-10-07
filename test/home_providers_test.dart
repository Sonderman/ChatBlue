import 'dart:async';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/home_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Home list provider contract (drift): sessions sorted by updatedAt desc,
/// live re-emission on repository writes (save/delete), fail-open when no
/// database is provided.
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

  ChatSessionModel session(String id, DateTime updatedAt) => ChatSessionModel(
        id: id,
        name: id,
        createdAt: updatedAt,
        updatedAt: updatedAt,
        messages: const [],
        device: const {},
      );

  ProviderContainer container() => ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );

  /// Reads the first emitted list. NOTE: Riverpod 3 `read(provider.future)`
  /// does not start a StreamProvider's stream — a listener is required.
  Future<List<ChatSessionModel>> firstList(ProviderContainer c) async {
    final completer = Completer<List<ChatSessionModel>>();
    final sub = c.listen(homeSessionsProvider, (_, next) {
      final list = next.value;
      if (!completer.isCompleted && list != null) completer.complete(list);
    });
    final list = await completer.future.timeout(const Duration(seconds: 5));
    sub.close();
    return list;
  }

  Future<List<ChatSessionModel>> nextEmission(
    ProviderContainer c,
    bool Function(List<ChatSessionModel>) matches,
  ) {
    final completer = Completer<List<ChatSessionModel>>();
    final sub = c.listen(homeSessionsProvider, (_, next) {
      final list = next.value;
      if (!completer.isCompleted && list != null && matches(list)) {
        completer.complete(list);
      }
    });
    completer.future.then((_) => sub.close(), onError: (_) => sub.close());
    return completer.future.timeout(const Duration(seconds: 5));
  }

  test('homeSessionsProvider emits sessions sorted by updatedAt desc',
      () async {
    final c = container();
    addTearDown(c.dispose);
    await repo.saveChatSession(session('a', DateTime(2026, 10, 1)));
    await repo.saveChatSession(session('b', DateTime(2026, 10, 5)));
    await repo.saveChatSession(session('c', DateTime(2026, 10, 3)));

    final sessions = await firstList(c);
    expect(sessions.map((s) => s.id).toList(), ['b', 'c', 'a']);
  });

  test('re-emits when the repository writes (new session)', () async {
    final c = container();
    addTearDown(c.dispose);

    // One listener for the whole test: a canceled subscription ends the
    // provider's stream.
    final first = Completer<void>();
    final fresh = Completer<void>();
    final sub = c.listen(homeSessionsProvider, (_, next) {
      final v = next.value;
      if (v == null) return;
      if (!first.isCompleted) first.complete();
      if (v.any((s) => s.id == 'fresh') && !fresh.isCompleted) fresh.complete();
    });
    addTearDown(sub.close);

    await first.future.timeout(const Duration(seconds: 5));

    await repo.saveChatSession(session('fresh', DateTime(2026, 10, 9)));
    await fresh.future.timeout(const Duration(seconds: 8));

    // The emission carrying 'fresh' made it first (sorted by updatedAt desc).
    expect(c.read(homeSessionsProvider).value!.first.id, 'fresh');
  });

  test('deleteChatSessionProvider removes the session and the stream re-emits',
      () async {
    final c = container();
    addTearDown(c.dispose);
    await repo.saveChatSession(session('doomed', DateTime(2026, 10, 9, 12)));

    final emission =
        nextEmission(c, (list) => list.every((s) => s.id != 'doomed'));
    await pumpEventQueue(); // let the stream subscribe before the delete
    await c.read(deleteChatSessionProvider)(
      session('doomed', DateTime(2026, 10, 9, 12)),
    );

    final updated = await emission;
    expect(updated.map((s) => s.id), isNot(contains('doomed')));
    expect(await repo.loadChatSession('doomed'), isNull);
  });

  test('fail-open: provider renders an empty list without a database',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sessions = await firstList(c);
    expect(sessions, isEmpty);
  });
}
