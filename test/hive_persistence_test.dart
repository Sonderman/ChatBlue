import 'dart:io';

import 'package:chatblue/core/hive/hive_registrar.g.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Verifies the Hive persistence contract that HiveService relies on:
/// sessions are keyed by id and messages survive a box round-trip.
void main() {
  late Directory tempDir;

  // Hive's TypeAdapter registry is per-isolate and Hive.close() does NOT
  // clear it — registering in setUpAll runs exactly once.
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('chatblue_test');
    Hive.init(tempDir.path);
    Hive.registerAdapters();
  });

  tearDown(() async {
    await Hive.close();
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  test('chat session with messages persists and reloads', () async {
    final box = await Hive.openBox<ChatSessionModel>('test_sessions');

    final session = ChatSessionModel(
      id: 'device-1',
      name: 'Peer',
      createdAt: DateTime(2026, 10, 4, 9, 0),
      updatedAt: DateTime(2026, 10, 4, 9, 30),
      messages: [
        MessageModel(
          text: 'first',
          isSentByMe: true,
          timestamp: DateTime(2026, 10, 4, 9, 10),
        ),
        MessageModel(
          text: 'second',
          isSentByMe: false,
          timestamp: DateTime(2026, 10, 4, 9, 20),
          imagePath: '/tmp/incoming.jpg',
        ),
      ],
      device: {'name': 'Peer', 'address': 'device-1'},
    );

    await box.put(session.id, session);

    final loaded = box.get('device-1');
    expect(loaded, isNotNull);
    expect(loaded!.name, 'Peer');
    expect(loaded.messages, hasLength(2));
    expect(loaded.messages[0].text, 'first');
    expect(loaded.messages[1].imagePath, '/tmp/incoming.jpg');
    expect(loaded.messages[1].isSentByMe, false);
  });

  test('updating a session overwrites the stored value', () async {
    final box = await Hive.openBox<ChatSessionModel>('test_sessions');

    final session = ChatSessionModel(
      id: 'device-1',
      name: 'Peer',
      createdAt: DateTime(2026, 10, 4, 9, 0),
      updatedAt: DateTime(2026, 10, 4, 9, 0),
      messages: [],
      device: {},
    );
    await box.put(session.id, session);

    session.updatedAt = DateTime(2026, 10, 4, 10, 0);
    session.messages = [
      MessageModel(
        text: 'updated',
        isSentByMe: true,
        timestamp: DateTime(2026, 10, 4, 10, 0),
      ),
    ];
    await box.put(session.id, session);

    final loaded = box.get('device-1');
    expect(loaded!.updatedAt, DateTime(2026, 10, 4, 10, 0));
    expect(loaded.messages.single.text, 'updated');
  });

  test('deleting a session removes it from the box', () async {
    final box = await Hive.openBox<ChatSessionModel>('test_sessions');

    final session = ChatSessionModel(
      id: 'device-1',
      name: 'Peer',
      createdAt: DateTime(2026, 10, 4, 9, 0),
      updatedAt: DateTime(2026, 10, 4, 9, 0),
      messages: [],
      device: {},
    );
    await box.put(session.id, session);
    await box.delete(session.id);

    expect(box.get('device-1'), isNull);
  });
}