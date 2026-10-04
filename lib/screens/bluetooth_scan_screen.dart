// DeviceScanScreen for discovering nearby Bluetooth devices and connecting to them.
// Uses GetX for state management.
import 'package:chatblue/controllers/bt_controller.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class BluetoothScanScreen extends StatelessWidget {
  const BluetoothScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ensureRegistered(BtController());
    return Scaffold(
          appBar: AppBar(title: Text('discoverConnectTitle'.tr), centerTitle: true),
          body: Obx(
            () => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: controller.isServerModeActive.value
                                  ? Colors.green
                                  : null,
                              foregroundColor: controller.isServerModeActive.value
                                  ? Colors.white
                                  : null,
                            ),
                            onPressed: controller.isServerModeActive.value
                                ? controller.stopServer
                                : () async {
                                    controller.startServer();
                                  },
                            child: Text(
                              controller.isServerModeActive.value
                                  ? 'stopDiscoverable'.tr
                                  : 'makeDiscoverable'.tr,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: controller.isScanning.value
                                  ? Colors.green
                                  : null,
                              foregroundColor: controller.isScanning.value
                                  ? Colors.white
                                  : null,
                            ),
                            onPressed: controller.isScanning.value
                                ? controller.stopScan
                                : () async {
                                    controller.startScan();
                                  },
                            child: Text(
                              controller.isScanning.value
                                  ? 'stopScanning'.tr
                                  : 'scanForDevices'.tr,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        TabBar(
                          tabs: [
                            Tab(
                              text: 'nearbyDevices'.trParams({
                                'count': '${controller.scanResults.length}',
                              }),
                            ),
                            Tab(
                              text: 'pairedDevices'.trParams({
                                'count': '${controller.pairedDevices.length}',
                              }),
                            ),
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
                                    title: Text(device.name ?? 'unknownDevice'.tr),
                                    subtitle: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [Text(device.address)],
                                    ),
                                    leading: Icon(Icons.bluetooth),
                                    trailing: _buildSignalIndicator(device.rssi),
                                    onTap: () async {
                                      // Show loading dialog and track its life:
                                      // the dialog is closed via the root
                                      // navigator (snackbars are overlay
                                      // entries, not routes, so this can never
                                      // close the wrong thing).
                                      var loading = true;
                                      Get.dialog(
                                        const Center(child: CircularProgressIndicator()),
                                        barrierDismissible: false,
                                      ).then((_) => loading = false);

                                      await controller.connectToDevice(device);

                                      if (loading) {
                                        Navigator.of(
                                          Get.overlayContext!,
                                          rootNavigator: true,
                                        ).pop();
                                      }
                                      // A timeout with the peer still deciding
                                      // is NOT a failure: the link is alive
                                      // and the READY frame will open the
                                      // chat once the peer accepts.
                                      if (!controller.isConnected.value &&
                                          !controller.isAwaitingAcceptance) {
                                        Get.snackbar(
                                          'couldNotConnectTitle'.tr,
                                          'couldNotConnectMessage'.tr,
                                        );
                                      } else if (!controller.isConnected.value) {
                                        Get.snackbar(
                                          'waitingAcceptanceTitle'.tr,
                                          'waitingAcceptanceMessage'.tr,
                                        );
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
                                    title: Text(device.name ?? 'unknownDevice'.tr),
                                    subtitle: Text(
                                      '${device.address} | ${'previouslyConnected'.tr}',
                                    ),
                                    leading: Icon(Icons.phone_android),
                                    trailing: Icon(Icons.link, color: Colors.blue),
                                    onTap: () async {
                                                                          var loading = true;
                                                                          Get.dialog(
                                                                            const Center(child: CircularProgressIndicator()),
                                                                            barrierDismissible: false,
                                                                          ).then((_) => loading = false);
                                                                          try {
                                                                            final bool connected =
                                                                                await controller.connectToDevice(device);

                                                                            if (loading) {
                                                                              Navigator.of(
                                                                                Get.overlayContext!,
                                                                                rootNavigator: true,
                                                                              ).pop();
                                                                            }

                                                                            // A timeout with the peer still deciding is NOT a
                                                                            // failure: the link is alive and the READY frame
                                                                            // will open the chat once the peer accepts.
                                                                            if (!connected &&
                                                                                !controller.isConnected.value &&
                                                                                !controller.isAwaitingAcceptance) {
                                                                              Get.snackbar(
                                                                                'couldNotConnectTitle'.tr,
                                                                                'couldNotConnectMessage'.tr,
                                                                              );
                                                                            } else if (!connected &&
                                                                                !controller.isConnected.value) {
                                                                              Get.snackbar(
                                                                                'waitingAcceptanceTitle'.tr,
                                                                                'waitingAcceptanceMessage'.tr,
                                                                              );
                                                                            }
                                                                            // On success, BtController navigates to
                                                                            // the chat screen itself.
                                                                          } catch (e) {
                                                                            if (loading) {
                                                                              Navigator.of(
                                                                                Get.overlayContext!,
                                                                                rootNavigator: true,
                                                                              ).pop();
                                                                            }
                                                                            Get.snackbar(
                                                                              'connectionError'.tr,
                                                                              'connectErrorDetail'.trParams(
                                                                                {'error': '$e'},
                                                                              ),
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
