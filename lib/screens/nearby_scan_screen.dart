// Nearby Connections scan screen: advertise + discover together, endpoint
// list, and connect. Riverpod transport notifier (same pattern as the WFD
// screen); the WFD-specific server mode has no Nearby equivalent.
import 'package:chatblue/core/services/nearby_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connecting_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NearbyScanScreen extends ConsumerWidget {
  const NearbyScanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(nearbyTransportProvider);
    final notifier = ref.read(nearbyTransportProvider.notifier);
    notifier.translate = (key, {params}) =>
        transportKeyToL10n(l10n, key, params: params);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.discoverConnectNearbyTitle),
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Play Services missing: Nearby cannot run at all.
          if (!state.isPlayServicesAvailable)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    l10n.playServicesRequired,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            )
          // Bluetooth off: nothing can be advertised/discovered.
          else if (!state.isBluetoothOn)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.btOffForNearby,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: notifier.enableBluetooth,
                        icon: const Icon(Icons.bluetooth),
                        label: Text(l10n.enableBluetooth),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            Expanded(
              child: Column(
                children: [
                  // Old budget stacks (e.g. SM-G610F) cannot advertise at
                  // all — Nearby's advertise Task still reports success, so
                  // this note is the only in-app signal that other devices
                  // will never discover this one.
                  if (!state.canAdvertise)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.orange.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline,
                              size: 18,
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.nearbyAdvertisingUnavailable,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (state.isScanning) Text(l10n.scanningForDevices),
                  Text(l10n.nearbyDevices('${state.peers.length}')),
                  Expanded(
                    child: ListView.builder(
                      itemCount: state.peers.length,
                      itemBuilder: (context, index) {
                        NearbyPeerInfo device = state.peers[index];
                        return ListTile(
                          title: Text(
                            device.endpointName.isEmpty
                                ? l10n.unknownDevice
                                : device.endpointName,
                          ),
                          subtitle: Text(device.uid ?? device.endpointId),
                          leading: const Icon(Icons.sensors),
                          onTap: () async {
                            // Cancellable connecting panel (bottom sheet,
                            // closed by route reference — the chat push may
                            // land while it is still up).
                            final outcome = await showConnectingPanel(
                              context: context,
                              deviceName: device.endpointName.trim().isEmpty
                                  ? null
                                  : device.endpointName.trim(),
                              connect: () async {
                                final ok =
                                    await notifier.connectToDevice(device);
                                if (!ok && !notifier.isAwaitingAcceptance) {
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
                            final isConnected =
                                ref.read(nearbyTransportProvider).isConnected;
                            final awaiting = notifier.isAwaitingAcceptance;
                            if (!isConnected && !awaiting) {
                              messenger?.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${l10n.couldNotConnectTitle}: '
                                    '${ref.read(nearbyTransportProvider).lastConnectError ?? l10n.couldNotConnectMessage}',
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
                            // On success the notifier navigates to the chat
                            // screen itself.
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            // Primary action: the advertise+discover toggle at the bottom.
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
                      ? notifier.stopScan
                      : notifier.startScan,
                  icon: Icon(
                    state.isScanning ? Icons.stop : Icons.search,
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
