// Nearby Connections scan screen: advertise + discover together, endpoint
// list, and connect. Riverpod transport notifier (same pattern as the WFD
// screen, panels included): preconditions are tracked in live state —
// Play Services, Bluetooth, the location permission (GMS discovery refuses
// with 8034 without ACCESS_COARSE_LOCATION), the location master toggle and
// the Wi‑Fi radio — and each missing one gets its own panel/note instead of
// a raw native failure.
import 'dart:async';

import 'package:chatblue/core/services/nearby_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connecting_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class NearbyScanScreen extends ConsumerStatefulWidget {
  const NearbyScanScreen({super.key});

  @override
  ConsumerState<NearbyScanScreen> createState() => _NearbyScanScreenState();
}

class _NearbyScanScreenState extends ConsumerState<NearbyScanScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Fresh precondition + flow state on mount: permissions and the
    // location / Wi‑Fi / Bluetooth toggles can change outside the app
    // between visits.
    unawaited(ref.read(nearbyTransportProvider.notifier).onAppResumed());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    // The user may have flipped the location / Wi‑Fi / Bluetooth toggles in
    // the system settings we opened (or via quick settings) — re-read on
    // return so the panels reflect it, and release a pending "turn on
    // Location" flow so its button is tappable again right away.
    if (lifecycleState == AppLifecycleState.resumed) {
      unawaited(ref.read(nearbyTransportProvider.notifier).onAppResumed());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(nearbyTransportProvider);
    final notifier = ref.read(nearbyTransportProvider.notifier);

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
          // Location permission missing: GMS discovery refuses with
          // "8034: MISSING_PERMISSION_ACCESS_COARSE_LOCATION". The primary
          // button re-triggers the system dialog; the text button opens the
          // app's settings page for the permanently-denied case.
          else if (!state.isLocationPermissionGranted)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.nearbyLocationPermissionMissing,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: notifier.requestPermissions,
                        icon: const Icon(Icons.location_on_outlined),
                        label: Text(l10n.grantPermissions),
                      ),
                      TextButton(
                        onPressed: notifier.openAppSettings,
                        child: Text(l10n.openAppSettings),
                      ),
                    ],
                  ),
                ),
              ),
            )
          // Location off: discovery fails on many OEM builds (MIUI/HyperOS)
          // while the master toggle is off — same panel pattern as the WFD
          // screen, with a shortcut into the system location settings.
          else if (!state.isLocationOn)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.locationOffTitle,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: state.isLocationEnableInFlight
                            ? null
                            : notifier.enableLocation,
                        icon: const Icon(Icons.location_on_outlined),
                        label: Text(l10n.enableLocation),
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
                  // Wi‑Fi off: informational (Nearby can fall back to other
                  // mediums, but discovery may miss devices).
                  if (!state.isWifiOn)
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
                              Icons.wifi_off,
                              size: 18,
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                l10n.nearbyWifiOffNote,
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
                            final isConnected =
                                ref.read(nearbyTransportProvider).isConnected;
                            final awaiting = notifier.isAwaitingAcceptance;
                            if (!isConnected && !awaiting) {
                              // A declined request is announced by the
                              // transport's notice card — don't stack a
                              // second notice card on top of it.
                              if (ref
                                      .read(nearbyTransportProvider)
                                      .lastConnectError ==
                                  l10n.connectionDeclinedMessage) {
                                return;
                              }
                              ConnectionNotice.show(
                                title: l10n.couldNotConnectTitle,
                                message: ref
                                        .read(nearbyTransportProvider)
                                        .lastConnectError ??
                                    l10n.couldNotConnectMessage,
                                icon: Icons.error_outline,
                              );
                            } else if (!isConnected) {
                              ConnectionNotice.show(
                                title: l10n.waitingAcceptanceTitle,
                                message: l10n.waitingAcceptanceMessage,
                                icon: Icons.hourglass_top,
                                accent: Colors.amber,
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
