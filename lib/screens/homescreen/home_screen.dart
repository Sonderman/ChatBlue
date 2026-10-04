import 'package:chatblue/config.dart';
import 'package:chatblue/screens/bluetooth_scan_screen.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/homescreen/home_controller.dart';
import 'package:chatblue/screens/settings/settings_screen.dart';
import 'package:chatblue/screens/wifid_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Lists previous chat sessions (tab 1) and hosts the settings panel
/// (tab 2) behind a bottom navigation bar.
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
          appBar: AppBar(
            title: Text(_tabIndex == 0 ? appName : 'settingsTab'.tr),
            actions: _tabIndex == 0
                ? [
                    IconButton(
                      tooltip: 'scanBluetoothTooltip'.tr,
                      icon: const Icon(Icons.bluetooth_searching),
                      onPressed: () {
                        Get.to(() => BluetoothScanScreen())
                            ?.then((_) => controller.refreshSessions());
                      },
                    ),
                    IconButton(
                      tooltip: 'scanWifiTooltip'.tr,
                      icon: const Icon(Icons.wifi_tethering),
                      onPressed: () {
                        Get.to(() => WifiDirectScanScreen())
                            ?.then((_) => controller.refreshSessions());
                      },
                    ),
                  ]
                : null,
          ),
          body: IndexedStack(
            index: _tabIndex,
            children: [
              _ChatsTab(controller: controller),
              const SettingsScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (index) => setState(() => _tabIndex = index),
            destinations: [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'chatsTab'.tr,
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'settingsTab'.tr,
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