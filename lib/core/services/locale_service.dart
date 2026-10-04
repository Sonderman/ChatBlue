import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';

/// Persists and applies the app-wide language (English / Turkish).
///
/// The raw locale string is stored in the shared `settings` Hive box;
/// applying goes through `Get.updateLocale` so GetMaterialApp rebuilds
/// reactively. When nothing is saved yet, the device language decides:
/// Turkish devices start in Turkish, everything else defaults to English.
class LocaleService extends GetxService {
  static LocaleService get to => Get.find<LocaleService>();

  static const String _boxName = 'settings';
  static const String _localeKey = 'locale';

  late final Box _box;

  /// Currently selected locale; initialized from the saved value (or the
  /// device language on first launch).
  final Rx<Locale> locale = const Locale('en', 'US').obs;

  /// Opens the settings box and restores the saved locale. Must be called
  /// after Hive has been initialized (see setupServices in main.dart).
  Future<LocaleService> init() async {
    _box = await Hive.openBox(_boxName);
    final saved = _box.get(_localeKey) as String?;
    if (saved != null) {
      final parts = saved.split('_');
      if (parts.length == 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
        locale.value = Locale(parts.first, parts.last);
        return this;
      }
    }
    // First launch: follow the device language (Turkish → tr, else en).
    locale.value = Get.deviceLocale?.languageCode == 'tr'
        ? const Locale('tr', 'TR')
        : const Locale('en', 'US');
    return this;
  }

  /// Applies [value] immediately and persists it.
  Future<void> setLocale(Locale value) async {
    locale.value = value;
    await _box.put(_localeKey, value.toString());
    Get.updateLocale(value);
  }
}