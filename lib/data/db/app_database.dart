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
/// [schemaVersion] 6: v3 is the first SHIPPED schema; v4 adds the messages
/// `delivery` column (outgoing delivery ticks); v5 adds the sessions
/// `device_addresses` column (per-transport peer addresses — Bluetooth MAC
/// / Wi‑Fi Direct p2p address — so the chat's transport picker can dial the
/// chosen channel directly); v6 adds the sessions `nickname` column
/// (user-chosen chat title — display-only, shown instead of the device
/// name while set). Every version from 3 on migrates stepwise and
/// PRESERVES data — a device upgrade must never lose chat history. Versions
/// 1–2 only ever existed on test devices via the abandoned
/// `migration/riverpod-drift-nearby` experiment (v2 added the sync-identity
/// columns); a pre-existing file at those versions is REBUILT from scratch
/// when opened instead — pre-release contents are disposable and the
/// rebuild clears `app_settings`.
@DriftDatabase(tables: [Sessions, Messages, AppSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Bump together with a migration step below on every schema change.
  @override
  int get schemaVersion => 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createMessageIndex();
        },
        // drift runs this for any pre-existing file whose version differs —
        // upgrades and downgrades alike (there is no separate handler).
        onUpgrade: (m, from, to) async {
          // Shipped schemas (v3+) migrate STEPWISE, preserving all data:
          // 3 → 4 adds the message `delivery` column; 4 → 5 adds the
          // sessions `device_addresses` column (existing rows keep their
          // single address — the repository treats it as the entry for the
          // session's transport); 5 → 6 adds the sessions `nickname` column
          // (existing rows read back null — no nickname set). Never rebuild
          // here — a shipped file carries real conversations.
          if (from >= 3) {
            if (from < 4) {
              await m.addColumn(messages, messages.delivery);
            }
            if (from < 5) {
              await m.addColumn(sessions, sessions.deviceAddresses);
            }
            if (from < 6) {
              await m.addColumn(sessions, sessions.nickname);
            }
            return;
          }
          // Pre-release files only (see class doc): wipe + recreate; the
          // Hive importer re-populates. No per-version diffing needed.
          await _dropAllTables();
          await m.createAll();
          await _createMessageIndex();
        },
        beforeOpen: (details) async {
          // Message rows cascade when a session is deleted.
          await customStatement('PRAGMA foreign_keys = ON');
          // Installs created before the paged reads get the timestamp index
          // here; idempotent (the create path builds both indexes).
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_messages_session_ts '
            'ON messages (session_id, timestamp)',
          );
        },
      );

  /// Session-scoped message reads: the windowed/paged loads order by
  /// timestamp (newest first) — the primary path; the seq index stays for
  /// the legacy full reads.
  Future<void> _createMessageIndex() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_session_seq '
      'ON messages (session_id, seq)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_messages_session_ts '
      'ON messages (session_id, timestamp)',
    );
  }

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
