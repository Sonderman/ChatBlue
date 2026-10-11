import 'dart:async';

import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/device_id_service.dart';
import 'package:chatblue/core/services/nearby_service.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:chatblue/screens/chat_ui/connection_request.dart';
import 'package:chatblue/screens/n_chatscreen/n_chat_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Immutable UI state of the Nearby Connections transport.
class NearbyTransportState {
  const NearbyTransportState({
    this.isConnected = false,
    this.isScanning = false,
    this.isBluetoothOn = true,
    this.isPlayServicesAvailable = true,
    this.canAdvertise = true,
    this.isLocationPermissionGranted = true,
    this.isLocationOn = true,
    this.isLocationEnableInFlight = false,
    this.isWifiOn = true,
    this.peers = const [],
    this.connectedPeer,
    this.linkQuality = 0,
    this.lastDisconnectReason,
    this.lastConnectError,
  });

  final bool isConnected;
  final bool isScanning;
  final bool isBluetoothOn;
  final bool isPlayServicesAvailable;

  /// False when the device's Bluetooth stack cannot advertise over BLE at
  /// all (old budget stacks): the scan screen shows an explanatory note.
  final bool canAdvertise;

  /// Whether a location runtime permission is granted. GMS Nearby refuses
  /// discovery with "8034: MISSING_PERMISSION_ACCESS_COARSE_LOCATION"
  /// without it — the scan screen shows a grant panel while missing.
  final bool isLocationPermissionGranted;

  /// Location master toggle mirror (required for Nearby discovery on many
  /// OEM builds); drives the scan screen's "turn on location" panel.
  final bool isLocationOn;
  final bool isLocationEnableInFlight;

  /// Wi‑Fi radio mirror — informational note only (Nearby can discover over
  /// other mediums, but Wi‑Fi off may hide devices).
  final bool isWifiOn;
  final List<NearbyPeerInfo> peers;
  final NearbyPeerInfo? connectedPeer;

  /// Coarse link-quality code from GMS bandwidth events (0=unknown,
  /// 1=low, 2=medium, 3=high — BandwidthInfo.Quality). 0 until the first
  /// change event of a connection arrives.
  final int linkQuality;

  final String? lastDisconnectReason;
  final String? lastConnectError;

  NearbyTransportState copyWith({
    bool? isConnected,
    bool? isScanning,
    bool? isBluetoothOn,
    bool? isPlayServicesAvailable,
    bool? canAdvertise,
    bool? isLocationPermissionGranted,
    bool? isLocationOn,
    bool? isLocationEnableInFlight,
    bool? isWifiOn,
    List<NearbyPeerInfo>? peers,
    NearbyPeerInfo? connectedPeer,
    bool clearConnectedPeer = false,
    int? linkQuality,
    String? lastDisconnectReason,
    bool clearLastDisconnectReason = false,
    String? lastConnectError,
    bool clearLastConnectError = false,
  }) {
    return NearbyTransportState(
      isConnected: isConnected ?? this.isConnected,
      isScanning: isScanning ?? this.isScanning,
      isBluetoothOn: isBluetoothOn ?? this.isBluetoothOn,
      isPlayServicesAvailable:
          isPlayServicesAvailable ?? this.isPlayServicesAvailable,
      canAdvertise: canAdvertise ?? this.canAdvertise,
      isLocationPermissionGranted:
          isLocationPermissionGranted ?? this.isLocationPermissionGranted,
      isLocationOn: isLocationOn ?? this.isLocationOn,
      isLocationEnableInFlight:
          isLocationEnableInFlight ?? this.isLocationEnableInFlight,
      isWifiOn: isWifiOn ?? this.isWifiOn,
      peers: peers ?? this.peers,
      connectedPeer:
          clearConnectedPeer ? null : (connectedPeer ?? this.connectedPeer),
      linkQuality: linkQuality ?? this.linkQuality,
      lastDisconnectReason: clearLastDisconnectReason
          ? null
          : (lastDisconnectReason ?? this.lastDisconnectReason),
      lastConnectError:
          clearLastConnectError ? null : (lastConnectError ?? this.lastConnectError),
    );
  }
}

