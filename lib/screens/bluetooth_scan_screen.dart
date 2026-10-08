// DeviceScanScreen for discovering nearby Bluetooth devices and connecting
// to them. Riverpod transport notifier (ported from the GetX controller).
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connecting_panel.dart';
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
                              trailing: _buildSignalIndicator(context, device.rssi),
                              onTap: () => _connect(
                                context,
                                ref,
                                l10n,
                                () => notifier.connectToDevice(device),
                                deviceName: device.name,
                                rssi: device.rssi,
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
                                deviceName: device.name,
                                rssi: device.rssi,
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
    Future<bool> Function() attempt, {
    String? deviceName,
    int? rssi,
  }) async {
    // Cancellable connecting panel (bottom sheet, closed by route reference
    // — the chat push may land while it is still up).
    bool? connected;
    Object? error;
    final outcome = await showConnectingPanel(
      context: context,
      deviceName: deviceName,
      qualityLabel: rssi == null ? null : _signalQualityLabel(l10n, rssi),
      connect: () async {
        try {
          connected = await attempt();
        } catch (e) {
          error = e;
          return;
        }
        // Keep the panel up until the peer accepts (or the dial dies):
        // a socket-connect alone is not an accepted link yet.
        if (connected == false &&
            !ref.read(btTransportProvider.notifier).isAwaitingAcceptance) {
          return;
        }
        await ref.read(btTransportProvider.notifier).dialSettled;
      },
      onCancel: ref.read(btTransportProvider.notifier).cancelPendingConnect,
    );
    if (outcome == ConnectingOutcome.cancelled) return;
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

  /// RSSI → 0-4 quality level (shared by the list indicator and the
  /// connecting panel's quality line).
  int _signalLevel(int rssi) {
    if (rssi >= -50) return 4;
    if (rssi >= -60) return 3;
    if (rssi >= -70) return 2;
    if (rssi >= -80) return 1;
    return 0;
  }

  /// Human-readable quality line for the connecting panel (BT is the only
  /// transport with a caller-available signal metric — the scan RSSI).
  String _signalQualityLabel(AppLocalizations l10n, int rssi) {
    String word;
    switch (_signalLevel(rssi)) {
      case 4:
        word = l10n.signalStrong;
        break;
      case 3:
        word = l10n.signalGood;
        break;
      case 2:
        word = l10n.signalFair;
        break;
      default:
        word = l10n.signalWeak;
    }
    return '${l10n.signalLabel}: $word ($rssi dBm)';
  }

  // Builds a signal strength indicator based on RSSI (in dBm).
  // Higher (closer to 0) values indicate stronger signal.
  Widget _buildSignalIndicator(BuildContext context, int? rssi) {
    if (rssi == null) return const SizedBox.shrink();

    IconData icon;
    switch (_signalLevel(rssi)) {
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
        Text(
          '$rssi dBm',
          style: TextStyle(
            fontSize: 10,
            // Theme-aware: the old hardcoded dark color vanished on dark
            // themes.
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
      ],
    );
  }
}