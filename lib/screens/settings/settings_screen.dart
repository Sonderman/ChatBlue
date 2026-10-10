// Settings panel: language, theme switching and app info. Reached from the
// home screen's settings tab (app-bar icon). Owns its Scaffold/AppBar so it
// renders with the proper theme even when shown as a standalone tab.

import 'package:chatblue/config.dart';
import 'package:chatblue/core/format_utils.dart';
import 'package:chatblue/core/services/cache_cleaner.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:flutter/foundation.dart';
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
    final packageInfo = ref.watch(packageInfoProvider).value;

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
                // Segment labels scale down instead of wrapping/clipping when
                // squeezed: MIUI/HyperOS runs a larger system font scale and
                // the widest theme label ("System") used to be cut off inside
                // its equal-width segment box on those devices.
                SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto_outlined),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l10n.themeSystem),
                      ),
                    ),
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode_outlined),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l10n.themeLight),
                      ),
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode_outlined),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l10n.themeDark),
                      ),
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
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l10n.languageEnglish),
                      ),
                    ),
                    ButtonSegment(
                      value: const Locale('tr', 'TR'),
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(l10n.languageTurkish),
                      ),
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
          _SectionLabel(l10n.storageSection),
          const SizedBox(height: 8),
          _settingsCard(
            scheme: scheme,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cleaning_services_outlined,
                        color: scheme.primary),
                    const SizedBox(width: 10),
                    Text(
                      l10n.clearCacheTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.clearCacheHint,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerRight,
                  child: _ClearCacheButton(),
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
              // Real installed version + build code (pubspec `version:` is
              // the single source of truth; the constant is only the
              // headless fallback when the platform info is unavailable).
              subtitle: Text(
                l10n.versionLabel(
                  packageInfo == null
                      ? appVersion
                      : '${packageInfo.version} (build ${packageInfo.buildNumber})',
                ),
              ),
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

/// "Clear cache" action: confirmation dialog → cleanup pass → result card.
/// Busy while running (the pass can touch many files); the outcome is
/// reported through the app's standard notice card.
class _ClearCacheButton extends ConsumerStatefulWidget {
  const _ClearCacheButton();

  @override
  ConsumerState<_ClearCacheButton> createState() => _ClearCacheButtonState();
}

class _ClearCacheButtonState extends ConsumerState<_ClearCacheButton> {
  bool _busy = false;

  Future<void> _confirmAndClear() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.clearCacheConfirmTitle),
        content: Text(l10n.clearCacheConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.clearAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    CacheClearResult? result;
    try {
      result = await ref.read(cacheCleanerProvider).clearCache();
    } catch (e) {
      if (kDebugMode) debugPrint('Clear cache failed: $e');
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (result == null) {
      ConnectionNotice.show(
        title: l10n.clearCacheFailedTitle,
        message: l10n.clearCacheFailedMessage,
        icon: Icons.error_outline,
        accent: Colors.redAccent,
      );
      return;
    }

    // The files just deleted must not stay cached as decoded bitmaps.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();

    final freed = result.freedBytes;
    ConnectionNotice.show(
      title: l10n.clearCacheDoneTitle,
      message: freed > 0
          ? l10n.clearCacheFreedMessage(formatFileSize(freed))
          : l10n.clearCacheNothingMessage,
      icon: Icons.check_circle,
      accent: Colors.green,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.tonalIcon(
      onPressed: _busy ? null : _confirmAndClear,
      style: FilledButton.styleFrom(foregroundColor: scheme.error),
      icon: _busy
          ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.error,
              ),
            )
          : const Icon(Icons.delete_sweep_outlined, size: 18),
      label: Text(l10n.clearAction),
    );
  }
}