/// Orchestrates Nearby Connections through [NearbyService] and exposes
/// reactive UI state (sibling of the Bt/Wd transport notifiers).
///
/// Transport-specific simplifications vs BT/WFD (see the design doc):
/// - Nearby's own accept protocol replaces the READY/identity frames, so the
///   notifier neither sends nor parses handshake frames.
/// - The banner shows ONLY for genuinely remote-initiated requests — the
///   native side marks those with `incoming=true`, so the self-request race
///   class cannot occur by construction.
/// - The peer's stable uid arrives in the endpoint metadata (endpointInfo);
///   it keys the chat session from the first second.
class NearbyTransportNotifier extends Notifier<NearbyTransportState> {
  /// Test hook: inject a fake service instead of the real platform-channel
  /// backed one. Null in production (the real service is created in build).
  NearbyTransportNotifier({NearbyService? service}) : _serviceOverride = service;

  final NearbyService? _serviceOverride;

  /// Context'siz çeviri: güncel locale'in l10n kaynağından okur.
  String _t(String key, {Map<String, String>? params}) =>
      transportKeyToL10n(ref.read(appLocalizationsProvider), key, params: params);

  /// Dial windows (mutable for tests). On the first timeout a still-pending
  /// attempt holds in "awaiting acceptance" for a second window, mirroring
  /// the WFD behavior — a late accept must still land the chat.
  static Duration connectTimeout = const Duration(seconds: 10);

  /// Session-reconnect discovery budget (mutable for tests).
  static Duration sessionSearchTimeout = const Duration(seconds: 20);
  static Duration sessionSearchPollInterval = const Duration(milliseconds: 900);

  late NearbyService _service;
  bool _chatOpen = false;
  bool _locationEnableInFlight = false;
  int _locationEnableGeneration = 0;
  bool _bluetoothEnableInFlight = false;
  bool _pendingAccept = false;
  String? _ownDeviceName;
  String? _ownUid;

  /// Pending dial bookkeeping for the UI "İptal" (connecting panel).
  Completer<bool>? _pendingConnectCompleter;
  String? _pendingConnectEndpointId;
  String? _cancelledEndpointId;
  Completer<void>? _dialSettle;

  /// Completes when the current dial reaches a terminal state (accepted,
  /// rejected, dropped or cancelled) — the connecting panel stays up until
  /// then; the cap prevents a stuck panel if no event ever arrives.
  Future<void> get dialSettled async {
    final s = _dialSettle;
    if (s == null) return;
    await s.future.timeout(const Duration(seconds: 30), onTimeout: () {});
  }

  void _settleDial() {
    final s = _dialSettle;
    if (s != null && !s.isCompleted) s.complete();
  }
  void Function(Uint8List bytes, String text, {required String kind})?
      _chatDataCallback;

  @override
  NearbyTransportState build() {
    _service = _serviceOverride ?? NearbyService();
    _wireCallbacks();
    unawaited(_init());
    ref.onDispose(() {
      _service.dispose();
    });
    return const NearbyTransportState();
  }

  Future<void> _init() async {
    try {
      await _service.initialize();
      if (!ref.mounted) return;
      await refreshStatus();
    } catch (e) {
      if (kDebugMode) debugPrint('Nearby transport init failed: $e');
    }
  }

  // --- ChatTransport surface (consumed by the chat binding + scan screens) ---

  bool get isConnected => state.isConnected;
  bool get isAwaitingAcceptance => _pendingAccept;

  /// Stable per-install uid of the connected peer — Nearby carries it in the
  /// endpoint metadata, so it is known from the first second. Null when the
  /// identity bytes were missing; the base controller then falls back to a
  /// uuid session key.
  String? get connectedDeviceKey => state.connectedPeer?.uid;
  String? get connectedDeviceId => state.connectedPeer?.uid;
  String? get connectedDeviceName => state.connectedPeer?.endpointName;
  String get transportType => 'nearby';

