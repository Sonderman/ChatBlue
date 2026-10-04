import 'package:chatblue/config.dart';
import 'package:chatblue/screens/bluetooth_scan_screen.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/homescreen/home_controller.dart';
import 'package:chatblue/screens/settings/settings_screen.dart';
import 'package:chatblue/screens/wifid_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

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
    return GetBuilder<HomeController>(
      init: HomeController(),
      builder: (controller) {
        return Scaffold(
          // Only the Chats tab gets the home app bar; the scan screens
          // provide their own app bar inside the tab.
          appBar: _tabIndex == 0
              ? AppBar(
                  title: const Text(appName),
                  actions: [
                    IconButton(
                      tooltip: 'settingsTab'.tr,
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => Get.to(() => const SettingsScreen()),
                    ),
                  ],
                )
              : null,
          body: IndexedStack(
            index: _tabIndex,
            children: [
              _ChatsTab(controller: controller),
              const BluetoothScanScreen(),
              const WifiDirectScanScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (index) {
              setState(() => _tabIndex = index);
              if (index == 0) {
                controller.refreshSessions();
              }
            },
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'chatsTab'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.bluetooth),
                label: 'bluetoothTab'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.wifi_tethering),
                label: 'wifiTab'.tr,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Chat session list (first bottom nav tab).
class _ChatsTab extends StatelessWidget {
  const _ChatsTab({required this.controller});

  final HomeController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Obx(() {
      if (controller.sessions.isEmpty) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 64, color: scheme.outlineVariant),
              const SizedBox(height: 12),
              Text('noChatsYet'.tr),
              const SizedBox(height: 4),
              Text(
                'noChatsHint'.tr,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        );
      }
      return ListView.separated(
        itemCount: controller.sessions.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final s = controller.sessions[index];
          final subtitle = StringBuffer()
            ..write(s.device['address'] ?? '')
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
            onTap: () {
              Get.to(
                () => BChatScreen(),
                arguments: s,
              )?.then((_) => controller.refreshSessions());
            },
            onLongPress: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('deleteChatTitle'.trParams({'name': s.name})),
                  content: Text('deleteChatMessage'.tr),
                  actions: [
                    TextButton(
                      onPressed: () => Get.back(),
                      child: Text('cancel'.tr),
                    ),
                    TextButton(
                      onPressed: () {
                        controller.deleteSession(s);
                        Get.back();
                      },
                      child: Text('delete'.tr),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    });
  }

  String _formatDateTime(DateTime dt) {
    final time = TimeOfDay.fromDateTime(dt);
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} $h:$m';
  }
}