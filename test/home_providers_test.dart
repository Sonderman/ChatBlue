import 'dart:async';
import 'dart:io';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:chatblue/providers/home_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Home list provider contract: sessions sorted by updatedAt desc, live
/// re-emission on box changes (put/delete), fail-open when Hive is absent,
/// and the delete action feeding the same stream.
void main() {
  late Directory tempDir;
  late HiveService service;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('chatblue_home_test');
    service = await HiveService().init(directoryPath: tempDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
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
        overrides: [hiveServiceProvider.overrideWithValue(service)],
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

  test('homeSessionsProvider emits sessions sorted by updatedAt desc', () async {
    final c = container();
    addTearDown(c.dispose);
    await service.chatSessionsBox.put('a', session('a', DateTime(2026, 10, 1)));
    await service.chatSessionsBox.put('b', session('b', DateTime(2026, 10, 5)));
    await service.chatSessionsBox.put('c', session('c', DateTime(2026, 10, 3)));

    final sessions = await firstList(c);
    expect(sessions.map((s) => s.id).toList(), ['b', 'c', 'a']);
  });

  test('re-emits when the box changes (new session)', () async {
    final c = container();
    addTearDown(c.dispose);

    // One listener for the whole test: a canceled subscription kills the
    // async* stream, so never listen-close-then-listen again.
    final first = Completer<void>();
    final fresh = Completer<void>();
    final sub = c.listen(homeSessionsProvider, (_, next) {
      final v = next.value;
      if (v == null) return;
      if (!first.isCompleted) first.complete();
      if (v.any((s) => s.id == 'fresh') && !fresh.isCompleted) fresh.complete();
    });
    addTearDown(sub.close);

    await first.future.timeout(const Duration(seconds: 3));
    // Let the async* generator reach its `await for` subscription before
    // the put — a broadcast watch event emitted before subscription is
    // lost (no buffering).
    await pumpEventQueue();

    await service.chatSessionsBox
        .put('fresh', session('fresh', DateTime(2026, 10, 9)));
    await fresh.future.timeout(const Duration(seconds: 8));

    // The emission carrying 'fresh' made it first (sorted by updatedAt desc).
    expect(c.read(homeSessionsProvider).value!.first.id, 'fresh');
  });

  test('deleteChatSessionProvider removes the session and the stream re-emits',
      () async {
    final c = container();
    addTearDown(c.dispose);
    await service.chatSessionsBox.put('doomed', session('doomed', DateTime(2026, 10, 9, 12)));

    final emission = nextEmission(c, (list) => list.every((s) => s.id != 'doomed'));
    await pumpEventQueue(); // let the stream subscribe before the delete
    await c.read(deleteChatSessionProvider)(ChatSessionModel(
      id: 'doomed',
      name: 'doomed',
      createdAt: DateTime(2026, 10, 9),
      updatedAt: DateTime(2026, 10, 9, 12),
      messages: const [],
      device: const {},
    ));

    final updated = await emission;
    expect(updated.map((s) => s.id), isNot(contains('doomed')));
    final stored = service.chatSessionsBox.get('doomed');
    expect(stored, isNull);
  });

  test('fail-open: provider renders an empty list without a Hive service',
      () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sessions = await firstList(c);
    expect(sessions, isEmpty);
  });
}