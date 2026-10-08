import 'dart:async';

import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/device_id_service.dart';
import 'package:chatblue/core/services/nearby_service.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/chat_ui/connection_request.dart';
import 'package:chatblue/screens/n_chatscreen/n_chat_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

String _noopTranslate(String key, {Map<String, String>? params}) => key;

/// Immutable UI state of the Nearby Connections transport.
class NearbyTransportState {
  const NearbyTransportState({
    this.isConnected = false,
    this.isScanning = false,
    this.isBluetoothOn = true,
    this.isPlayServicesAvailable = true,
    this.canAdvertise = true,
    this.peers = const [],
    this.connectedPeer,
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
  final List<NearbyPeerInfo> peers;
  final NearbyPeerInfo? connectedPeer;
  final String? lastDisconnectReason;
  final String? lastConnectError;

  NearbyTransportState copyWith({
    bool? isConnected,
    bool? isScanning,
    bool? isBluetoothOn,
    bool? isPlayServicesAvailable,
    bool? canAdvertise,
    List<NearbyPeerInfo>? peers,
    NearbyPeerInfo? connectedPeer,
    bool clearConnectedPeer = false,
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
      peers: peers ?? this.peers,
      connectedPeer:
          clearConnectedPeer ? null : (connectedPeer ?? this.connectedPeer),
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

  /// Translation hook — installed by the GetX adapter or a ported screen.
  TransportTranslator translate = _noopTranslate;

  /// Dial windows (mutable for tests). On the first timeout a still-pending
  /// attempt holds in "awaiting acceptance" for a second window, mirroring
  /// the WFD behavior — a late accept must still land the chat.
  static Duration connectTimeout = const Duration(seconds: 10);

  /// Session-reconnect discovery budget (mutable for tests).
  static Duration sessionSearchTimeout = const Duration(seconds: 20);
  static Duration sessionSearchPollInterval = const Duration(milliseconds: 900);

  late NearbyService _service;
  bool _chatOpen = false;
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

  // --- ChatTransport surface (consumed by the GetX bridge) ---

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

  Future<void> refreshStatus() async {
    try {
      final status = await _service.getStatus();
      state = state.copyWith(
        isPlayServicesAvailable: status.playServices,
        isBluetoothOn: status.bluetoothEnabled,
        canAdvertise: status.canAdvertise,
      );
    } catch (_) {
      // fail-open: keep the last known state
    }
  }

  /// Opens the system Bluetooth-enable prompt (consent-pref backed natively).
  Future<void> enableBluetooth() async {
    final granted = await _service.requestEnableBluetooth();
    if (!granted) return;
    await refreshStatus();
  }

  Future<void> startScan() async {
    state = state.copyWith(lastConnectError: null);
    await refreshStatus();
    if (!state.isPlayServicesAvailable) {
      state = state.copyWith(lastConnectError: translate('playServicesRequired'));
      return;
    }
    if (!state.isBluetoothOn) {
      // The screen shows the "turn on Bluetooth" panel; never touch native.
      return;
    }
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

  Future<bool> connectToDevice(NearbyPeerInfo peer) =>
      connectToPeer(peer.endpointId);

  Future<bool> connectToPeer(String endpointId) async {
    final Completer<bool> completer = Completer<bool>();
    _pendingConnectCompleter = completer;
    _pendingConnectEndpointId = endpointId;
    _cancelledEndpointId = null;
    _dialSettle = Completer<void>();
    state = state.copyWith(lastConnectError: null);
    if (kDebugMode) debugPrint('Nearby connecting to endpoint: $endpointId');

    if (state.isScanning) {
      await stopScan();
    }

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
        completer.complete(false);
      }
    };

    _service.onConnectionRejected = (rejectedEndpointId) {
      prevRejected?.call(rejectedEndpointId);
      if (rejectedEndpointId == endpointId && !completer.isCompleted) {
        completer.complete(false);
      }
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby socket error during connect: $message');
      }
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
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby error initiating connection: $e');
      }
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
      return result;
    } catch (_) {
      restore();
      return false;
    }
  }

  Future<bool> connectToSessionPeer({required String? address, String? name}) async {
    if (address == null || address.isEmpty) {
      state = state.copyWith(lastConnectError: translate('noDeviceAddressMessage'));
      return false;
    }
    state = state.copyWith(lastConnectError: null);
    await refreshStatus();
    if (!state.isPlayServicesAvailable) {
      state = state.copyWith(lastConnectError: translate('playServicesRequired'));
      return false;
    }
    if (!state.isBluetoothOn) {
      await enableBluetooth();
      if (!state.isBluetoothOn) {
        state = state.copyWith(lastConnectError: translate('btOffForNearby'));
        return false;
      }
    }

    final search = await _discoverSessionPeer(uid: address, name: name);
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
              translate('nearbyTargetNotFound',
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
          lastConnectError: state.lastConnectError ?? translate('nearbyNoDevicesFound'),
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
                  translate('wfdPickDeviceTitle'),
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  translate('wfdPickDeviceHint'),
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
                      title: Text(name.isEmpty ? translate('unknownDevice') : name),
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
        // Feedback for the DECLINING side — until now only the dialer saw a
        // "declined" snackbar (from the rejected event); the receiver's
        // banner just vanished without confirmation.
        scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              '${translate('connectionDeclinedTitle')}: '
              '${translate('connectionDeclinedByYouMessage')}',
            ),
          ),
        );
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
      state = state.copyWith(isScanning: false);
      state = state.copyWith(lastConnectError: message);
      final messenger = scaffoldMessengerKey.currentState;
      messenger?.showSnackBar(
        SnackBar(content: Text('${translate('scanErrorTitle')}: $message')),
      );
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Nearby socket error: $message');
      }
    };

    _service.onSocketData = _dispatchSocketData;
    _service.onConnectionInitiated = _handleConnectionInitiated;

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
      state = state.copyWith(isConnected: true);
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
      final messenger = scaffoldMessengerKey.currentState;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${translate('connectionDeclinedTitle')}: '
            '${translate('connectionDeclinedMessage')}',
          ),
        ),
      );
    };

    _service.onSocketDisconnected = (reason) {
      _settleDial();
      final bool wasConnected = state.isConnected;
      state = state.copyWith(isConnected: false);
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
      state = state.copyWith(isConnected: false);
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
