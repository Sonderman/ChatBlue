import 'package:chatblue/config.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/home_providers.dart';
import 'package:chatblue/screens/bluetooth_scan_screen.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/n_chatscreen/n_chat_screen.dart';
import 'package:chatblue/screens/nearby_scan_screen.dart';
import 'package:chatblue/screens/settings/settings_screen.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:chatblue/screens/wifid_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hosts the chat session list (tab 0) and the two scan entry points
/// (Bluetooth / Wi‑Fi Direct, tabs 1-2) behind a bottom navigation bar;
/// those tabs live in an IndexedStack — switching is in-place, never a
/// pushed route. Settings is pushed as its own route from the app-bar icon.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      // Only the Chats tab gets the home app bar; the scan screens
      // provide their own app bar inside the tab.
      appBar: _tabIndex == 0
          ? AppBar(
              title: const Text(appName),
              actions: [
                IconButton(
                  tooltip: l10n.settingsTab,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => navigatorKey.currentState!.push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
              ],
            )
          : null,
      body: IndexedStack(
        index: _tabIndex,
        children: const [
          _ChatsTab(),
          BluetoothScanScreen(),
          WifiDirectScanScreen(),
          NearbyScanScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) {
          setState(() => _tabIndex = index);
        },
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: l10n.chatsTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.bluetooth),
            label: l10n.bluetoothTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.wifi_tethering),
            label: l10n.wifiTab,
          ),
          NavigationDestination(
            icon: const Icon(Icons.sensors),
            label: l10n.nearbyTab,
          ),
        ],
      ),
    );
  }
}

/// Chat session list (first bottom nav tab).
class _ChatsTab extends ConsumerWidget {
  const _ChatsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    // First event loads the list; before that (and on fail-open) show the
    // empty state, matching the pre-port behavior.
    final sessions =
        ref.watch(homeSessionsProvider).value ?? const <ChatSessionModel>[];

    if (sessions.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 64, color: scheme.outlineVariant),
            const SizedBox(height: 12),
            Text(l10n.noChatsYet),
            const SizedBox(height: 4),
            Text(
              l10n.noChatsHint,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final s = sessions[index];
        // Which channel this chat runs over — also drives the badge and tap.
        final String kind = s.transportKind;
        final bool isNearby = kind == ChatSessionModel.transportNearby;
        final bool isWifi = kind == ChatSessionModel.transportWifiDirect;
        // Subtitle = the LAST message (the stored MAC/uid address no longer
        // shows — it was noise under a real conversation) • activity time.
        final String lastText = s.lastMessage?.text.trim() ?? '';
        final subtitle = StringBuffer()
          ..write(lastText.isEmpty ? l10n.noMessagesYet : lastText)
          ..write('  •  ')
          ..write(_formatDateTime(s.updatedAt));

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(
              // A user nickname (when set) drives the avatar letter too.
              (s.title.isNotEmpty ? s.title[0] : '?').toUpperCase(),
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
          title: Text(s.title),
          subtitle: Text(
            subtitle.toString(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Transport badge: a Bluetooth or Wi‑Fi Direct icon at the
          // right edge, so the channel of every chat is visible at a
          // glance.
          trailing: Tooltip(
            message: isNearby
                ? l10n.nearbyTab
                : (isWifi ? l10n.wifiTab : l10n.bluetoothTab),
            child: Icon(
              isNearby
                  ? Icons.sensors
                  : (isWifi ? Icons.wifi_tethering : Icons.bluetooth),
              size: 20,
              color: scheme.primary,
            ),
          ),
          onTap: () {
            // Reopen through the chat's own transport: Nearby → N screen,
            // Wi‑Fi Direct → W screen, everything else (Bluetooth and
            // legacy untagged sessions) → Bluetooth screen.
            // The home list follows via the drift stream — no manual
            // refresh needed after the chat closes.
            if (isNearby) {
              navigatorKey.currentState!.push(
                MaterialPageRoute(
                  builder: (_) => const NChatScreen(),
                  settings: RouteSettings(arguments: s),
                ),
              );
            } else if (isWifi) {
              navigatorKey.currentState!.push(
                MaterialPageRoute(
                  builder: (_) => const WChatScreen(),
                  settings: RouteSettings(arguments: s),
                ),
              );
            } else {
              navigatorKey.currentState!.push(
                MaterialPageRoute(
                  builder: (_) => BChatScreen(),
                  settings: RouteSettings(arguments: s),
                ),
              );
            }
          },
          onLongPress: () => _showSessionActions(context, ref, s),
        );
      },
    );
  }

