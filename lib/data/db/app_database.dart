import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import 'tables.dart';

part 'app_database.g.dart';

/// SQLite (drift) store for chat data and app settings — replaced the legacy
/// Hive `chat_sessions`/`settings` boxes (migration P1/P2; the Hive code and
/// its one-time importers were removed in P3). The schema mirrors the old
/// Hive layout (see tables.dart).
///
/// [schemaVersion] 3: versions 1–2 only ever existed on test devices via the
/// abandoned `migration/riverpod-drift-nearby` experiment (v2 added the
/// sync-identity columns). A pre-existing file at ANY other version is
/// REBUILT from scratch when opened instead of migrated — pre-release
/// contents are disposable (test devices re-import through the migration
/// builds when needed) and the rebuild clears `app_settings`. Replace the
/// rebuild with real, data-preserving steps before a shipped schema bumps
/// this.
@DriftDatabase(tables: [Sessions, Messages, AppSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Bump together with a migration step below on every schema change.
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createMessageIndex();
        },
        // drift runs this for any pre-existing file whose version differs —
        // upgrades and downgrades alike (there is no separate handler).
        onUpgrade: (m, from, to) async {
          // Pre-release files only (see class doc): wipe + recreate; the
          // Hive importer re-populates. No per-version diffing needed.
          await _dropAllTables();
          await m.createAll();
          await _createMessageIndex();
        },
        beforeOpen: (details) async {
          // Message rows cascade when a session is deleted.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Session-scoped message reads filter by FK and read in seq order.
  Future<void> _createMessageIndex() => customStatement(
        'CREATE INDEX IF NOT EXISTS idx_messages_session_seq '
        'ON messages (session_id, seq)',
      );

  /// Drops every table this store ever created (children first; the FK
  /// pragma is off during migrations, and `IF EXISTS` keeps this safe on
  /// partially built files). `createAll` re-creates the current schema.
  Future<void> _dropAllTables() async {
    for (final table in const ['messages', 'sessions', 'app_settings']) {
      await customStatement('DROP TABLE IF EXISTS $table');
    }
  }

  /// Opens the app database file from the documents directory (the same
  /// directory the legacy Hive boxes live in). The engine runs on a
  /// background isolate so UI never stalls on disk I/O.
  static Future<AppDatabase> open() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/chatblue.sqlite');
    return AppDatabase(NativeDatabase.createInBackground(file));
  }
}
