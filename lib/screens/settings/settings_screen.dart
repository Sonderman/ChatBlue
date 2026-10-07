// Settings panel: language, theme switching and app info. Reached from the
// home screen's settings tab (app-bar icon). Owns its Scaffold/AppBar so it
// renders with the proper theme even when shown as a standalone tab.

import 'package:chatblue/config.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTab)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionLabel(l10n.appearanceSection),
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
                      l10n.themeLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto_outlined),
                      label: Text(l10n.themeSystem),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: Text(l10n.themeLight),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: Text(l10n.themeDark),
                    ),
                  ],
                  selected: {themeMode},
                  onSelectionChanged: (selection) =>
                      ref.read(themeModeProvider.notifier).setMode(selection.first),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.themeSystemHint,
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
                      l10n.languageLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<Locale>(
                  segments: [
                    ButtonSegment(
                      value: const Locale('en', 'US'),
                      label: Text(l10n.languageEnglish),
                    ),
                    ButtonSegment(
                      value: const Locale('tr', 'TR'),
                      label: Text(l10n.languageTurkish),
                    ),
                  ],
                  selected: {locale},
                  onSelectionChanged: (selection) =>
                      ref.read(localeProvider.notifier).setLocale(selection.first),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.languageHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _SectionLabel(l10n.aboutSection),
          const SizedBox(height: 8),
          _settingsCard(
            scheme: scheme,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child:
                    Icon(Icons.chat_bubble_outline, color: scheme.onPrimaryContainer),
              ),
              title: Text(appName),
              subtitle: Text(l10n.versionLabel(appVersion)),
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