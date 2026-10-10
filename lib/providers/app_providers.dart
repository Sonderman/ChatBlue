import 'package:chatblue/core/services/cache_cleaner.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Global navigator key — controller'lar context'siz navigasyon için kullanır;
/// `main.dart`'taki MaterialApp'e bağlanır.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Global scaffold messenger key — controller'lar context'siz snackbar
/// gösterimi için (eski GetX snackbar'ı yerine).
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// App-wide theme mode — persisted in the drift `app_settings` store via
/// [SettingsRepository] (fail-open: system). MaterialApp consumes this
/// via `ref.watch`.
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
/// (Turkish → tr, else en). Fail-open: en. MaterialApp consumes this via
/// `ref.watch`; switching the locale rebuilds the app with it.
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
    try {
      await SettingsRepository.instance?.setString('locale', value.toString());
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist locale: $e');
    }
  }
}

/// Context'siz çeviri: notifier'lar (transport + chat) çağrı anında bu
/// provider'dan güncel locale'in AppLocalizations'ını okur.
final appLocalizationsProvider = Provider<AppLocalizations>(
  (ref) => lookupAppLocalizations(ref.watch(localeProvider)),
);

/// Root drift database. `main()` opens it before `runApp` and overrides this
/// provider; tests override it with an in-memory instance. Override
/// edilmediyse bu provider'a dokunan tüketici hata alır — fail-open ele alış
/// için bkz. home_providers.dart.
final appDatabaseProvider = Provider<AppDatabase>(
  (ref) => throw UnimplementedError(
    'appDatabaseProvider must be overridden in main() (or in tests).',
  ),
);

/// Sohbet verisi deposu (drift). Tüm chat kodu bu provider üzerinden erişir.
final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => SessionRepository(ref.watch(appDatabaseProvider)),
);

/// Cache cleaner (Settings → Clear cache): yerel medya kopyalarını siler,
/// balonları yeniden indirilebilir placeholder'a çevirir, temp dizini
/// boşaltır. Sohbet geçmişine ve ayarlara dokunmaz.
final cacheCleanerProvider = Provider<CacheCleaner>(
  (ref) => CacheCleaner(ref.watch(sessionRepositoryProvider)),
);

/// Installed package info (versionName + versionCode). The About screen
/// reads the ACTUAL APK metadata through this, so the shown version always
/// matches the build on the device — single source of truth: pubspec
/// `version: X.Y.Z+N`. Fail-open: an error (headless/test sessions) leaves
/// `.value` null and the About screen falls back to [appVersion].
final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);
