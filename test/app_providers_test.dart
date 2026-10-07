import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Theme/locale provider contract on the drift settings store: persisted
/// values win on rebuild (cache re-loaded from the database), writes land
/// in `app_settings`, defaults hold when nothing is saved, and a missing
/// store falls back without throwing.
void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    SettingsRepository.instance = SettingsRepository(db);
    await SettingsRepository.instance!.load();
  });

  tearDown(() async {
    SettingsRepository.instance = null;
    await db.close();
  });

  Future<String?> readRow(String key) async {
    final row = await (db.select(db.appSettings)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  /// Simulates a fresh launch: a new repository whose cache is loaded from
  /// the database (nothing carried over in memory).
  Future<void> relaunch() async {
    SettingsRepository.instance = SettingsRepository(db);
    await SettingsRepository.instance!.load();
  }

  test('themeModeProvider defaults to system when nothing is saved', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(themeModeProvider), ThemeMode.system);
  });

  test('setMode updates state, persists, and survives a rebuild', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(themeModeProvider.notifier).setMode(ThemeMode.dark);
    expect(c.read(themeModeProvider), ThemeMode.dark);
    expect(await readRow('themeMode'), 'dark');

    await relaunch();
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(themeModeProvider), ThemeMode.dark);
  });

  test('localeProvider defaults to the device language (en in tests)', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(localeProvider), const Locale('en', 'US'));
  });

  test('setLocale updates state, persists, and survives a rebuild', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(localeProvider.notifier).setLocale(const Locale('tr', 'TR'));
    expect(c.read(localeProvider), const Locale('tr', 'TR'));
    expect(await readRow('locale'), 'tr_TR');

    await relaunch();
    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(localeProvider), const Locale('tr', 'TR'));
  });

  test('no settings store: providers fall back to defaults', () {
    SettingsRepository.instance = null;
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(themeModeProvider), ThemeMode.system);
    expect(c.read(localeProvider), const Locale('en', 'US'));
  });
}
