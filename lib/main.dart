import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:chatblue/core/theme/app_theme.dart';
import 'package:chatblue/core/translations/app_translations.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/home_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:chatblue/screens/homescreen/home_screen.dart';
import 'package:sizer/sizer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final hiveService = await setupServices();
  // Transport controllers are NOT registered here: each screen registers its
  // own on first access via `ensureRegistered`, so no permissions dialog
  // appears on launch and hot reloads (which skip main()) stay consistent.
  final container = ProviderContainer(
    overrides: [
      if (hiveService != null) hiveServiceProvider.overrideWithValue(hiveService),
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

Future<HiveService?> setupServices() async {
  HiveService? hiveService;
  try {
    // Register with GetX UNCONDITIONALLY and permanent — GetX auto-deletes
    // non-permanent instances not `Get.find`-ed within ~5 s, and nothing on
    // the GetX side touches HiveService until a chat opens (Home is now
    // Riverpod-driven), so the legacy `HiveService.to` calls in the chat
    // controller would crash with "not found" after a few seconds.
    // (Deliberately `Get.put`, not `putAsync`: a sync, guaranteed
    // registration — a broken box is a recoverable runtime error, a
    // missing registration is a crash.)
    final service = HiveService();
    // `HiveService.to` prefers this static reference over the GetX registry
    // (see hive_service.dart) so the app path stays independent of GetX's
    // instance lifecycle during the GetX→Riverpod migration.
    HiveService.instance = service;
    try {
      await service.init();
    } catch (e) {
      // Fail open: app still starts; persistence calls degrade.
      if (kDebugMode && showDebugLogs) {
        debugPrint('Hive init failed: $e');
      }
    }
    // The explicit `<HiveService>` type argument is REQUIRED here: in this
    // ternary the assignment context is `HiveService?`, and type inference
    // then infers `S = HiveService?` for `put`, keying the registration as
    // "HiveService?" — every `Get.find<HiveService>()` missed it and the
    // first chat open crashed with '"HiveService" not found' (verified live
    // on device over the VM service: isRegistered<HiveService>() false while
    // isRegistered<HiveService?>() true). Pin the type argument.
    hiveService = Get.isRegistered<HiveService>()
        ? Get.find<HiveService>()
        : Get.put<HiveService>(service, permanent: true);
  } catch (e) {
    if (kDebugMode && showDebugLogs) {
      debugPrint('HiveService registration failed: $e');
    }
  }
  try {
    // Shared settings box (theme mode / locale); depends on Hive being up.
    await Hive.openBox('settings');
  } catch (e) {
    // Fail open: theme stays on system default, locale on the device language.
    if (kDebugMode && showDebugLogs) {
      debugPrint('Settings box init failed: $e');
    }
  }
  return hiveService;
}
