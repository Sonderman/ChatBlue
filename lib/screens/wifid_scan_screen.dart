// DeviceScanScreen for discovering nearby Bluetooth devices and connecting to them.
// Uses GetX for state management.
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/controllers/wifi_controller.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WifiDirectScanScreen extends StatelessWidget {
  const WifiDirectScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = ensureRegistered(WifiController());
    return Scaffold(
          appBar: AppBar(title: Text('discoverConnectWifiTitle'.tr), centerTitle: true),
          body: Obx(
            () => Column(
              children: [
                // Wi‑Fi off: nothing can be discovered/connected — show a
                // "turn on Wi‑Fi" panel button instead of the scan controls.
                if (!controller.isWifiOn.value)
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'wifiOffTitle'.tr,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed:
                                  controller.isWifiEnableInFlight.value
                                      ? null
                                      : controller.enableWifi,
                              icon: const Icon(Icons.wifi),
                              label: Text('enableWifi'.tr),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                // Server mode (explicit P2P group owner) is hidden from
                // the UI for now: connecting works through the scan list
                // or the chat screen's Connect button; the controller/
                // service/native code is kept intact. Restore the
                // commented button below to bring it back:
                // Expanded(
                //   child: FittedBox(
                //     fit: BoxFit.scaleDown,
                //     child: ElevatedButton(
                //       style: ElevatedButton.styleFrom(
                //         backgroundColor:
                //             controller.isServerModeActive.value
                //                 ? Colors.green
                //                 : null,
                //         foregroundColor:
                //             controller.isServerModeActive.value
                //                 ? Colors.white
                //                 : null,
                //       ),
                //       onPressed:
                //           controller.isServerModeActive.value
                //               ? controller.stopServer
                //               : () async {
                //                   controller.startServer();
                //                 },
                //       child: Text(
                //         controller.isServerModeActive.value
                //             ? 'stopServer'.tr
                //             : 'startServer'.tr,
                //       ),
                //     ),
                //   ),
                // ),
                Expanded(
                  child: DefaultTabController(
                    length: 2,
                    child: Column(
                      children: [
                        if (controller.isScanning.value) Text('scanningForDevices'.tr),
                        Text(
                          'nearbyDevices'.trParams({
                            'count': '${controller.peers.length}',
                          }),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: controller.peers.length,
                            itemBuilder: (context, index) {
                              WdPeerInfo device = controller.peers[index];
                              return ListTile(
                                title: Text(device.deviceName ?? 'unknownDevice'.tr),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [Text(device.deviceAddress)],
                                ),
                                leading: Icon(Icons.wifi_tethering),
                                onTap: () async {
                                  // Show loading dialog and track its life:
                                  // the dialog is closed via the root
                                  // navigator (snackbars are overlay entries,
                                  // not routes, so this can never close the
                                  // wrong thing).
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
                                  // A timeout with the peer still deciding is
                                  // NOT a failure: the link is alive and the
                                  // READY frame will open the chat once the
                                  // peer accepts.
                                  if (!controller.isConnected.value &&
                                      !controller.isAwaitingAcceptance) {
                                    Get.snackbar(
                                      'couldNotConnectTitle'.tr,
                                      controller.lastConnectError.value ??
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
                        ),
                      ],
                    ),
                  ),
                ),
                // Primary action: the discovery toggle lives at the bottom
                // as a full-width button (the top row only held it next to
                // the now-hidden server button).
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      style: controller.isScanning.value
                          ? FilledButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            )
                          : null,
                      onPressed: controller.isScanning.value
                          ? controller.stopDiscovery
                          : () async {
                              controller.startDiscovery();
                            },
                      icon: Icon(
                        controller.isScanning.value
                            ? Icons.stop
                            : Icons.wifi_find,
                      ),
                      label: Text(
                        controller.isScanning.value
                            ? 'stopDiscovery'.tr
                            : 'startDiscovery'.tr,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                ],
              ],
            ),
          ),
        );
  }
}
