import 'dart:convert';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

/// drift-backed chat storage — replaced the legacy Hive `chat_sessions` box
/// in the migration (P1); Hive itself was removed in P3.
///
/// The API mirrors the old Hive service so call sites switch over with
/// minimal churn. Message reads return the NEWEST-first order (the in-memory
/// list contract everywhere), ordered by `timestamp DESC, id DESC` — the id
/// is the deterministic, pagination-safe tiebreak for identical timestamps.
/// The `seq` column is still written for schema compatibility but is no
/// longer authoritative: windowed upserts cannot maintain global positions.
///
/// Full-state writes ([writeSession]/[saveChatSession] — the peer-merge
/// absorb path and the tests) keep the legacy "the session object is the
/// full state" semantics. The chat controller's regular saves use the
/// windowed upsert ([saveChatSessionWindow]) instead: with paged loading the
/// in-memory list only holds the newest window, and a delete-all rewrite
/// would drop the unloaded part of the history.
class SessionRepository {
  SessionRepository(this._db);

  final AppDatabase _db;

  static const _uuid = Uuid();

  // ---------------------------------------------------------------- reads

  /// All sessions sorted by `updatedAt` descending — the exact order the
  /// Hive service returned. Optionally filtered to a single [chatID].
  Future<List<ChatSessionModel>> getAllChatSessions({String? chatID}) async {
    final query = _db.select(_db.sessions)
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);
    if (chatID != null) {
      query.where((t) => t.id.equals(chatID));
    }
    return _sessionsWithMessages(await query.get());
  }

  /// Session rows WITHOUT their messages, newest-updated first: the cheap
  /// identity search the chat's peer-merge paths use (a matched session's
  /// full messages are loaded on demand, only when it is actually merged).
  Future<List<ChatSessionModel>> getAllSessionsMeta() async {
    final rows = await (_db.select(_db.sessions)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .get();
    return [for (final row in rows) _sessionFromRow(row, const [])];
  }

  /// Reactive variant of [getAllChatSessions] (same order): the stream
  /// re-emits whenever the `sessions` table changes. Every write path in
  /// the app upserts the session row (updatedAt/messages) on each change,
  /// so message traffic reaches the home list through this stream too.
  Stream<List<ChatSessionModel>> watchSessions() {
    return (_db.select(_db.sessions)
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
        .watch()
        .asyncMap(_sessionsWithMessages);
  }

  /// Maps session rows to models, attaching each session's messages (one
  /// message query, grouped by session; newest-first per session).
  Future<List<ChatSessionModel>> _sessionsWithMessages(
      List<SessionRow> sessionRows) async {
    if (sessionRows.isEmpty) return const [];

    final messageRows = await (_db.select(_db.messages)
          ..orderBy([
            (t) => OrderingTerm.desc(t.timestamp),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    final grouped = <String, List<MessageModel>>{};
    for (final row in messageRows) {
      grouped.putIfAbsent(row.sessionId, () => []).add(_messageFromRow(row));
    }

    return [
      for (final row in sessionRows)
        _sessionFromRow(row, grouped[row.id] ?? const []),
    ];
  }

  /// Session row WITHOUT its messages — the chat-open metadata read (the
  /// visible message window is loaded separately via [loadRecentMessages]).
  Future<ChatSessionModel?> loadSessionMeta(String id) async {
    final row = await (_db.select(_db.sessions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;
    return _sessionFromRow(row, const []);
  }

  Future<ChatSessionModel?> loadChatSession(String id) async {
    final row = await (_db.select(_db.sessions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;

    final messageRows = await (_db.select(_db.messages)
          ..where((t) => t.sessionId.equals(id))
          ..orderBy([
            (t) => OrderingTerm.desc(t.timestamp),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
    return _sessionFromRow(row, messageRows.map(_messageFromRow).toList());
  }

  /// The newest [limit] messages of a session, newest-first: the chat's
  /// visible window (the "+1 overfetch tells whether older history exists"
  /// probe lives in the caller).
  Future<List<MessageModel>> loadRecentMessages(
    String sessionId, {
    required int limit,
  }) async {
    final rows = await (_db.select(_db.messages)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.timestamp),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
    return rows.map(_messageFromRow).toList();
  }

  /// Up to [limit] messages strictly OLDER than the [before]/[beforeId]
  /// keyset cursor (newest-first) — one older page for the windowed chat.
  /// The comparison matches the read order exactly (`timestamp DESC, id
  /// DESC`), so pages can neither skip nor repeat rows. [beforeId] null (a
  /// legacy row without an id) falls back to a timestamp-only comparison.
  Future<List<MessageModel>> loadMessagesBefore(
    String sessionId, {
    required DateTime before,
    String? beforeId,
    required int limit,
  }) async {
    final ms = before.millisecondsSinceEpoch;
    final rows = await (_db.select(_db.messages)
          ..where((t) {
            if (beforeId == null || beforeId.isEmpty) {
              return t.sessionId.equals(sessionId) &
                  t.timestamp.isSmallerOrEqualValue(ms);
            }
            return t.sessionId.equals(sessionId) &
                (t.timestamp.isSmallerThanValue(ms) |
                    (t.timestamp.isBiggerOrEqualValue(ms) &
                        t.timestamp.isSmallerOrEqualValue(ms) &
                        t.id.isSmallerThanValue(beforeId)));
          })
          ..orderBy([
            (t) => OrderingTerm.desc(t.timestamp),
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(limit))
        .get();
    return rows.map(_messageFromRow).toList();
  }

  /// Whether a message with this text, direction and an (almost) identical
  /// timestamp already exists in the session — one indexed existence check
  /// used by the history sync: with paged loading the in-memory window may
  /// not cover the whole history, so a re-served message could sit BELOW it
  /// and would be integrated a second time (duplicate row).
  Future<bool> hasMessageNear(
    String sessionId, {
    required String text,
    required bool isSentByMe,
    required DateTime timestamp,
    Duration tolerance = const Duration(seconds: 10),
  }) async {
    final lower = timestamp.subtract(tolerance).millisecondsSinceEpoch;
    final upper = timestamp.add(tolerance).millisecondsSinceEpoch;
    final query = _db.select(_db.messages)
      ..where((t) =>
          t.sessionId.equals(sessionId) &
          t.content.equals(text) &
          t.isSentByMe.equals(isSentByMe) &
          t.timestamp.isBiggerOrEqualValue(lower) &
          t.timestamp.isSmallerOrEqualValue(upper))
      ..limit(1);
    return (await query.get()).isNotEmpty;
  }

  /// Every message across all sessions that still references a local media
  /// file — the cache cleaner's work list (Settings → Clear cache).
  Future<List<MessageModel>> messagesWithLocalMedia() async {
    final rows = await (_db.select(_db.messages)
          ..where((t) => t.imagePath.isNotNull()))
        .get();
    return rows.map(_messageFromRow).toList();
  }

  // --------------------------------------------------------------- writes

  /// Persists the full session state (row + message list) in one
  /// transaction — the legacy full-rewrite semantics ([writeSession]).
  /// Used by the peer-merge absorb path and the tests; the chat's regular
  /// saves go through [saveChatSessionWindow] instead.
  Future<void> saveChatSession(ChatSessionModel session) =>
      _db.transaction(() => writeSession(session));

  /// The paged-chat save: upserts the session row and ONLY the messages it
  /// carries (the loaded window) — nothing is deleted, so the unloaded part
  /// of the history stays intact. Removals run through the explicit
  /// [deleteMessageRow]/[clearSessionMessages] instead.
  Future<void> saveChatSessionWindow(ChatSessionModel session) =>
      _db.transaction(() async {
        await _db
            .into(_db.sessions)
            .insert(_sessionCompanion(session),
                onConflict: DoUpdate((_) => _sessionCompanion(session)));

        final messageCompanions = <MessagesCompanion>[
          for (var i = 0; i < session.messages.length; i++)
            _messageCompanion(session.messages[i], session.id, i),
        ];
        if (messageCompanions.isNotEmpty) {
          await _db.batch(
            (b) => b
                .insertAllOnConflictUpdate(_db.messages, messageCompanions),
          );
        }
      });

  /// Writes the session row and its full message list. The caller wraps this
  /// in a transaction: [saveChatSession] for a single session, bulk callers
  /// open their own transaction.
  Future<void> writeSession(ChatSessionModel session) async {
    await _db
        .into(_db.sessions)
        .insert(_sessionCompanion(session),
            onConflict: DoUpdate((_) => _sessionCompanion(session)));

    final messageCompanions = <MessagesCompanion>[
      for (var i = 0; i < session.messages.length; i++)
        _messageCompanion(session.messages[i], session.id, i),
    ];

    await _db.batch((b) {
      // The in-memory list is the full state for this session: rewrite it.
      b.deleteWhere(_db.messages, (t) => t.sessionId.equals(session.id));
      if (messageCompanions.isNotEmpty) {
        b.insertAllOnConflictUpdate(_db.messages, messageCompanions);
      }
    });
  }

  Future<void> deleteChatSession(String id) async {
    await (_db.delete(_db.sessions)..where((t) => t.id.equals(id))).go();
  }

  /// Removes a single message row — the chat's explicit delete (windowed
  /// saves can no longer drop messages implicitly).
  Future<void> deleteMessageRow(String id) async {
    await (_db.delete(_db.messages)..where((t) => t.id.equals(id))).go();
  }

  /// Removes every message of a session — the chat's clear-conversation
  /// (windowed saves can no longer drop messages implicitly).
  Future<void> clearSessionMessages(String sessionId) async {
    await (_db.delete(_db.messages)
          ..where((t) => t.sessionId.equals(sessionId)))
        .go();
  }

  /// Turns media messages into deferred-download placeholders: drops the
  /// local file reference, records the byte size so the bubble can re-fetch
  /// the file from the peer, and clears any stale in-transfer flag. One
  /// transaction for the batch — the cache cleaner resets every local
  /// media row in a single pass.
  Future<void> markMediaAsRemote(List<({String id, int size})> resets) =>
      _db.transaction(() async {
        for (final r in resets) {
          await (_db.update(_db.messages)..where((t) => t.id.equals(r.id)))
              .write(
            MessagesCompanion(
              imagePath: const Value<String?>(null),
              remoteMediaSize: Value(r.size),
              isTransferring: const Value(false),
            ),
          );
        }
      });

  /// Utility parity with the old service (debug/QA resets).
  Future<void> clearAllChatSessions() async {
    await _db.delete(_db.messages).go();
    await _db.delete(_db.sessions).go();
  }

  // --------------------------------------------------------------- mapping

  SessionsCompanion _sessionCompanion(ChatSessionModel s) => SessionsCompanion(
        id: Value(s.id),
        name: Value(s.name),
        createdAt: Value(s.createdAt),
        updatedAt: Value(s.updatedAt),
        transport: Value(s.transport),
        deviceName: Value(s.device['name']?.toString()),
        deviceAddress: Value(s.device['address']?.toString()),
        deviceAddresses: Value(
          s.deviceAddresses.isEmpty ? null : jsonEncode(s.deviceAddresses),
        ),
      );

  MessagesCompanion _messageCompanion(
      MessageModel m, String sessionId, int seq) {
    final rawId = m.id;
    return MessagesCompanion(
      // Legacy records may lack a message id; the PK needs one. The in-memory
      // controller backfills ids on load, so this is a safety net only.
      id: Value((rawId == null || rawId.isEmpty) ? _uuid.v4() : rawId),
      sessionId: Value(sessionId),
      content: Value(m.text),
      isSentByMe: Value(m.isSentByMe),
      timestamp: Value(m.timestamp),
      seq: Value(seq),
      imagePath: Value(m.imagePath),
      remoteMediaSize: Value(m.remoteMediaSize),
      transferKind: Value(m.transferKind),
      isTransferring: Value(m.isTransferring),
      transferCurrent: Value(m.transferCurrent),
      transferTotal: Value(m.transferTotal),
      delivery: Value(m.delivery),
    );
  }

  ChatSessionModel _sessionFromRow(
          SessionRow row, List<MessageModel> messages) =>
      ChatSessionModel(
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        messages: messages,
        device: {
          'name': row.deviceName,
          'address': row.deviceAddress,
        },
        transport: row.transport,
        deviceAddresses: _decodeAddresses(row),
      );

  /// Per-transport addresses of a session row: the stored JSON map, with
  /// the legacy single [SessionRow.deviceAddress] seeded as the entry for
  /// [SessionRow.transport] when missing (rows written before the column
  /// existed — and the steady-state mirror the write path keeps).
  static Map<String, String> _decodeAddresses(SessionRow row) {
    final map = <String, String>{};
    final raw = row.deviceAddresses;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is String && v.isNotEmpty) map[e.key.toString()] = v;
          }
        }
      } catch (_) {
        // Malformed JSON (hand-edited file): fall through to the legacy
        // seed — one bad row must not break every read.
      }
    }
    final kind = row.transport;
    final legacy = row.deviceAddress;
    if (kind != null && kind.isNotEmpty && legacy != null && legacy.isNotEmpty) {
      map.putIfAbsent(kind, () => legacy);
    }
    return map;
  }

  MessageModel _messageFromRow(MessageRow row) => MessageModel(
        id: row.id,
        text: row.content,
        isSentByMe: row.isSentByMe,
        timestamp: row.timestamp,
        imagePath: row.imagePath,
        remoteMediaSize: row.remoteMediaSize,
        isTransferring: row.isTransferring,
        transferCurrent: row.transferCurrent,
        transferTotal: row.transferTotal,
        transferKind: row.transferKind,
        delivery: row.delivery,
      );
}
