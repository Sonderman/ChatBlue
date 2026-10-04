import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

/// Persists and applies the app-wide theme mode (system / light / dark).
///
/// The raw mode string is stored in a small Hive box (`settings`); applying
/// goes through `Get.changeThemeMode` so GetMaterialApp rebuilds reactively.
class ThemeService extends GetxService {
  static ThemeService get to => Get.find<ThemeService>();

  static const String _boxName = 'settings';
  static const String _modeKey = 'themeMode';

  late final Box _box;

  /// Currently selected mode; initialized from the saved value.
  final Rx<ThemeMode> mode = ThemeMode.system.obs;

  /// Opens the settings box and restores the saved mode. Must be called
  /// after Hive has been initialized (see setupServices in main.dart).
  Future<ThemeService> init() async {
    _box = await Hive.openBox(_boxName);
    final saved = _box.get(_modeKey) as String?;
    mode.value = ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
    return this;
  }

  /// Applies [value] immediately and persists it.
  Future<void> setMode(ThemeMode value) async {
    mode.value = value;
    await _box.put(_modeKey, value.name);
    Get.changeThemeMode(value);
  }
}