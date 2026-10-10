import 'dart:io';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Pre-release drift files (written by the abandoned migration experiment or
/// its first import build) must not brick the store: [AppDatabase] REBUILDS
/// any file at a different schema version and clears the importer flag, so
/// every app_settings row is cleared, stale flags/values never survive.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chatblue_rebuild');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // A leaked open handle during a failed assertion is fine here.
    }
  });

  /// Hand-built legacy file: the shared table shapes, one stale
  /// session/message pair and the importer flag set. v2 files additionally
  /// carry the experiment's extra identity columns.
  File legacyFile({required int version, bool withV2Columns = false}) {
    final file = File('${dir.path}/legacy_v$version.sqlite');
    final extra = withV2Columns ? ', origin TEXT, origin_seq INTEGER' : '';
    // v4 added the message `delivery` column; later versions carry it too.
    final delivery = version >= 4 ? ', delivery TEXT' : '';
    final raw = sqlite3.open(file.path);
    raw.execute('''
      CREATE TABLE sessions (
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        transport TEXT,
        device_name TEXT,
        device_address TEXT,
        PRIMARY KEY (id)
      )
    ''');
    raw.execute('''
      CREATE TABLE messages (
        id TEXT NOT NULL,
        session_id TEXT NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
        content TEXT NOT NULL,
        is_sent_by_me INTEGER NOT NULL,
        timestamp INTEGER NOT NULL,
        seq INTEGER NOT NULL,
        image_path TEXT,
        remote_media_size INTEGER,
        transfer_kind TEXT,
        is_transferring INTEGER NOT NULL DEFAULT 0,
        transfer_current INTEGER,
        transfer_total INTEGER$extra$delivery,
        PRIMARY KEY (id)
      )
    ''');
    raw.execute('''
      CREATE TABLE app_settings (
        key TEXT NOT NULL,
        value TEXT NOT NULL,
        PRIMARY KEY (key)
      )
    ''');
    raw.execute(
      "INSERT INTO sessions (id, name, created_at, updated_at) "
      "VALUES ('stale', 'stale', 1, 2)",
    );
    raw.execute(
      "INSERT INTO messages (id, session_id, content, is_sent_by_me, "
      "timestamp, seq) VALUES ('m1', 'stale', 'old', 1, 3, 0)",
    );
    raw.execute(
      "INSERT INTO app_settings (key, value) "
      "VALUES ('hive_import_done', 'true')",
    );
    raw.execute('PRAGMA user_version = $version');
    raw.dispose();
    return file;
  }

  Future<void> expectRebuilt(File file) async {
    final db = AppDatabase(NativeDatabase(file));
    // First query opens the file → the rebuild migration runs.
    expect(await db.select(db.sessions).get(), isEmpty);
    expect(await db.select(db.messages).get(), isEmpty);
    // Every app_settings row is cleared (stale flags/values never survive).
    expect(await db.select(db.appSettings).get(), isEmpty);

    // The rebuilt schema is fully usable: repository round-trip + index.
    final repo = SessionRepository(db);
    await repo.saveChatSession(ChatSessionModel(
      id: 'fresh',
      name: 'fresh',
      createdAt: DateTime(2026, 10, 7),
      updatedAt: DateTime(2026, 10, 7),
      messages: const [],
      device: const {},
    ));
    expect(await repo.loadChatSession('fresh'), isNotNull);
    final index = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type = 'index' AND name = 'idx_messages_session_seq'",
        )
        .getSingleOrNull();
    expect(index, isNotNull);

    await db.close();
  }

  test('rebuilds a v2 file left behind by the abandoned experiment',
      () async {
    await expectRebuilt(legacyFile(version: 2, withV2Columns: true));
  });

  test('rebuilds a v1 file from the first import build', () async {
    await expectRebuilt(legacyFile(version: 1));
  });

  test(
      'migrates a shipped v3 file in place: data preserved, delivery column added',
      () async {
    final file = legacyFile(version: 3);
    final db = AppDatabase(NativeDatabase(file));

    // No rebuild: every pre-existing row survives the upgrade — a shipped
    // file carries real conversations.
    expect(await db.select(db.sessions).get(), hasLength(1));
    expect(await db.select(db.appSettings).get(), hasLength(1));
    final rows = await db.select(db.messages).get();
    expect(rows, hasLength(1));
    expect(rows.single.content, 'old');
    // The new column exists and migrated rows read back as null (no ticks
    // for pre-existing messages — the UI falls back to a single tick).
    expect(rows.single.delivery, isNull);
    // The new column is writable through the generated companion.
    await (db.update(db.messages)..where((t) => t.id.equals('m1')))
        .write(const MessagesCompanion(delivery: Value('sent')));
    expect((await db.select(db.messages).getSingle()).delivery, 'sent');

    await db.close();
  });

  test(
      'migrates a shipped v4 file in place: data preserved, the '
      'device_addresses column added', () async {
    final file = legacyFile(version: 4);
    final db = AppDatabase(NativeDatabase(file));

    // No rebuild: every pre-existing row survives the upgrade.
    expect(await db.select(db.sessions).get(), hasLength(1));
    final rows = await db.select(db.messages).get();
    expect(rows, hasLength(1));
    expect(rows.single.content, 'old');
    expect(rows.single.delivery, isNull);

    // The new column exists and is writable through the generated
    // companion; migrated rows read back as NULL (the repository seeds the
    // map from the legacy single address at read time).
    expect((await db.select(db.sessions).getSingle()).deviceAddresses, isNull);
    await (db.update(db.sessions)..where((t) => t.id.equals('stale')))
        .write(const SessionsCompanion(
      deviceAddresses: Value('{"bt":"AA:BB:CC:DD:EE:FF"}'),
    ));
    expect(
      (await db.select(db.sessions).getSingle()).deviceAddresses,
      '{"bt":"AA:BB:CC:DD:EE:FF"}',
    );

    await db.close();
  });
}
