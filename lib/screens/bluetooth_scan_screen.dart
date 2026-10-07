// DeviceScanScreen for discovering nearby Bluetooth devices and connecting
// to them. Riverpod transport notifier (ported from the GetX controller).
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BluetoothScanScreen extends ConsumerWidget {
  const BluetoothScanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(btTransportProvider);
    final notifier = ref.read(btTransportProvider.notifier);
    notifier.translate = (key, {params}) =>
        transportKeyToL10n(l10n, key, params: params);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.discoverConnectTitle), centerTitle: true),
      body: Column(
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
                        backgroundColor:
                            state.isServerModeActive ? Colors.green : null,
                        foregroundColor:
                            state.isServerModeActive ? Colors.white : null,
                      ),
                      onPressed: state.isServerModeActive
                          ? notifier.stopServer
                          : () async {
                              notifier.startServer();
                            },
                      child: Text(
                        state.isServerModeActive
                            ? l10n.stopDiscoverable
                            : l10n.makeDiscoverable,
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
                        backgroundColor: state.isScanning ? Colors.green : null,
                        foregroundColor: state.isScanning ? Colors.white : null,
                      ),
                      onPressed: state.isScanning
                          ? notifier.stopScan
                          : () async {
                              notifier.startScan();
                            },
                      child: Text(
                        state.isScanning ? l10n.stopScanning : l10n.scanForDevices,
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
                      Tab(text: l10n.nearbyDevices('${state.scanResults.length}')),
                      Tab(text: l10n.pairedDevices('${state.pairedDevices.length}')),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        ListView.builder(
                          itemCount: state.scanResults.length,
                          itemBuilder: (context, index) {
                            BtDeviceInfo device = state.scanResults[index];
                            return ListTile(
                              title: Text(device.name ?? l10n.unknownDevice),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [Text(device.address)],
                              ),
                              leading: const Icon(Icons.bluetooth),
                              trailing: _buildSignalIndicator(device.rssi),
                              onTap: () => _connect(
                                context,
                                ref,
                                l10n,
                                () => notifier.connectToDevice(device),
                              ),
                            );
                          },
                        ),
                        // Paired/bonded devices tab
                        ListView.builder(
                          itemCount: state.pairedDevices.length,
                          itemBuilder: (context, index) {
                            BtDeviceInfo device = state.pairedDevices[index];
                            return ListTile(
                              title: Text(device.name ?? l10n.unknownDevice),
                              subtitle: Text(
                                '${device.address} | ${l10n.previouslyConnected}',
                              ),
                              leading: const Icon(Icons.phone_android),
                              trailing: const Icon(Icons.link, color: Colors.blue),
                              onTap: () => _connect(
                                context,
                                ref,
                                l10n,
                                () => notifier.connectToDevice(device),
                              ),
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
    );
  }

  /// Runs [attempt] behind a loading dialog and reports the outcome with
  /// the same semantics as the pre-port flow: a timeout with the peer still
  /// deciding is NOT a failure (the READY frame opens the chat late).
  Future<void> _connect(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Future<bool> Function() attempt,
  ) async {
    var loading = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).then((_) => loading = false);

    bool? connected;
    Object? error;
    try {
      connected = await attempt();
    } catch (e) {
      error = e;
    }

    if (loading && context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    final messenger = scaffoldMessengerKey.currentState;
    if (error != null) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.connectionError}: ${l10n.connectErrorDetail('$error')}',
          ),
        ),
      );
      return;
    }
    final isConnected = ref.read(btTransportProvider).isConnected;
    final awaiting = ref.read(btTransportProvider.notifier).isAwaitingAcceptance;
    if (connected == false && !isConnected && !awaiting) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.couldNotConnectTitle}: ${l10n.couldNotConnectMessage}',
          ),
        ),
      );
    } else if (connected == false && !isConnected) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.waitingAcceptanceTitle}: ${l10n.waitingAcceptanceMessage}',
          ),
        ),
      );
    }
    // On success the notifier navigates to the chat screen itself.
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