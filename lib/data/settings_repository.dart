import 'package:chatblue/data/db/app_database.dart';
import 'package:drift/drift.dart';

/// drift-backed key/value store for app settings (theme mode, locale,
/// device id) — replaces the legacy `settings` Hive box (migration P2).
///
/// Reads are synchronous through a startup cache: `main()` loads every row
/// once before `runApp` (parity with the old synchronous box reads — no
/// theme/locale flicker on launch). Writes update the cache immediately and
/// persist with an upsert. Fail-open throughout: without an instance (or on
/// a database error) reads return null and consumers keep their defaults,
/// exactly like the old `_settingsBox()` null-path.
class SettingsRepository {
  SettingsRepository(this._db);

  /// Migration bridge, same pattern as `SessionRepository.instance`:
  /// `main()` assigns this once after opening the database; legacy static
  /// callers (DeviceIdService, the notifiers) read it directly.
  static SettingsRepository? instance;

  final AppDatabase _db;
  final Map<String, String> _cache = {};

  /// Loads every `app_settings` row into the cache (call once from `main()`
  /// before `runApp`). Fail-open: on error the cache stays empty.
  Future<void> load() async {
    try {
      final rows = await _db.select(_db.appSettings).get();
      _cache
        ..clear()
        ..addEntries(rows.map((r) => MapEntry(r.key, r.value)));
    } catch (_) {
      // Fail-open: settings read back as null → consumers use defaults.
    }
  }

  /// Synchronous read from the cache; null when unset or the store is down.
  String? getString(String key) => _cache[key];

  /// Updates the cache immediately, then persists the row (upsert). A
  /// failed write still leaves the cache updated for this run.
  Future<void> setString(String key, String value) async {
    _cache[key] = value;
    try {
      await _db.into(_db.appSettings).insert(
            AppSettingsCompanion.insert(key: key, value: value),
            mode: InsertMode.insertOrReplace,
          );
    } catch (_) {
      // Fail-open: the cache keeps this run consistent.
    }
  }

  /// Writes several keys in ONE transaction (used by the one-time settings
  /// importer, which includes its done-flag so a crash rolls both back
  /// together). The cache is updated regardless of the transaction outcome.
  Future<void> setAll(Map<String, String> values) async {
    _cache.addAll(values);
    try {
      await _db.transaction(() async {
        for (final entry in values.entries) {
          await _db.into(_db.appSettings).insert(
                AppSettingsCompanion.insert(
                    key: entry.key, value: entry.value),
                mode: InsertMode.insertOrReplace,
              );
        }
      });
    } catch (_) {
      // Fail-open: the importer flag did not land → next launch retries.
    }
  }
}
