import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/hive_service.dart';
import 'package:chatblue/core/services/theme_service.dart';
import 'package:chatblue/core/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:chatblue/screens/homescreen/home_screen.dart';
import 'package:sizer/sizer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await setupServices();
  // Transport controllers are NOT registered here: each screen registers its
  // own on first access via `ensureRegistered`, so no permissions dialog
  // appears on launch and hot reloads (which skip main()) stay consistent.
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = Get.find<ThemeService>();
    return Sizer(
      builder: (context, orientation, deviceType) => GetMaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeService.mode.value,
        home: const HomeScreen(),
      ),
    );
  }
}

Future<void> setupServices() async {
  try {
    await Get.putAsync(() => HiveService().init());
  } catch (e) {
    // Fail open: app still starts; persistence calls degrade gracefully.
    if (kDebugMode && showDebugLogs) {
      debugPrint('Hive init failed: $e');
    }
  }
  try {
    // Theme mode persistence box (depends on Hive being up).
    await Get.putAsync(() => ThemeService().init());
  } catch (e) {
    // Fail open: theme stays on system default.
    if (kDebugMode && showDebugLogs) {
      debugPrint('ThemeService init failed: $e');
    }
  }
}
