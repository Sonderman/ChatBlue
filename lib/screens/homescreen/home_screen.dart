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
        // Nearby sessions store the peer uid as the address — a uuid reads
        // as noise, so the channel label is shown instead.
        final String addressText =
            isNearby ? l10n.nearbyTab : (s.device['address'] ?? '');
        final subtitle = StringBuffer()
          ..write(addressText)
          ..write('  •  ')
          ..write(_formatDateTime(s.updatedAt));

        return ListTile(
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Text(
              (s.name.isNotEmpty ? s.name[0] : '?').toUpperCase(),
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
          title: Text(s.name),
          subtitle: Text(subtitle.toString()),
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
          onLongPress: () {
            showDialog<void>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: Text(l10n.deleteChatTitle(s.name)),
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
          },
        );
      },
    );
  }

  String _formatDateTime(DateTime dt) {
    final time = TimeOfDay.fromDateTime(dt);
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m';
  }
}