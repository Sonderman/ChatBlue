import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

/// drift-backed chat storage — replaced the legacy Hive `chat_sessions` box
/// in the migration (P1); Hive itself was removed in P3.
///
/// The API mirrors the old Hive service so call sites switch over with
/// minimal churn. Writes keep the legacy "the session object is the full
/// state" semantics (messages no longer present in the list are dropped),
/// and display order is preserved through the `seq` column. Finer-grained,
/// reactive queries arrive in later phases.
class SessionRepository {
  SessionRepository(this._db);

  /// Migration bridge: legacy GetX screens cannot take providers yet, so
  /// `main()` assigns this once after opening the database. New Riverpod
  /// code should read `sessionRepositoryProvider` instead.
  static late SessionRepository instance;

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
  /// message query, grouped by session; ordering by seq keeps each
  /// session's message order intact after grouping).
  Future<List<ChatSessionModel>> _sessionsWithMessages(
      List<SessionRow> sessionRows) async {
    if (sessionRows.isEmpty) return const [];

    final messageRows = await (_db.select(_db.messages)
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
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

  Future<ChatSessionModel?> loadChatSession(String id) async {
    final row = await (_db.select(_db.sessions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return null;

    final messageRows = await (_db.select(_db.messages)
          ..where((t) => t.sessionId.equals(id))
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .get();
    return _sessionFromRow(row, messageRows.map(_messageFromRow).toList());
  }

  // --------------------------------------------------------------- writes

  /// Persists the full session state (row + message list) in one
  /// transaction — same semantics as the old `box.put(session.id, session)`.
  Future<void> saveChatSession(ChatSessionModel session) =>
      _db.transaction(() => writeSession(session));

  /// Writes the session row and its full message list. The caller wraps this
  /// in a transaction: [saveChatSession] for a single session, the Hive
  /// importer for a whole batch.
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
      );

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
      );
}
