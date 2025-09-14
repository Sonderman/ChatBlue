import 'package:chatblue/config.dart';
import 'package:chatblue/screens/bluetooth_scan_screen.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/homescreen/home_controller.dart';
import 'package:chatblue/screens/wifid_scan_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Lists previous chat sessions and provides a quick action to open
/// the device scan/connect screen.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<HomeController>(
      init: HomeController(),
      builder: (controller) {
        return Scaffold(
          appBar: AppBar(
            title: const Text(appName),
            actions: [
              IconButton(
                tooltip: 'Scan & Connect with Bluetooth',
                icon: const Icon(Icons.bluetooth_searching),
                onPressed: () {
                  Get.to(() => BluetoothScanScreen())?.then((_) => controller.refreshSessions());
                },
              ),
              IconButton(
                tooltip: 'Scan & Connect with Wifi Direct',
                icon: const Icon(Icons.wifi_tethering),
                onPressed: () {
                  Get.to(() => WifiDirectScanScreen())?.then((_) => controller.refreshSessions());
                },
              ),
            ],
          ),
          body: Obx(() {
            if (controller.sessions.isEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.chat_bubble_outline, size: 64, color: Colors.black26),
                    const SizedBox(height: 12),
                    const Text('No chats yet'),
                    const SizedBox(height: 4),
                    Text(
                      'Tap the bluetooth icon to find a device to chat with',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              );
            }
            return ListView.separated(
              itemCount: controller.sessions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final s = controller.sessions[index];
                final subtitle = StringBuffer()
                  ..write(s.device['address'] ?? '')
                  ..write('  •  ')
                  ..write(_formatDateTime(s.updatedAt));

                return ListTile(
                  leading: CircleAvatar(
                    child: Text((s.name.isNotEmpty ? s.name[0] : '?').toUpperCase()),
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
                        title: Text('Delete ${s.name}'),
                        content: Text('Are you sure you want to delete this chat session?'),
                        actions: [
                          TextButton(onPressed: () => Get.back(), child: Text('Cancel')),
                          TextButton(
                            onPressed: () {
                              controller.deleteSession(s);
                              Get.back();
                            },
                            child: Text('Delete'),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            );
          }),
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
