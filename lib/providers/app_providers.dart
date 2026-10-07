import 'dart:async';

import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';

/// Global navigator key — controller'lar context'siz navigasyon için kullanır
/// (GetX `Get.to` / `Get.arguments` yerine). `main.dart`'taki MaterialApp'e
/// (F4 sonrası) ve mevcut GetMaterialApp'e bağlanır.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global scaffold messenger key — controller'lar context'siz snackbar
/// gösterimi için (GetX `Get.snackbar` yerine).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Root ProviderContainer used by the GetX→Riverpod bridge
/// (`lib/controllers/transport_adapter.dart`) — GetX code has no BuildContext
/// to reach providers. Attached in `main()` next to the
/// `UncontrolledProviderScope`. Tests use their own containers and never
/// touch this.
ProviderContainer? rootProviderContainer;

/// App-wide theme mode — persisted in the drift `app_settings` store via
/// [SettingsRepository] (fail-open: system). GetMaterialApp consumes this
/// via `ref.watch` (replaces ThemeService/Get.changeThemeMode usage).
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final saved = SettingsRepository.instance?.getString('themeMode');
    return ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode value) async {
    state = value;
    try {
      await SettingsRepository.instance?.setString('themeMode', value.name);
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist theme mode: $e');
    }
  }
}

/// App-wide locale — persisted in the drift `app_settings` store via
/// [SettingsRepository]; on first launch the device language decides
/// (Turkish → tr, else en). Fail-open: en. GetMaterialApp consumes this via
/// `ref.watch` (replaces LocaleService/Get.updateLocale usage; GetMaterialApp
/// mirrors it into `Get.locale`, so legacy `.tr` lookups keep following the
/// selection).
final localeProvider =
    NotifierProvider<LocaleNotifier, Locale>(LocaleNotifier.new);

class LocaleNotifier extends Notifier<Locale> {
  @override
  Locale build() {
    final saved = SettingsRepository.instance?.getString('locale');
    if (saved != null) {
      final parts = saved.split('_');
      if (parts.length == 2 &&
          parts.first.isNotEmpty &&
          parts.last.isNotEmpty) {
        return Locale(parts.first, parts.last);
      }
    }
    return PlatformDispatcher.instance.locale.languageCode == 'tr'
        ? const Locale('tr', 'TR')
        : const Locale('en', 'US');
  }

  Future<void> setLocale(Locale value) async {
    state = value;
    // Apply through GetX: `GetMaterialApp` mirrors its `locale:` param into
    // `Get.locale` only in its initState (first build) and the inner
    // MaterialApp resolves `Get.locale ?? locale` — so a rebuild with a new
    // `locale:` alone is ignored (the stale Get.locale wins). updateLocale
    // sets Get.locale and forces a full reassemble, which is what actually
    // switches both the `.tr` chat strings and the gen-l10n screens
    // (reassemble also repaints const subtrees).
    unawaited(Get.updateLocale(value));
    try {
      await SettingsRepository.instance?.setString('locale', value.toString());
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist locale: $e');
    }
  }
}

/// Root drift database. `main()` opens it before `runApp` and overrides this
/// provider; tests override it with an in-memory instance. Override
/// edilmediyse bu provider'a dokunan tüketici hata alır — fail-open ele alış
/// için bkz. home_providers.dart.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError(
    'appDatabaseProvider must be overridden in main() (or in tests).',
  ),
);

/// Sohbet verisi deposu (drift). GetX chat ekranları aynı veritabanına
/// [SessionRepository.instance] üzerinden erişir (geçiş köprüsü); yeni
/// Riverpod kodu bu provider'ı kullanır.
final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => SessionRepository(ref.watch(appDatabaseProvider)),
);
