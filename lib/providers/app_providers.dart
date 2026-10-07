import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

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

/// App-wide theme mode — persisted in the `settings` Hive box (fail-open:
/// system). GetMaterialApp consumes this via `ref.watch` (replaces
/// ThemeService/Get.changeThemeMode usage).
final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final saved = _settingsBox()?.get('themeMode') as String?;
    return ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setMode(ThemeMode value) async {
    state = value;
    try {
      await _settingsBox()?.put('themeMode', value.name);
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist theme mode: $e');
    }
  }
}

/// App-wide locale — persisted in the `settings` Hive box; on first launch
/// the device language decides (Turkish → tr, else en). Fail-open: en.
/// GetMaterialApp consumes this via `ref.watch` (replaces
/// LocaleService/Get.updateLocale usage; GetMaterialApp mirrors it into
/// `Get.locale`, so legacy `.tr` lookups keep following the selection).
final localeProvider =
    NotifierProvider<LocaleNotifier, Locale>(LocaleNotifier.new);

class LocaleNotifier extends Notifier<Locale> {
  @override
  Locale build() {
    final saved = _settingsBox()?.get('locale') as String?;
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
      await _settingsBox()?.put('locale', value.toString());
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to persist locale: $e');
    }
  }
}

/// The shared `settings` box (opened in `main()`); null when Hive is down
/// (fail-open — consumers fall back to defaults).
Box? _settingsBox() {
  try {
    if (!Hive.isBoxOpen('settings')) return null;
    return Hive.box('settings');
  } catch (_) {
    return null;
  }
}