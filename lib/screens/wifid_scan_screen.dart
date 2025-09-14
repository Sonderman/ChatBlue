// DeviceScanScreen for discovering nearby Bluetooth devices and connecting to them.
// Uses GetX for state management.
import 'package:chatblue/controllers/wifi_controller.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WifiDirectScanScreen extends StatelessWidget {
  const WifiDirectScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<WifiController>(
      init: WifiController(),
      builder: (controller) {
        return Scaffold(
          appBar: AppBar(title: Text('Discover & Connect via Wifi'), centerTitle: true),
          body: Obx(
            () => Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: controller.isServerModeActive.value ? Colors.green : null,
                        foregroundColor: controller.isServerModeActive.value ? Colors.white : null,
                      ),
                      onPressed: controller.isServerModeActive.value
                          ? controller.stopServer
                          : () async {
                              controller.startServer();
                            },
                      child: Text(
                        controller.isServerModeActive.value ? 'Stop Server' : 'Start Server',
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: controller.isScanning.value ? Colors.green : null,
                        foregroundColor: controller.isScanning.value ? Colors.white : null,
                      ),
                      onPressed: controller.isScanning.value
                          ? controller.stopDiscovery
                          : () async {
                              controller.startDiscovery();
                            },
                      child: Text(
                        controller.isScanning.value ? 'Stop Discovery' : 'Start Discovery',
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        if (controller.isScanning.value) Text("Scanning for Devices"),
                        Text("Nearby Devices (${controller.peers.length})"),
                        Expanded(
                          child: ListView.builder(
                            itemCount: controller.peers.length,
                            itemBuilder: (context, index) {
                              WdPeerInfo device = controller.peers[index];
                              return ListTile(
                                title: Text(device.deviceName ?? 'Unknown'),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [Text(device.deviceAddress)],
                                ),
                                leading: Icon(Icons.wifi_tethering),
                                onTap: () async {
                                  // Show loading dialog
                                  Get.dialog(
                                    Center(child: CircularProgressIndicator()),
                                    barrierDismissible: false,
                                  );

                                  bool isConnected = await controller.connectToDevice(device);

                                  // Close loading dialog if still open
                                  if (Get.isDialogOpen == true) {
                                    Get.back();
                                  }

                                  if (isConnected && controller.isConnected.value) {
                                    Get.to(() => WChatScreen());
                                  }
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
