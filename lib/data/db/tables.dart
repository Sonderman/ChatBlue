import 'package:drift/drift.dart';

/// DateTime <-> milliseconds-since-epoch converter for drift columns.
///
/// drift's built-in `dateTime()` storage truncates to whole seconds; message
/// ordering, dedup windows and the sync protocol need millisecond fidelity,
/// so every timestamp column stores milliseconds as an INTEGER through this
/// converter.
class DateTimeMillisConverter extends TypeConverter<DateTime, int> {
  const DateTimeMillisConverter();

  @override
  DateTime fromSql(int fromDb) => DateTime.fromMillisecondsSinceEpoch(fromDb);

  @override
  int toSql(DateTime value) => value.millisecondsSinceEpoch;
}

/// Chat session rows — 1:1 mirror of the legacy Hive `ChatSessionModel`.
@DataClassName('SessionRow')
class Sessions extends Table {
  /// Session key: peer uid (Wi-Fi/Nearby) or Bluetooth MAC (legacy keys).
  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get createdAt => integer().map(const DateTimeMillisConverter())();

  IntColumn get updatedAt => integer().map(const DateTimeMillisConverter())();

  /// Channel the chat was created over: 'bt' / 'wfd' (null on sessions
  /// persisted before the field existed — see ChatSessionModel.transportKind).
  TextColumn get transport => text().nullable()();

  TextColumn get deviceName => text().nullable()();

  TextColumn get deviceAddress => text().nullable()();

  /// Per-transport peer addresses as a JSON map (e.g.
  /// {"bt":"34:8A:7B:B4:5B:9D","wfd":"36:8a:7b:b4:5b:9e"}): the same peer
  /// has a different address per radio, and the chat's transport picker
  /// dials the target transport with ITS entry. Null on rows written before
  /// the column existed — the single [deviceAddress] then serves as the
  /// entry for [transport] (see SessionRepository._decodeAddresses).
  TextColumn get deviceAddresses => text().nullable()();

  /// User-chosen display name for the chat (home list long-press rename):
  /// shown instead of [name] wherever the session title renders. Null/empty
  /// = not set; the stored [name] keeps updating from the live peer
  /// identity underneath, so clearing the nickname falls back to the
  /// current device name (see ChatSessionModel.title).
  TextColumn get nickname => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Message rows — 1:1 mirror of the legacy Hive `MessageModel`.
@DataClassName('MessageRow')
class Messages extends Table {
  TextColumn get id => text()();

  TextColumn get sessionId =>
      text().references(Sessions, #id, onDelete: KeyAction.cascade)();

  /// Message body. (Named `content` because a column named `text` would
  /// shadow drift's inherited `text()` column-type helper in this class and
  /// break every `text()` call in the table.)
  TextColumn get content => text()();

  BoolColumn get isSentByMe => boolean()();

  IntColumn get timestamp => integer().map(const DateTimeMillisConverter())();

  /// Append order within its session (0-based on every write): mirrors the
  /// old Hive list order and keeps identical-timestamp messages stable.
  IntColumn get seq => integer()();

  TextColumn get imagePath => text().nullable()();

  /// Byte size of media that still lives on the peer (deferred download);
  /// null for plain messages and once the file is local.
  IntColumn get remoteMediaSize => integer().nullable()();

  /// 'bytes' | 'text' | 'audio' — see MessageModel.
  TextColumn get transferKind => text().nullable()();

  BoolColumn get isTransferring =>
      boolean().withDefault(const Constant(false))();

  IntColumn get transferCurrent => integer().nullable()();

  IntColumn get transferTotal => integer().nullable()();

  /// Delivery state of an OUTGOING message (null for incoming messages and
  /// pre-tick legacy rows): 'pending' | 'sent' | 'delivered' | 'failed' —
  /// see MessageModel.delivery / the chat controller.
  TextColumn get delivery => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Small key/value store for app-level flags (migration bookkeeping now;
/// the settings boxes move here in the cleanup phase).
@DataClassName('AppSettingRow')
class AppSettings extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
