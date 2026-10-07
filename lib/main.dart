import 'dart:async';

import 'package:chatblue/config.dart';
import 'package:chatblue/core/theme/app_theme.dart';
import 'package:chatblue/core/translations/app_translations.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:mcp_toolkit/mcp_toolkit.dart';
import 'package:chatblue/screens/homescreen/home_screen.dart';
import 'package:sizer/sizer.dart';

void main() async {
  if (kDebugMode) {
    // Agent bridge (flutter-mcp-toolkit), debug-only. initialize() installs
    // the toolkit's log capture as a global debugPrint override (plain
    // print() is NOT captured — use debugPrint for agent-visible logs) and
    // registers the VM-service extensions; the runZonedGuarded zone routes
    // uncaught async errors to handleZoneError so they stay visible. The
    // binding is inert in release builds; this gate keeps the release path
    // exactly as before.
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        MCPToolkitBinding.instance
          ..initialize()
          ..initializeFlutterToolkit();
        await _launchApp();
      },
      (error, stack) =>
          MCPToolkitBinding.instance.handleZoneError(error, stack),
    );
  } else {
    WidgetsFlutterBinding.ensureInitialized();
    await _launchApp();
  }
}

/// App bootstrap after binding/toolkit init: services, container, runApp.
Future<void> _launchApp() async {
  final database = await setupServices();
  // Transport controllers are NOT registered here: each screen registers its
  // own on first access via `ensureRegistered`, so no permissions dialog
  // appears on launch and hot reloads (which skip main()) stay consistent.
  final container = ProviderContainer(
    overrides: [
      if (database != null) appDatabaseProvider.overrideWithValue(database),
    ],
  );
  rootProviderContainer = container;
  runApp(UncontrolledProviderScope(container: container, child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Sizer(
      builder: (context, orientation, deviceType) => GetMaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        translations: AppTranslations(),
        locale: ref.watch(localeProvider),
        fallbackLocale: const Locale('en', 'US'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ref.watch(themeModeProvider),
        home: const HomeScreen(),
      ),
    );
  }
}

/// Service bootstrap. Every step fails open: the app starts even when a
/// service is unavailable — persistence simply degrades. Returns the opened
/// drift database (null when opening failed) so `main()` can hand it to the
/// Riverpod container.
Future<AppDatabase?> setupServices() async {
  AppDatabase? database;
  try {
    // drift (SQLite) — the app's single local store: chat sessions/messages
    // plus app settings (themeMode/locale/device_id). The legacy Hive data
    // was carried over by the one-time importers while Hive was still
    // present (P1/P2 builds); Hive itself is gone (P3) — boxes remaining on
    // test devices are inert files.
    database = await AppDatabase.open();
    SessionRepository.instance = SessionRepository(database);
    // Settings cache loads before runApp: the notifiers read synchronously
    // (no theme/locale flicker on launch).
    final settings = SettingsRepository(database);
    SettingsRepository.instance = settings;
    await settings.load();
  } catch (e) {
    // Fail open: without the database, chat features degrade but the app
    // still starts (home list renders empty, settings defaults win).
    if (kDebugMode && showDebugLogs) {
      debugPrint('Drift init failed: $e');
    }
  }
  return database;
}