  /// Coarse link-quality code while connected (null when the link is down):
  /// GMS reports it through bandwidth-change events — this transport's only
  /// link metric. 0 (unknown) until the first event of a connection lands.
  int? get linkQuality => state.isConnected ? state.linkQuality : null;

  /// Decline feedback — the themed notice card. One owner per outcome:
  /// raised only by the dialer's main rejection handler and the declining
  /// side; screens skip their own.
  void _showDeclinedNotice(String messageKey) {
    ConnectionNotice.show(
      title: _t('connectionDeclinedTitle'),
      message: _t(messageKey),
      isChatScreen: _chatOpen,
    );
  }

  /// Re-reads the Play Services / Bluetooth / permission / location / Wi‑Fi
  /// status. Public: the scan screen refreshes it on mount and on app
  /// resume so its panels reflect the current system state (the toggles can
  /// change outside the app).
  Future<void> refreshStatus() async {
    try {
      final status = await _service.getStatus();
      state = state.copyWith(
        isPlayServicesAvailable: status.playServices,
        isBluetoothOn: status.bluetoothEnabled,
        canAdvertise: status.canAdvertise,
        isLocationPermissionGranted: status.locationPermission,
        isLocationOn: status.locationEnabled,
        isWifiOn: status.wifiEnabled,
      );
    } catch (_) {
      // fail-open: keep the last known state
    }
  }

  /// Opens the consent flow for enabling Bluetooth and re-reads the status
  /// so the panel clears once the adapter is actually on. Android 13+ apps
  /// cannot enable Bluetooth silently (`BluetoothAdapter.enable()` is a
  /// documented no-op for targetSdk 33+ apps) — the native side then opens
  /// the system dialog directly; below 13 a remembered consent enables
  /// silently.
  Future<void> enableBluetooth() async {
    if (_bluetoothEnableInFlight) return;
    _bluetoothEnableInFlight = true;
    try {
      final granted = await _service.requestEnableBluetooth();
      if (kDebugMode && showDebugLogs) {
        debugPrint('[nearby] enableBluetooth result=$granted');
      }
      if (granted) {
        // The dialog decision (or a silent enable) landed: refresh, with a
        // short poll as a safety net for a lagging adapter flip.
        for (var i = 0; i < 10; i++) {
          await refreshStatus();
          if (state.isBluetoothOn) return;
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } else {
        await refreshStatus();
      }
    } finally {
      _bluetoothEnableInFlight = false;
    }
  }

  /// Re-requests the Nearby runtime permissions (the scan screen's grant
  /// panel) and re-reads the status so the panel clears once the grant
  /// lands.
  Future<void> requestPermissions() async {
    try {
      await _service.requestNearbyPermissions();
    } catch (_) {
      // fail-open: refreshStatus below still reads the real grant state
    }
    if (!ref.mounted) return;
    await refreshStatus();
  }

  /// Opens this app's system settings page (escape hatch when a permission
  /// is permanently denied and the system dialog no longer appears).
  Future<void> openAppSettings() async {
    try {
      await _service.openAppSettings();
    } catch (_) {
      // fail-open
    }
  }

  /// Opens the system location settings and polls until the master toggle
  /// turns on (mirrors the Wi‑Fi Direct flow: 30 x 500 ms window).
  Future<void> enableLocation() async {
    if (_locationEnableInFlight) return;
    _locationEnableInFlight = true;
    final int generation = ++_locationEnableGeneration;
    state = state.copyWith(isLocationEnableInFlight: true);
    try {
      final opened = await _service.requestEnableLocation();
      if (!opened) return;
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (generation != _locationEnableGeneration) return;
        await refreshStatus();
        if (state.isLocationOn) return;
      }
    } finally {
      if (generation == _locationEnableGeneration) {
        _locationEnableInFlight = false;
        if (ref.mounted) {
          state = state.copyWith(isLocationEnableInFlight: false);
        }
      }
    }
  }