  /// Long-press menu: set/clear the chat's nickname (the user-chosen title)
  /// and delete the session. The nickname entry is the primary action; the
  /// destructive delete keeps its own confirm dialog one tap behind it.
  void _showSessionActions(
      BuildContext context, WidgetRef ref, ChatSessionModel s) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: Text(l10n.setNicknameTitle),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showNicknameDialog(context, ref, s);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: scheme.error),
              title: Text(l10n.delete, style: TextStyle(color: scheme.error)),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showDeleteDialog(context, ref, s);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// The nickname dialog, prefilled with the current nickname (the device
  /// name shows as the hint — that is what appears again while the field is
  /// empty). Saving an empty field clears the nickname.
  Future<void> _showNicknameDialog(
      BuildContext context, WidgetRef ref, ChatSessionModel s) async {
    if (!context.mounted) return;
    final String? value = await showNicknameDialog(
      context,
      initial: s.nickname ?? '',
      hint: s.name,
    );
    if (value == null) return; // Cancelled.
    final normalized = value.trim();
    if (normalized == (s.nickname ?? '')) return; // No change.
    // The list re-renders from the drift stream — no manual refresh needed.
    await ref.read(setSessionNicknameProvider)(s, normalized);
  }

  /// Deletes the session after confirmation — the pre-nickname long-press
  /// flow, now reached through the action menu.
  void _showDeleteDialog(
      BuildContext context, WidgetRef ref, ChatSessionModel s) {
    final l10n = AppLocalizations.of(context)!;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteChatTitle(s.title)),
        content: Text(l10n.deleteChatMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              ref.read(deleteChatSessionProvider)(s);
              Navigator.of(dialogContext).pop();
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final time = TimeOfDay.fromDateTime(dt);
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m';
  }
}

/// Shows the nickname-entry dialog and resolves with the entered text, or
/// null when the user cancelled. (Also clears the field when it is saved
/// empty — the caller trims and persists.)
///
/// The TextEditingController is owned by the DIALOG'S state and disposed
/// with it. Disposing a controller right after `showDialog` returns is a
/// trap: the future completes at pop TIME, while the dialog is still
/// animating out — any rebuild of the field during the exit (e.g. the
/// app-wide rebuild the keyboard-close viewport-metrics resend triggers)
/// then re-attaches to the disposed controller, "A TextEditingController
/// was used after being disposed" is thrown inside the layout phase, the
/// frame aborts, and the framework cascades into further assertions on
/// device (`_dependents.isEmpty`, 'debugNeedsLayout', duplicate-global-key
/// reports — device-reported). Owning the controller in the dialog's state
/// keeps its lifetime exactly as long as the field needs it.
Future<String?> showNicknameDialog(
  BuildContext context, {
  required String initial,
  required String hint,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NicknameDialog(initial: initial, hint: hint),
  );
}

/// The dialog content: owns its controller (see [showNicknameDialog]).
class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial, required this.hint});

  /// The current nickname the field starts with.
  final String initial;

  /// The device name shown as the hint while the field is empty.
  final String hint;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      title: Text(l10n.setNicknameTitle),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          labelText: l10n.nicknameLabel,
          hintText: widget.hint,
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.saveAction),
        ),
      ],
    );
  }
}