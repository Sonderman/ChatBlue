// Settings panel: language, theme switching and app info. Reached from the
// home screen's settings tab (app-bar icon). Owns its Scaffold/AppBar so it
// renders with the proper theme even when shown as a standalone tab.

import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/locale_service.dart';
import 'package:chatblue/core/services/theme_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final themeService = Get.find<ThemeService>();
    final localeService = Get.find<LocaleService>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text('settingsTab'.tr)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionLabel('appearanceSection'.tr),
        const SizedBox(height: 8),
        _settingsCard(
          scheme: scheme,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.palette_outlined, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'themeLabel'.tr,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Obx(
                () => SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto_outlined),
                      label: Text('themeSystem'.tr),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: Text('themeLight'.tr),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: Text('themeDark'.tr),
                    ),
                  ],
                  selected: {themeService.mode.value},
                  onSelectionChanged: (selection) =>
                      themeService.setMode(selection.first),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'themeSystemHint'.tr,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _settingsCard(
          scheme: scheme,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.language, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'languageLabel'.tr,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Obx(
                () => SegmentedButton<Locale>(
                  segments: [
                    ButtonSegment(
                      value: const Locale('en', 'US'),
                      label: Text('languageEnglish'.tr),
                    ),
                    ButtonSegment(
                      value: const Locale('tr', 'TR'),
                      label: Text('languageTurkish'.tr),
                    ),
                  ],
                  selected: {localeService.locale.value},
                  onSelectionChanged: (selection) =>
                      localeService.setLocale(selection.first),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'languageHint'.tr,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _SectionLabel('aboutSection'.tr),
        const SizedBox(height: 8),
        _settingsCard(
          scheme: scheme,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.chat_bubble_outline, color: scheme.onPrimaryContainer),
            ),
            title: Text(appName),
            subtitle: Text('versionLabel'.trParams({'version': appVersion})),
          ),
        ),
      ],
      ),
    );
  }

  /// Shared card surface for the settings rows.
  Widget _settingsCard({
    required ColorScheme scheme,
    required Widget child,
  }) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    );
  }
}