  /// Called by the scan screen on mount and app resume: re-reads the full
  /// precondition status and releases a pending "turn on Location" flow so
  /// its button is tappable again immediately after the user returns from
  /// the system settings (it used to stay disabled for the rest of the
  /// flow's 15 s poll window when nothing was changed).
  Future<void> onAppResumed() async {
    _locationEnableGeneration++;
    _locationEnableInFlight = false;
    if (!ref.mounted) return;
    state = state.copyWith(isLocationEnableInFlight: false);
    await refreshStatus();
  }

  Future<void> startScan() async {
    state = state.copyWith(clearLastConnectError: true);
    await refreshStatus();
    if (!state.isPlayServicesAvailable) {
      state = state.copyWith(lastConnectError: _t('playServicesRequired'));
      return;
    }
    if (!state.isBluetoothOn) {
      // The screen shows the "turn on Bluetooth" panel; never touch native.
      return;
    }
    if (!state.isLocationPermissionGranted) {
      // GMS refuses discovery with 8034 while the location permission is
      // missing — the screen shows the grant panel; never touch native.
      return;
    }
    if (!state.isLocationOn) {
      // The screen shows the "turn on Location" panel; never touch native.
      return;
    }
    await _stopOtherTransportScans();
    final name = _ownDeviceName ??= await _resolveOwnDeviceName();
    final uid = _ownUid ??= await DeviceIdService.get();
    if (!ref.mounted) return;
    state = state.copyWith(peers: const [], isScanning: true);
    await _service.startScan(name: name, uid: uid);
  }

  Future<void> stopScan() async {
    await _service.stopScan();
    state = state.copyWith(isScanning: false);
  }

