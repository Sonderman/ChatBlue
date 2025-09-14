// DeviceScanScreen for discovering nearby Bluetooth devices and connecting to them.
// Uses GetX for state management.
import 'package:chatblue/controllers/bt_controller.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class BluetoothScanScreen extends StatelessWidget {
  const BluetoothScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GetBuilder<BtController>(
      init: BtController(),
      builder: (controller) {
        return Scaffold(
          appBar: AppBar(title: Text('Discover & Connect'), centerTitle: true),
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
                        controller.isServerModeActive.value
                            ? 'Stop Discoverable'
                            : 'Make Discoverable',
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: controller.isScanning.value ? Colors.green : null,
                        foregroundColor: controller.isScanning.value ? Colors.white : null,
                      ),
                      onPressed: controller.isScanning.value
                          ? controller.stopScan
                          : () async {
                              controller.startScan();
                            },
                      child: Text(
                        controller.isScanning.value ? 'Stop Scanning' : 'Scan for Devices',
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        TabBar(
                          tabs: [
                            Tab(text: 'Nearby Devices (${controller.scanResults.length})'),
                            Tab(text: 'Paired Devices (${controller.pairedDevices.length})'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              ListView.builder(
                                itemCount: controller.scanResults.length,
                                itemBuilder: (context, index) {
                                  BtDeviceInfo device = controller.scanResults[index];
                                  return ListTile(
                                    title: Text(device.name ?? 'Unknown'),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [Text(device.address)],
                                    ),
                                    leading: Icon(Icons.bluetooth),
                                    trailing: _buildSignalIndicator(device.rssi),
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
                                        Get.to(() => BChatScreen());
                                      }
                                    },
                                  );
                                },
                              ),
                              // Paired/bonded devices tab
                              ListView.builder(
                                itemCount: controller.pairedDevices.length,
                                itemBuilder: (context, index) {
                                  BtDeviceInfo device = controller.pairedDevices[index];
                                  return ListTile(
                                    title: Text(device.name ?? 'Unknown'),
                                    subtitle: Text('${device.address} | Previously connected'),
                                    leading: Icon(Icons.phone_android),
                                    trailing: Icon(Icons.link, color: Colors.blue),
                                    onTap: () async {
                                      try {
                                        // Show loading dialog
                                        Get.dialog(
                                          Center(child: CircularProgressIndicator()),
                                          barrierDismissible: false,
                                        );

                                        bool connected = await controller.connectToDevice(device);

                                        // Close loading dialog if still open
                                        if (Get.isDialogOpen == true) {
                                          Get.back();
                                        }

                                        if (connected && controller.isConnected.value) {
                                          Get.to(() => BChatScreen());
                                        } else {
                                          Get.snackbar(
                                            'Could not connect!',
                                            "Make sure the other device is discoverable and in range.",
                                          );
                                        }
                                      } catch (e) {
                                        // Close loading dialog if still open
                                        if (Get.isDialogOpen == true) {
                                          Get.back();
                                        }
                                        Get.snackbar(
                                          'Connection Error',
                                          'Could not connect to device: $e',
                                        );
                                      }
                                    },
                                  );
                                },
                              ),
                            ],
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

  // Builds a signal strength indicator based on RSSI (in dBm).
  // Higher (closer to 0) values indicate stronger signal.
  Widget _buildSignalIndicator(int? rssi) {
    if (rssi == null) return const SizedBox.shrink();
    int level;
    if (rssi >= -50) {
      level = 4;
    } else if (rssi >= -60) {
      level = 3;
    } else if (rssi >= -70) {
      level = 2;
    } else if (rssi >= -80) {
      level = 1;
    } else {
      level = 0;
    }

    IconData icon;
    switch (level) {
      case 4:
        icon = Icons.signal_cellular_4_bar;
        break;
      case 3:
        icon = Icons.signal_cellular_alt;
        break;
      case 2:
        icon = Icons.signal_cellular_alt_2_bar;
        break;
      case 1:
        icon = Icons.signal_cellular_alt_1_bar;
        break;
      default:
        icon = Icons.signal_cellular_0_bar;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Icon(icon, color: Colors.green),
        const SizedBox(height: 2),
        Text('$rssi dBm', style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ],
    );
  }
}
