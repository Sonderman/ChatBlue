import 'dart:io';

import 'package:chatblue/core/hive/hive_registrar.g.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

/// Theme/locale provider contract: persisted values win on rebuild, writes
/// land in the settings box, and failures fall back to defaults.
void main() {
  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('chatblue_settings_test');
    Hive.init(tempDir.path);
    Hive.registerAdapters();
    await Hive.openBox('settings');
  });

  tearDownAll(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

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
    expect(Hive.box('settings').get('themeMode'), 'dark');

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
    expect(Hive.box('settings').get('locale'), 'tr_TR');

    final c2 = ProviderContainer();
    addTearDown(c2.dispose);
    expect(c2.read(localeProvider), const Locale('tr', 'TR'));
  });
}