  /// Cross-transport scan exclusion (same rule as the other notifiers):
  /// starting a Nearby scan stops the other transports' scan loops.
  /// Advertise is part of the same Nearby session, so it stops with the
  /// scan; connections and server modes stay untouched.
  Future<void> _stopOtherTransportScans() async {
    if (ref.read(btTransportProvider).isScanning) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby scan: stopping the Bluetooth scan');
      }
      await ref.read(btTransportProvider.notifier).stopScan();
    }
    if (ref.read(wdTransportProvider).isScanning) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby scan: stopping the Wi‑Fi Direct discovery');
      }
      await ref.read(wdTransportProvider.notifier).stopDiscovery();
    }
  }

  Future<bool> connectToDevice(NearbyPeerInfo peer) =>
      connectToPeer(peer.endpointId);

  Future<bool> connectToPeer(String endpointId) async {
    final Completer<bool> completer = Completer<bool>();
    _pendingConnectCompleter = completer;
    _pendingConnectEndpointId = endpointId;
    _cancelledEndpointId = null;
    _dialSettle = Completer<void>();
    state = state.copyWith(clearLastConnectError: true);
    if (kDebugMode) debugPrint('[nearby] connect start: $endpointId');

    // Deliberately NO stopScan() here: the request must go out while
    // discovery is still active (Google's own sample requests from inside
    // onEndpointFound). Stopping it first races stopDiscovery and the
    // request can fail as unknown-endpoint on some OEM stacks. The success
    // path stops the scan natively (onConnectionResult); a failed attempt
    // keeps the list live for an immediate retry.
    final prevConnected = _service.onSocketConnected;
    final prevDisconnected = _service.onSocketDisconnected;
    final prevRejected = _service.onConnectionRejected;
    final prevError = _service.onSocketError;

    void restore() {
      _service.onSocketConnected = prevConnected;
      _service.onSocketDisconnected = prevDisconnected;
      _service.onConnectionRejected = prevRejected;
      _service.onSocketError = prevError;
      _pendingConnectCompleter = null;
    }

    _service.onSocketConnected = (peer) {
      prevConnected?.call(peer);
      if (peer.endpointId == endpointId && !completer.isCompleted) {
        completer.complete(true);
      }
    };

    _service.onSocketDisconnected = (reason) {
      prevDisconnected?.call(reason);
      if (!completer.isCompleted) {
        // A teardown mid-dial — surface why instead of the generic message.
        if (kDebugMode) debugPrint('[nearby] connect dropped: $reason');
        state = state.copyWith(lastConnectError: 'Dropped: $reason');
        completer.complete(false);
      }
    };

    _service.onConnectionRejected = (rejectedEndpointId) {
      prevRejected?.call(rejectedEndpointId);
      if (rejectedEndpointId == endpointId && !completer.isCompleted) {
        // Give the screen's failure snackbar an accurate reason instead of
        // the generic "make sure the device is discoverable" message.
        if (kDebugMode) {
          debugPrint('[nearby] connect rejected: $rejectedEndpointId');
        }
        state = state.copyWith(
          lastConnectError: _t('connectionDeclinedMessage'),
        );
        // The decline feedback itself is raised by the main rejection
        // handler (chained above via prevRejected) — one surface, not two.
        completer.complete(false);
      }
    };

    _service.onSocketError = (message) {
      if (kDebugMode) debugPrint('[nearby] connect socket error: $message');
      state = state.copyWith(lastConnectError: message);
      if (!completer.isCompleted) {
        ConnectionRequestBanner.dismiss();
        _pendingAccept = false;
        completer.complete(false);
      }
    };

    try {
      final name = _ownDeviceName ??= await _resolveOwnDeviceName();
      final uid = _ownUid ??= await DeviceIdService.get();
      await _service.connect(endpointId, uid: uid, name: name);
    } catch (e) {
      if (kDebugMode) debugPrint('Nearby error initiating connection: $e');
      // Surface the reason: a throw here (e.g. a native-side error) used to
      // fail silently with the generic "could not connect" snackbar.
      state = state.copyWith(lastConnectError: 'Connect error: $e');
      restore();
      return false;
    }

    try {
      final bool result = await completer.future.timeout(
        connectTimeout,
        onTimeout: () async {
          final bool connected = await _service.isConnected();
          if (connected) return true;
          _pendingAccept = true;
          if (kDebugMode) {
            debugPrint('[nearby] connect timeout; awaiting acceptance');
          }
          return completer.future.timeout(
            connectTimeout,
            onTimeout: () => _service.isConnected(),
          );
        },
      );
      restore();
      if (!result) {
        ConnectionRequestBanner.dismiss();
      }
      if (kDebugMode) debugPrint('[nearby] connect result: $result');
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('Nearby connect wait failed: $e');
      state = state.copyWith(lastConnectError: 'Connect wait error: $e');
      restore();
      return false;
    }
  }

  Future<bool> connectToSessionPeer({required String? address, String? name}) async {
    final uid = (address ?? '').trim();
    final target = (name ?? '').trim();
    // A name-only search is legitimate: a cross-transport pick from a chat
    // that never learned this peer's Nearby uid arrives address-less, and
    // the search then matches by name (the endpoint's display name).
    if (uid.isEmpty && target.isEmpty) {
      state = state.copyWith(lastConnectError: _t('noDeviceAddressMessage'));
      return false;
    }
    state = state.copyWith(clearLastConnectError: true);
    await refreshStatus();
    if (!state.isPlayServicesAvailable) {
      state = state.copyWith(lastConnectError: _t('playServicesRequired'));
      return false;
    }
    if (!state.isBluetoothOn) {
      await enableBluetooth();
      if (!state.isBluetoothOn) {
        state = state.copyWith(lastConnectError: _t('btOffForNearby'));
        return false;
      }
    }
    // Location pre-flight (same as the scan gate): a missing permission or
    // a master toggle off makes discovery fail — offer the grant / settings
    // path instead of a misleading "no devices found".
    if (!state.isLocationPermissionGranted) {
      await requestPermissions();
      if (!state.isLocationPermissionGranted) {
        state = state.copyWith(
          lastConnectError: _t('nearbyLocationPermissionMissing'),
        );
        return false;
      }
    }
    if (!state.isLocationOn) {
      await enableLocation();
      if (!state.isLocationOn) {
        state = state.copyWith(lastConnectError: _t('locationOffTitle'));
        return false;
      }
    }

    final search = await _discoverSessionPeer(
      uid: uid,
      name: target.isEmpty ? null : target,
    );
    if (state.isConnected) return true;
    final match = search.match;
    if (match != null) {
      return connectToPeer(match.endpointId);
    }
    if (search.candidates.isNotEmpty) {
      final picked = await _promptPeerSelection(search.candidates);
      if (picked == null) {
        state = state.copyWith(
          lastConnectError: state.lastConnectError ??
              _t('nearbyTargetNotFound',
                  params: {'count': '${search.candidates.length}'}),
        );
        return false;
      }
      return connectToPeer(picked.endpointId);
    }
    return false;
  }

  Future<({NearbyPeerInfo? match, List<NearbyPeerInfo> candidates})>
      _discoverSessionPeer({required String uid, required String? name}) async {
    state = state.copyWith(peers: const []);
    ({NearbyPeerInfo? match, List<NearbyPeerInfo> candidates}) settle() =>
        (match: null, candidates: state.peers.toList());
    try {
      await startScan();
      if (!state.isScanning) {
        // Preconditions blocked the scan; startScan recorded the reason.
        return settle();
      }
      final deadline = DateTime.now().add(sessionSearchTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(sessionSearchPollInterval);
        if (state.isConnected) return settle();
        final match = _matchSessionPeer(state.peers, uid: uid, name: name);
        if (match != null) {
          return (match: match, candidates: state.peers.toList());
        }
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint(
          'Nearby session search: no target among '
          '${state.peers.map((p) => p.endpointName.isEmpty ? p.endpointId : p.endpointName).toList()}',
        );
      }
      if (state.peers.isEmpty) {
        state = state.copyWith(
          lastConnectError: state.lastConnectError ?? _t('nearbyNoDevicesFound'),
        );
      }
      return settle();
    } catch (e) {
      state = state.copyWith(lastConnectError: e.toString());
      return settle();
    } finally {
      if (state.isScanning) {
        state = state.copyWith(isScanning: false);
        unawaited(_service.stopScan());
      }
    }
  }

  /// uid match first (stable identity), then normalized device name (the
  /// endpoint's display name is the device model).
  NearbyPeerInfo? _matchSessionPeer(
    List<NearbyPeerInfo> candidates, {
    required String uid,
    required String? name,
  }) {
    final String targetName = _normalizeDeviceName(name);
    NearbyPeerInfo? byName;
    for (final peer in candidates) {
      if (peer.uid != null && peer.uid == uid) return peer;
      if (byName == null &&
          targetName.isNotEmpty &&
          _normalizeDeviceName(peer.endpointName) == targetName) {
        byName = peer;
      }
    }
    return byName;
  }

  String _normalizeDeviceName(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  /// GMS refusals carry raw texts like "startDiscovery failed: 8034:
  /// MISSING_PERMISSION_ACCESS_COARSE_LOCATION" — swap the permission case
  /// for an actionable, localized message (the panel offers the fix path).
  String _friendlyScanError(String message) {
    if (message.contains('8034') ||
        message.contains('MISSING_PERMISSION_ACCESS_COARSE_LOCATION')) {
      return _t('nearbyLocationPermissionMissing');
    }
    return message;
  }

  Future<NearbyPeerInfo?> _promptPeerSelection(List<NearbyPeerInfo> candidates) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return Future<NearbyPeerInfo?>.value();
    return showModalBottomSheet<NearbyPeerInfo>(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (sheetContext) => SafeArea(
        child: Material(
          color: Theme.of(sheetContext).cardColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  _t('wfdPickDeviceTitle'),
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _t('wfdPickDeviceHint'),
                  style: Theme.of(sheetContext).textTheme.bodySmall,
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (context, index) {
                    final peer = candidates[index];
                    final name = peer.endpointName.trim();
                    return ListTile(
                      leading: const Icon(Icons.sensors),
                      title: Text(name.isEmpty ? _t('unknownDevice') : name),
                      subtitle: Text(peer.uid ?? peer.endpointId),
                      onTap: () => Navigator.of(sheetContext).pop(peer),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _openChat() {
    if (_chatOpen) return;
    _chatOpen = true;
    final nav = navigatorKey.currentState;
    if (nav == null) return; // no UI mounted (tests / cold start)
    // No dialog dismissal here: ModalRoute.of(nav.overlay.context) is
    // ALWAYS null (the overlay element sits above every route scope), so
    // the old DialogRoute check was a silent no-op. The scan screens close
    // their own loading dialog by route reference after connect completes.
    nav.push(
      MaterialPageRoute(
        builder: (_) => const NChatScreen(),
        settings: const RouteSettings(name: 'NChatScreen'),
      ),
    );
  }

  void _handleConnectionInitiated(
    NearbyPeerInfo peer, {
    required bool incoming,
    required String authDigits,
  }) {
    if (kDebugMode && showDebugLogs) {
      debugPrint(
        'Nearby connection initiated: ${peer.endpointName} '
        '(incoming=$incoming, auth=$authDigits)',
      );
    }
    if (!incoming) {
      // Our own dial — native auto-accepts; no banner ever (the native side
      // marks incoming=true only for genuinely remote-initiated requests).
      return;
    }
    _showIncomingRequest(peer);
  }

  void _showIncomingRequest(NearbyPeerInfo peer) {
    ConnectionRequestBanner.show(
      deviceName: peer.endpointName,
      isChatScreen: _chatOpen,
      onAccept: () {
        if (_chatOpen) return;
        // Native accepts; the live 'connected' event flips the state and
        // opens the chat — both sides have accepted by then.
        unawaited(_service.accept(peer.endpointId));
      },
      onDecline: () {
        unawaited(_service.reject(peer.endpointId));
        // Feedback for the DECLINING side — without it the receiver's
        // banner just vanished without confirmation (the dialer side gets
        // the mirrored notice from its transport).
        _showDeclinedNotice('connectionDeclinedByYouMessage');
      },
      onTimeout: () {
        // Expiry is not a user decision: reject silently (no snackbar).
        unawaited(_service.reject(peer.endpointId));
      },
    );
  }

  /// No handshake frames over this transport: the payload stream is chat
  /// data only (the design's READY/identity-frame equivalents live in the
  /// native accept protocol and the endpoint metadata).
  void _dispatchSocketData(
    Uint8List bytes,
    String text, {
    required String kind,
  }) {
    _chatDataCallback?.call(bytes, text, kind: kind);
  }

  void _wireCallbacks() {
    _service.onScanStarted = () {
      state = state.copyWith(isScanning: true);
    };

    _service.onScanFinished = () {
      state = state.copyWith(isScanning: false);
    };

    _service.onPeerFound = (peer) {
      if (kDebugMode && showDebugLogs) {
        debugPrint(
          'Nearby endpoint found: ${peer.endpointName} '
          '(${peer.endpointId}) uid=${peer.uid}',
        );
      }
      if (!state.peers.any((p) => p.endpointId == peer.endpointId)) {
        state = state.copyWith(peers: [...state.peers, peer]);
      }
    };

    _service.onEndpointLost = (endpointId) {
      state = state.copyWith(
        peers: state.peers.where((p) => p.endpointId != endpointId).toList(),
      );
    };

    _service.onScanError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby scan error: $message');
      }
      final friendly = _friendlyScanError(message);
      state = state.copyWith(isScanning: false);
      state = state.copyWith(lastConnectError: friendly);
      ConnectionNotice.show(
        title: _t('scanErrorTitle'),
        message: friendly,
        isChatScreen: _chatOpen,
        icon: Icons.error_outline,
      );
      // The panels are status-driven: re-read it so a permission or
      // location change surfaced by this failure shows up immediately.
      unawaited(refreshStatus());
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby socket error: $message');
      }
    };

    _service.onSocketData = _dispatchSocketData;
    _service.onConnectionInitiated = _handleConnectionInitiated;

    _service.onBandwidthChanged = (quality) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby link quality: $quality');
      }
      state = state.copyWith(linkQuality: quality);
    };

    _service.onSocketConnected = (peer) {
      _settleDial();
      if (_cancelledEndpointId != null &&
          peer.endpointId == _cancelledEndpointId) {
        // The user cancelled this dial; a late accept must not land a link
        // (or a chat screen) behind their back.
        _cancelledEndpointId = null;
        unawaited(_service.disconnect());
        return;
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby connected: ${peer.endpointName} (${peer.endpointId})');
      }
      // A fresh connection starts with an unknown quality: a stale code
      // from the previous link must never leak through.
      state = state.copyWith(isConnected: true, linkQuality: 0);
      state = state.copyWith(peers: const []);
      state = state.copyWith(isScanning: false);
      state = state.copyWith(connectedPeer: peer);
      _pendingAccept = false;
      _openChat();
    };

    _service.onConnectionRejected = (endpointId) {
      _settleDial();
      if (_cancelledEndpointId != null &&
          endpointId == _cancelledEndpointId) {
        // Rejection of a cancelled dial is expected — stay silent.
        _cancelledEndpointId = null;
        _pendingAccept = false;
        return;
      }
      _pendingAccept = false;
      // Single decline surface for the dialer: this handler. The dial
      // attempt's own rejection hook (connectToPeer) stays silent — it
      // used to raise a second surface for the same rejection and the
      // two stacked on screen.
      _showDeclinedNotice('connectionDeclinedMessage');
    };

    _service.onSocketDisconnected = (reason) {
      _settleDial();
      final bool wasConnected = state.isConnected;
      state = state.copyWith(isConnected: false, linkQuality: 0);
      ConnectionRequestBanner.dismiss();
      _pendingAccept = false;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby disconnected: $reason');
      }
      if (wasConnected) {
        state = state.copyWith(lastDisconnectReason: reason);
      }
    };
  }

  Future<void> disconnectFromDevice() async {
    if (state.isConnected) {
      await _service.disconnect();
      state = state.copyWith(isConnected: false, linkQuality: 0);
    }
  }

  /// UI "İptal" on the connecting panel: abandons the pending dial (its wait
  /// resolves as a cancellation — callers skip the failure snackbar) and a
  /// late accept is suppressed: the fresh link is disconnected instead of
  /// opening a chat (guards in the wire callbacks below).
  Future<void> cancelPendingConnect() async {
    _settleDial();
    final c = _pendingConnectCompleter;
    final target = _pendingConnectEndpointId;
    _pendingConnectCompleter = null;
    if (c == null || c.isCompleted) return;
    _cancelledEndpointId = target;
    await _service.cancelConnect();
    if (!c.isCompleted) c.complete(false);
  }

  void onChatOpened() => _chatOpen = true;

  void onChatClosed() => _chatOpen = false;

  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) {
    _chatDataCallback = callback;
  }

  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) {
    _service.onTransferProgress = callback;
  }

  Future<void> sendMessage(String message) async {
    if (state.isConnected) {
      await _service.sendString(message);
    }
  }

  Future<void> sendBytes(Uint8List bytes) async {
    if (state.isConnected) {
      await _service.sendBytes(bytes);
    }
  }

  /// Best-effort user-visible name for our identity bytes: the OS/BT device
  /// name first (what peers should see in their lists and banners), the
  /// hardware model code as the last resort.
  Future<String> _resolveOwnDeviceName() async {
    final native = (await _service.getDeviceName()).trim();
    if (kDebugMode && showDebugLogs) {
      debugPrint(
        'Nearby own display name: "$native"'
        '${native.isEmpty ? ' (native empty — falling back to the model code)' : ''}',
      );
    }
    if (native.isNotEmpty) return native;
    try {
      return (await DeviceInfoPlugin().androidInfo).model.trim();
    } catch (_) {
      return '';
    }
  }
}

/// Global Nearby Connections transport (app-wide singleton; service lifetime).
final nearbyTransportProvider =
    NotifierProvider<NearbyTransportNotifier, NearbyTransportState>(
  NearbyTransportNotifier.new,
);
