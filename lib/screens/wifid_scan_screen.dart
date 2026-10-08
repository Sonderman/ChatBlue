// Wi‑Fi Direct scan screen: discovery, peer list, and connect. Riverpod
// transport notifier (ported from the GetX controller).
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connecting_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class WifiDirectScanScreen extends ConsumerWidget {
  const WifiDirectScanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(wdTransportProvider);
    final notifier = ref.read(wdTransportProvider.notifier);
    notifier.translate = (key, {params}) =>
        transportKeyToL10n(l10n, key, params: params);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discoverConnectWifiTitle),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Wi‑Fi off: nothing can be discovered/connected — show a
          // "turn on Wi‑Fi" panel button instead of the scan controls.
          if (!state.isWifiOn)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.wifiOffTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: state.isWifiEnableInFlight
                            ? null
                            : notifier.enableWifi,
                        icon: const Icon(Icons.wifi),
                        label: Text(l10n.enableWifi),
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
            //             state.isServerModeActive
            //                 ? Colors.green
            //                 : null,
            //         foregroundColor:
            //             state.isServerModeActive
            //                 ? Colors.white
            //                 : null,
            //       ),
            //       onPressed:
            //           state.isServerModeActive
            //               ? notifier.stopServer
            //               : () async {
            //                   notifier.startServer();
            //                 },
            //       child: Text(
            //         state.isServerModeActive
            //             ? l10n.stopServer
            //             : l10n.startServer,
            //       ),
            //     ),
            //   ),
            // ),
            Expanded(
              child: DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    if (state.isScanning) Text(l10n.scanningForDevices),
                    Text(l10n.nearbyDevices('${state.peers.length}')),
                    Expanded(
                      child: ListView.builder(
                        itemCount: state.peers.length,
                        itemBuilder: (context, index) {
                          WdPeerInfo device = state.peers[index];
                          return ListTile(
                            title: Text(
                              device.deviceName ?? l10n.unknownDevice,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [Text(device.deviceAddress)],
                            ),
                            leading: const Icon(Icons.wifi_tethering),
                            onTap: () async {
                              // Cancellable connecting panel (bottom sheet,
                              // closed by route reference — the chat push
                              // may land while it is still up).
                              final outcome = await showConnectingPanel(
                                context: context,
                                deviceName:
                                    (device.deviceName?.trim().isEmpty ??
                                            true)
                                        ? null
                                        : device.deviceName!.trim(),
                                connect: () async {
                                  final ok =
                                      await notifier.connectToDevice(device);
                                  if (!ok &&
                                      !notifier.isAwaitingAcceptance) {
                                    return;
                                  }
                                  await notifier.dialSettled;
                                },
                                onCancel: notifier.cancelPendingConnect,
                              );
                              if (outcome == ConnectingOutcome.cancelled) {
                                return;
                              }
                              final messenger =
                                  scaffoldMessengerKey.currentState;
                              // A timeout with the peer still deciding is
                              // NOT a failure: the link is alive and the
                              // READY frame will open the chat once the
                              // peer accepts.
                              final isConnected =
                                  ref.read(wdTransportProvider).isConnected;
                              final awaiting = notifier.isAwaitingAcceptance;
                              if (!isConnected && !awaiting) {
                                messenger?.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n.couldNotConnectTitle}: '
                                      '${ref.read(wdTransportProvider).lastConnectError ?? l10n.couldNotConnectMessage}',
                                    ),
                                  ),
                                );
                              } else if (!isConnected) {
                                messenger?.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${l10n.waitingAcceptanceTitle}: '
                                      '${l10n.waitingAcceptanceMessage}',
                                    ),
                                  ),
                                );
                              }
                              // On success the notifier navigates to the
                              // chat screen itself. `connected` mirrors the
                              // pre-port semantics (see BT screen).
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
                  style: state.isScanning
                      ? FilledButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        )
                      : null,
                  onPressed: state.isScanning
                      ? notifier.stopDiscovery
                      : () async {
                          notifier.startDiscovery();
                        },
                  icon: Icon(
                    state.isScanning ? Icons.stop : Icons.wifi_find,
                  ),
                  label: Text(
                    state.isScanning
                        ? l10n.stopDiscovery
                        : l10n.startDiscovery,
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
    );
  }
}