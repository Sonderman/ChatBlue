import 'dart:async';

import 'package:chatblue/config.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/device_id_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/screens/chat_ui/connection_request.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Key-based translation hook used by the transport notifiers for their
/// snackbar/bottom-sheet strings. The GetX adapter installs `.tr`; a ported
/// screen installs [transportKeyToL10n]. Fallback: the raw key.
typedef TransportTranslator =
    String Function(String key, {Map<String, String>? params});

String _noopTranslate(String key, {Map<String, String>? params}) => key;

/// Key→AppLocalizations mapping used by ported screens to install the
/// transport notifiers' translation hook (the GetX adapter installs `.tr`
/// instead). F4'te notifier'lar doğrudan AppLocalizations kullanır.
String transportKeyToL10n(
  AppLocalizations l10n,
  String key, {
  Map<String, String>? params,
}) {
  switch (key) {
    case 'scanErrorTitle':
      return l10n.scanErrorTitle;
    case 'connectionDeclinedTitle':
      return l10n.connectionDeclinedTitle;
    case 'connectionDeclinedMessage':
      return l10n.connectionDeclinedMessage;
    case 'connectionDeclinedByYouMessage':
      return l10n.connectionDeclinedByYouMessage;
    case 'noDeviceAddressMessage':
      return l10n.noDeviceAddressMessage;
    case 'wifiOffTitle':
      return l10n.wifiOffTitle;
    case 'wfdNoDevicesFound':
      return l10n.wfdNoDevicesFound;
    case 'wfdTargetNotFound':
      return l10n.wfdTargetNotFound(params?['count'] ?? '');
    case 'wfdPickDeviceTitle':
      return l10n.wfdPickDeviceTitle;
    case 'wfdPickDeviceHint':
      return l10n.wfdPickDeviceHint;
    case 'unknownDevice':
      return l10n.unknownDevice;
    case 'playServicesRequired':
      return l10n.playServicesRequired;
    case 'btOffForNearby':
      return l10n.btOffForNearby;
    case 'nearbyNoDevicesFound':
      return l10n.nearbyNoDevicesFound;
    case 'nearbyTargetNotFound':
      return l10n.nearbyTargetNotFound(params?['count'] ?? '');
  }
  return key;
}

/// ============================================================================
/// Bluetooth Classic transport
/// ============================================================================

/// Immutable UI state of the Bluetooth transport (replaces BtController's
/// reactive fields).
class BtTransportState {
  const BtTransportState({
    this.isConnected = false,
    this.isServerModeActive = false,
    this.isScanning = false,
    this.scanResults = const [],
    this.pairedDevices = const [],
    this.connectedDevice,
    this.lastDisconnectReason,
    this.lastConnectError,
  });

  final bool isConnected;
  final bool isServerModeActive;
  final bool isScanning;
  final List<BtDeviceInfo> scanResults;
  final List<BtDeviceInfo> pairedDevices;
  final BtDeviceInfo? connectedDevice;
  final String? lastDisconnectReason;
  final String? lastConnectError;

  BtTransportState copyWith({
    bool? isConnected,
    bool? isServerModeActive,
    bool? isScanning,
    List<BtDeviceInfo>? scanResults,
    List<BtDeviceInfo>? pairedDevices,
    BtDeviceInfo? connectedDevice,
    bool clearConnectedDevice = false,
    String? lastDisconnectReason,
    bool clearLastDisconnectReason = false,
    String? lastConnectError,
    bool clearLastConnectError = false,
  }) {
    return BtTransportState(
      isConnected: isConnected ?? this.isConnected,
      isServerModeActive: isServerModeActive ?? this.isServerModeActive,
      isScanning: isScanning ?? this.isScanning,
      scanResults: scanResults ?? this.scanResults,
      pairedDevices: pairedDevices ?? this.pairedDevices,
      connectedDevice:
          clearConnectedDevice ? null : (connectedDevice ?? this.connectedDevice),
      lastDisconnectReason: clearLastDisconnectReason
          ? null
          : (lastDisconnectReason ?? this.lastDisconnectReason),
      lastConnectError:
          clearLastConnectError ? null : (lastConnectError ?? this.lastConnectError),
    );
  }
}

/// Orchestrates Bluetooth Classic operations through BtClassicService and
/// exposes reactive UI state (Riverpod port of BtController).
class BtTransportNotifier extends Notifier<BtTransportState> {
  /// Test hook: inject a fake service instead of the real platform-channel
  /// backed one. Null in production (the real service is created in build).
  BtTransportNotifier({BtClassicService? service}) : _serviceOverride = service;

  final BtClassicService? _serviceOverride;

  /// Translation hook — installed by the GetX adapter or a ported screen.
  TransportTranslator translate = _noopTranslate;

  late BtClassicService _service;
  bool _chatOpen = false;
  bool _outgoingConnect = false;
  Completer<bool>? _pendingConnectCompleter;
  Completer<void>? _dialSettle;
  DateTime? _connectInitiatedAt;
  BtDeviceInfo? _pendingRemote;
  bool _pendingAccept = false;
  Timer? _serverAutoStopTimer;
  void Function(Uint8List bytes, String text, {required String kind})?
      _chatDataCallback;

  static const String _connectReadyFrame = '@@CHATBLUE_CONNECT@@';

  @override
  BtTransportState build() {
    _service = _serviceOverride ?? BtClassicService();
    _wireCallbacks();
    unawaited(_init());
    ref.onDispose(() {
      _serverAutoStopTimer?.cancel();
      _service.stopServer();
      _service.stopScan();
      _service.dispose();
    });
    return const BtTransportState();
  }

  Future<void> _init() async {
    try {
      await _service.initialize(requestEnableIfDisabled: true);
      if (!ref.mounted) return;
      await refreshPairedDevices();
    } catch (e) {
      if (kDebugMode) debugPrint('Bt transport init failed: $e');
    }
  }

  void _wireCallbacks() {
    _service.onScanStarted = () {
      state = state.copyWith(isScanning: true, scanResults: const []);
    };

    _service.onDeviceFound = (d) {
      final results = [...state.scanResults];
      final idx = results.indexWhere((e) => e.address == d.address);
      if (idx == -1) {
        results.add(d);
      } else {
        results[idx] = d;
      }
      state = state.copyWith(scanResults: results);
    };

    _service.onScanFinished = () {
      state = state.copyWith(isScanning: false);
      if (kDebugMode) debugPrint('Scan finished');
    };

    _service.onScanError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Scan error: $message');
      }
      state = state.copyWith(isScanning: false);
      _showSnackbar('scanErrorTitle', message);
    };

    _service.onSocketConnected = (remote) {
      _pendingRemote = remote;
      refreshPairedDevices();
      if (kDebugMode) debugPrint('Socket connected to ${remote.address}');

      final bool withinInitiationWindow =
          _connectInitiatedAt != null &&
          DateTime.now().difference(_connectInitiatedAt!).inSeconds < 20;

      if (_outgoingConnect || _pendingAccept || withinInitiationWindow) {
        _startWaitingAcceptance();
      } else {
        _showIncomingRequest(remote.name ?? remote.address);
      }
    };

    _service.onSocketDisconnected = (reason) {
      _settleDial();
      final bool wasConnected = state.isConnected;
      state = state.copyWith(isConnected: false);
      ConnectionRequestBanner.dismiss();
      // Keep the initiation window while OUR dial is still in flight: a
      // disconnect event during the attempt (native cleanup of a previous
      // socket) must not let the real socket that lands moments later read
      // as an INCOMING request — the dialer would show its own banner.
      if (!_outgoingConnect) {
        _connectInitiatedAt = null;
      }
      if (_pendingAccept) {
        _pendingAccept = false;
        _pendingRemote = null;
        _showSnackbar('connectionDeclinedTitle', 'connectionDeclinedMessage');
      }
      if (kDebugMode) debugPrint('Socket disconnected: $reason');
      refreshPairedDevices();
      if (wasConnected) {
        state = state.copyWith(lastDisconnectReason: reason);
      }
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error: $message');
      }
      // Deliberately not surfaced as a snackbar/modal: transient link errors
      // during scanning are common and would spam the UI.
    };

    _service.onSocketData = _dispatchSocketData;
  }

  /// Snackbar with a translated message.
  void _showSnackbar(String titleKey, String messageKeyOrRaw) {
    final messenger = scaffoldMessengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${translate(titleKey)}: $messageKeyOrRaw',
        ),
      ),
    );
  }

  // --- ChatTransport surface (consumed by the GetX bridge + ported UI) ---

  bool get isConnected => state.isConnected;
  bool get isAwaitingAcceptance => _pendingAccept;
  String? get connectedDeviceKey => state.connectedDevice?.address;
  String? get connectedDeviceName => state.connectedDevice?.name;
  String get transportType => 'bt';

  Future<void> refreshPairedDevices() async {
    try {
      final list = await _service.getPairedDevices();
      state = state.copyWith(pairedDevices: list);
    } catch (e) {
      if (kDebugMode) debugPrint('Failed to load paired devices: $e');
    }
  }

  Future<void> startServer() async {
    final res = await _service.requestDiscoverable(seconds: 300);
    final bool allowed = (res['allowed'] as bool?) ?? false;
    if (allowed) {
      await _service.startServer(serviceName: 'ChatBlueSPP');
      state = state.copyWith(isServerModeActive: true);
      final int durationSec = (res['durationSec'] as int?) ?? 0;
      if (durationSec > 0) {
        _serverAutoStopTimer?.cancel();
        _serverAutoStopTimer = Timer(Duration(seconds: durationSec), () {
          stopServer();
        });
      }
    } else {
      if (kDebugMode) debugPrint('Discoverable request denied');
    }
  }

  Future<void> stopServer() async {
    await _service.stopServer();
    state = state.copyWith(isServerModeActive: false);
  }

  Future<void> startScan() async {
    state = state.copyWith(scanResults: const []);
    await _service.startScan(autoStopAfter: const Duration(seconds: 60));
  }

  Future<void> stopScan() async {
    await _service.stopScan();
    state = state.copyWith(isScanning: false);
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
        builder: (_) => const BChatScreen(),
        settings: const RouteSettings(name: 'BChatScreen'),
      ),
    );
  }

  void _showIncomingRequest(String deviceName) {
    ConnectionRequestBanner.show(
      deviceName: deviceName,
      isChatScreen: _chatOpen,
      onAccept: () {
        if (_chatOpen) return;
        state = state.copyWith(isConnected: true);
        state = state.copyWith(connectedDevice: _pendingRemote);
        _pendingRemote = null;
        _service.sendString(_connectReadyFrame);
        _openChat();
      },
      onDecline: () {
        if (!_pendingAccept) {
          state = state.copyWith(
            connectedDevice: null,
            isConnected: false,
            clearConnectedDevice: true,
          );
          _service.disconnect();
        }
      },
    );
  }

  void _startWaitingAcceptance() {
    _pendingAccept = true;
  }

  void _dispatchSocketData(
    Uint8List bytes,
    String text, {
    required String kind,
  }) {
    if (text == _connectReadyFrame) {
      _settleDial();
      _pendingAccept = false;
      _connectInitiatedAt = null;
      ConnectionRequestBanner.dismiss();
      state = state.copyWith(isConnected: true);
      state = state.copyWith(connectedDevice: state.connectedDevice ?? _pendingRemote);
      _pendingRemote = null;
      _openChat();
      return;
    }
    _chatDataCallback?.call(bytes, text, kind: kind);
  }

  /// Connect to a discovered or paired device and await the connection result.
  Future<bool> connectToDevice(BtDeviceInfo device) =>
      connectToPeer(device.address);

  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();
    _pendingConnectCompleter = completer;
    _dialSettle = Completer<void>();
    _outgoingConnect = true;
    _connectInitiatedAt = DateTime.now();

    if (state.isScanning) {
      await stopScan();
    }
    if (state.isServerModeActive) {
      await stopServer();
    }

    final prevConnected = _service.onSocketConnected;
    final prevDisconnected = _service.onSocketDisconnected;
    final prevError = _service.onSocketError;

    void restore() {
      _service.onSocketConnected = prevConnected;
      _service.onSocketDisconnected = prevDisconnected;
      _service.onSocketError = prevError;
      _outgoingConnect = false;
      _pendingConnectCompleter = null;
    }

    _service.onSocketConnected = (remote) {
      prevConnected?.call(remote);
      if (remote.address == address && !completer.isCompleted) {
        completer.complete(true);
      }
    };

    _service.onSocketDisconnected = (reason) {
      _settleDial();
      prevDisconnected?.call(reason);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error during connect: $message');
      }
      if (!completer.isCompleted) {
        ConnectionRequestBanner.dismiss();
        _pendingAccept = false;
        completer.complete(false);
      }
    };

    try {
      await _service.connect(address);
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Error initiating connection: $e');
      }
      restore();
      return false;
    }

    try {
      final bool result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () async => await _service.isConnected(),
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

  Future<bool> connectToSessionPeer({required String? address, String? name}) {
    if (address == null || address.isEmpty) {
      state = state.copyWith(
        lastConnectError: translate('noDeviceAddressMessage'),
        clearLastConnectError: false,
      );
      return Future<bool>.value(false);
    }
    return connectToPeer(address);
  }

  Future<void> disconnectFromDevice() async {
    if (state.isConnected) {
      await _service.disconnect();
      state = state.copyWith(isConnected: false);
    }
  }

  /// Completes when the current dial reaches a terminal state (accepted
  /// link, peer rejection, drop or cancel) — the connecting panel stays up
  /// until then; the cap prevents a stuck panel if no event arrives.
  Future<void> get dialSettled async {
    final s = _dialSettle;
    if (s == null) return;
    await s.future.timeout(const Duration(seconds: 30), onTimeout: () {});
  }

  void _settleDial() {
    final s = _dialSettle;
    if (s != null && !s.isCompleted) s.complete();
  }

  /// UI "İptal" on the connecting panel: abandons the pending dial (its
  /// wait resolves as a cancellation — screens skip the failure snackbar)
  /// and closes the attempt so a late accept cannot land a link.
  Future<void> cancelPendingConnect() async {
    _settleDial();
    final c = _pendingConnectCompleter;
    _pendingConnectCompleter = null;
    await _service.disconnect();
    if (c != null && !c.isCompleted) c.complete(false);
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
}

/// ============================================================================
/// Wi‑Fi Direct transport
/// ============================================================================

/// Immutable UI state of the Wi‑Fi Direct transport (replaces
/// WifiController's reactive fields).
class WdTransportState {
  const WdTransportState({
    this.isConnected = false,
    this.isServerModeActive = false,
    this.isScanning = false,
    this.isWifiOn = true,
    this.isWifiEnableInFlight = false,
    this.peers = const [],
    this.connectedDevice,
    this.lastDisconnectReason,
    this.lastConnectError,
    this.pendingRequestName,
  });

  final bool isConnected;
  final bool isServerModeActive;
  final bool isScanning;
  final bool isWifiOn;
  final bool isWifiEnableInFlight;
  final List<WdPeerInfo> peers;
  final WdPeerInfo? connectedDevice;
  final String? lastDisconnectReason;
  final String? lastConnectError;
  final String? pendingRequestName;

  WdTransportState copyWith({
    bool? isConnected,
    bool? isServerModeActive,
    bool? isScanning,
    bool? isWifiOn,
    bool? isWifiEnableInFlight,
    List<WdPeerInfo>? peers,
    WdPeerInfo? connectedDevice,
    bool clearConnectedDevice = false,
    String? lastDisconnectReason,
    bool clearLastDisconnectReason = false,
    String? lastConnectError,
    bool clearLastConnectError = false,
    String? pendingRequestName,
    bool clearPendingRequestName = false,
  }) {
    return WdTransportState(
      isConnected: isConnected ?? this.isConnected,
      isServerModeActive: isServerModeActive ?? this.isServerModeActive,
      isScanning: isScanning ?? this.isScanning,
      isWifiOn: isWifiOn ?? this.isWifiOn,
      isWifiEnableInFlight: isWifiEnableInFlight ?? this.isWifiEnableInFlight,
      peers: peers ?? this.peers,
      connectedDevice: clearConnectedDevice
          ? null
          : (connectedDevice ?? this.connectedDevice),
      lastDisconnectReason: clearLastDisconnectReason
          ? null
          : (lastDisconnectReason ?? this.lastDisconnectReason),
      lastConnectError: clearLastConnectError
          ? null
          : (lastConnectError ?? this.lastConnectError),
      pendingRequestName: clearPendingRequestName
          ? null
          : (pendingRequestName ?? this.pendingRequestName),
    );
  }
}

/// Orchestrates Wi‑Fi Direct operations through WifiDirectService and
/// exposes reactive UI state (Riverpod port of WifiController).
class WdTransportNotifier extends Notifier<WdTransportState> {
  /// Test hook: inject a fake service instead of the real platform-channel
  /// backed one. Null in production (the real service is created in build).
  WdTransportNotifier({WifiDirectService? service}) : _serviceOverride = service;

  final WifiDirectService? _serviceOverride;

  /// Translation hook — installed by the GetX adapter or a ported screen.
  TransportTranslator translate = _noopTranslate;

  /// Live name of the pending incoming request; drives the request banner
  /// title in place (peer name frame can arrive while the banner is up).
  final ValueNotifier<String> pendingRequestName = ValueNotifier<String>('');

  /// Called with the peer's self-reported name when a chat screen is open —
  /// the GetX bridge routes it to WChatScreenController.updateSessionName.
  void Function(String name)? onPeerNameForChat;

  late WifiDirectService _service;
  bool _chatOpen = false;
  bool _outgoingConnect = false;
  Completer<bool>? _pendingConnectCompleter;
  Completer<void>? _dialSettle;
  DateTime? _connectInitiatedAt;
  WdPeerInfo? _pendingRemote;
  String? _pendingPeerName;
  String? _lastConnectAddress;
  String? _ownDeviceName;
  String? _ownP2pMac;
  bool _pendingAccept = false;
  bool _wifiEnableInFlight = false;
  bool _suppressScanErrors = false;
  void Function(Uint8List bytes, String text, {required String kind})?
      _chatDataCallback;

  static const String _connectReadyFrame = '@@CHATBLUE_CONNECT@@';
  static const String _connectNameFrame = '@@CHATBLUE_NAME@@';
  static const String _connectIdFrame = '@@CHATBLUE_ID@@';

  @override
  WdTransportState build() {
    _service = _serviceOverride ?? WifiDirectService();
    _wireCallbacks();
    unawaited(_init());
    ref.onDispose(() {
      _service.dispose();
      pendingRequestName.dispose();
    });
    return const WdTransportState();
  }

  Future<void> _init() async {
    try {
      await _service.initialize();
      if (!ref.mounted) return;
      await _refreshWifiState();
    } catch (e) {
      if (kDebugMode) debugPrint('WD transport init failed: $e');
    }
  }

  // --- ChatTransport surface (consumed by the GetX bridge + ported UI) ---

  bool get isConnected => state.isConnected;
  bool get isAwaitingAcceptance => _pendingAccept;
  String? get connectedDeviceKey => state.connectedDevice?.deviceAddress;
  String? get connectedDeviceId => state.connectedDevice?.peerId;
  String? get connectedDeviceName => state.connectedDevice?.deviceName;
  String get transportType => 'wfd';

  Future<void> startServer() async {
    await _service.startServer();
    state = state.copyWith(isServerModeActive: true);
  }

  Future<void> stopServer() async {
    await _service.stopServer();
    state = state.copyWith(isServerModeActive: false);
  }

  Future<void> startDiscovery() async {
    await _refreshWifiState();
    if (!state.isWifiOn) return; // screen shows the "turn on Wi‑Fi" state
    state = state.copyWith(peers: const []);
    await _service.startDiscovery();
    state = state.copyWith(isScanning: true);
  }

  Future<void> stopDiscovery() async {
    await _service.stopDiscovery();
    state = state.copyWith(isScanning: false);
  }

  Future<void> _refreshWifiState() async {
    try {
      // NOTE: fetch the value FIRST, then derive from the CURRENT state —
      // `state = state.copyWith(x: await f())` evaluates the `state` getter
      // BEFORE the await and would overwrite newer states (lost update).
      final wifiOn = await _service.isWifiEnabled();
      state = state.copyWith(isWifiOn: wifiOn);
    } catch (_) {
      // fail-open: keep the last known state
    }
  }

  Future<void> enableWifi() async {
    if (_wifiEnableInFlight) return;
    _wifiEnableInFlight = true;
    state = state.copyWith(isWifiEnableInFlight: true);
    try {
      final opened = await _service.requestEnableWifi();
      if (!opened) return;
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _refreshWifiState();
        if (state.isWifiOn) return;
      }
    } finally {
      _wifiEnableInFlight = false;
      state = state.copyWith(isWifiEnableInFlight: false);
    }
  }

  Future<bool> connectToDevice(WdPeerInfo device) {
    _pendingPeerName = device.deviceName;
    return connectToPeer(device.deviceAddress);
  }

  Future<bool> connectToSessionPeer({
    required String? address,
    String? name,
  }) async {
    state = state.copyWith(lastConnectError: null);
    await _refreshWifiState();
    if (!state.isWifiOn) {
      await enableWifi();
      if (!state.isWifiOn) {
        state = state.copyWith(lastConnectError: translate('wifiOffTitle'));
        return false;
      }
    }

    final search = await _discoverSessionPeer(address: address, name: name);
    if (state.isConnected) return true;
    final match = search.match;
    if (match != null) {
      return connectToPeer(match.deviceAddress);
    }
    if (search.candidates.isNotEmpty) {
      final picked = await _promptPeerSelection(search.candidates);
      if (picked == null) {
        state = state.copyWith(
          lastConnectError:
              state.lastConnectError ??
              translate('wfdTargetNotFound', params: {'count': '${search.candidates.length}'}),
        );
        return false;
      }
      return connectToPeer(picked.deviceAddress);
    }
    return false;
  }

  Future<({WdPeerInfo? match, List<WdPeerInfo> candidates})>
      _discoverSessionPeer({
    required String? address,
    String? name,
  }) async {
    const Duration timeout = Duration(seconds: 20);
    const Duration pollInterval = Duration(milliseconds: 900);
    const Duration rearmInterval = Duration(seconds: 7);
    const Duration matchGrace = Duration(seconds: 5);

    state = state.copyWith(peers: const []);
    _suppressScanErrors = true;
    final flowStart = DateTime.now();
    DateTime? firstPeerAt;
    ({WdPeerInfo? match, List<WdPeerInfo> candidates}) settle() =>
        (match: null, candidates: state.peers.toList());
    try {
      await _service.startDiscovery();
      state = state.copyWith(isScanning: true);

      final deadline = flowStart.add(timeout);
      var nextRearm = flowStart.add(rearmInterval);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);

        if (state.isConnected) return settle();

        var match = _matchSessionPeer(state.peers, address: address, name: name);
        if (match != null) return (match: match, candidates: state.peers.toList());

        await _service.requestPeers();
        for (final peer in await _service.getDiscoveredPeers()) {
          if (!state.peers.any((p) => p.deviceAddress == peer.deviceAddress)) {
            state = state.copyWith(peers: [...state.peers, peer]);
          }
        }
        if (state.peers.isNotEmpty) {
          firstPeerAt ??= DateTime.now();
        }
        match = _matchSessionPeer(state.peers, address: address, name: name);
        if (match != null) return (match: match, candidates: state.peers.toList());

        if (firstPeerAt != null &&
            DateTime.now().difference(firstPeerAt) >= matchGrace) {
          return settle();
        }

        if (state.peers.isEmpty &&
            state.lastConnectError != null &&
            DateTime.now().difference(flowStart).inMilliseconds > 10000) {
          return settle();
        }

        if (DateTime.now().isAfter(nextRearm)) {
          nextRearm = DateTime.now().add(rearmInterval);
          await _service.startDiscovery();
        }
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint(
          'WFD session search: no target among '
          '${state.peers.map((p) => p.deviceName ?? p.deviceAddress).toList()}',
        );
      }
      if (state.peers.isEmpty) {
        state = state.copyWith(
          lastConnectError: state.lastConnectError ?? translate('wfdNoDevicesFound'),
        );
      }
      return settle();
    } catch (e) {
      state = state.copyWith(lastConnectError: e.toString());
      return settle();
    } finally {
      _suppressScanErrors = false;
      if (state.isScanning) {
        state = state.copyWith(isScanning: false);
        unawaited(_service.stopDiscovery());
      }
    }
  }

  WdPeerInfo? _matchSessionPeer(
    List<WdPeerInfo> candidates, {
    required String? address,
    String? name,
  }) {
    final String targetName = _normalizeDeviceName(name);
    WdPeerInfo? byName;
    for (final peer in candidates) {
      if (address != null &&
          address.isNotEmpty &&
          peer.deviceAddress == address) {
        return peer;
      }
      if (byName == null &&
          targetName.isNotEmpty &&
          _normalizeDeviceName(peer.deviceName) == targetName) {
        byName = peer;
      }
    }
    return byName;
  }

  String _normalizeDeviceName(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  Future<WdPeerInfo?> _promptPeerSelection(List<WdPeerInfo> candidates) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return Future<WdPeerInfo?>.value();
    return showModalBottomSheet<WdPeerInfo>(
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
                    final name = (peer.deviceName ?? '').trim();
                    return ListTile(
                      leading: const Icon(Icons.wifi_tethering),
                      title: Text(name.isEmpty ? translate('unknownDevice') : name),
                      subtitle: Text(peer.deviceAddress),
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

  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();
    _pendingConnectCompleter = completer;
    _dialSettle = Completer<void>();
    _outgoingConnect = true;
    _connectInitiatedAt = DateTime.now();
    _lastConnectAddress = address;
    state = state.copyWith(lastConnectError: null);
    if (kDebugMode) {
      debugPrint('connecting to device: $address');
    }

    if (state.isScanning) {
      await stopDiscovery();
    }
    if (state.isServerModeActive) {
      await stopServer();
    }

    final prevConnected = _service.onSocketConnected;
    final prevDisconnected = _service.onSocketDisconnected;
    final prevError = _service.onSocketError;

    void restore() {
      _service.onSocketConnected = prevConnected;
      _service.onSocketDisconnected = prevDisconnected;
      _service.onSocketError = prevError;
      _outgoingConnect = false;
      _pendingConnectCompleter = null;
    }

    _service.onSocketConnected = (remote) {
      prevConnected?.call(remote);
      if (remote.deviceAddress == address && !completer.isCompleted) {
        completer.complete(true);
      }
    };

    _service.onSocketDisconnected = (reason) {
      _settleDial();
      prevDisconnected?.call(reason);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    };

    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error during connect: $message');
      }
      state = state.copyWith(lastConnectError: message);
      if (!completer.isCompleted) {
        ConnectionRequestBanner.dismiss();
        _pendingAccept = false;
        completer.complete(false);
      }
    };

    try {
      await _service.connect(address);
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Error initiating connection: $e');
      }
      restore();
      return false;
    }

    try {
      final bool result = await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () async {
          final bool socketUp = await _service.isConnected();
          if (socketUp) return true;
          _pendingAccept = true;
          return completer.future.timeout(
            const Duration(seconds: 10),
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
        builder: (_) => const WChatScreen(),
        settings: const RouteSettings(name: 'WChatScreen'),
      ),
    );
  }

  void _showIncomingRequest(String deviceName) {
    final initialName =
        (deviceName.trim().isEmpty || deviceName.trim() == 'unknown')
            ? null
            : deviceName.trim();
    pendingRequestName.value = initialName ?? '';
    ConnectionRequestBanner.show(
      deviceName: initialName ?? '',
      isChatScreen: _chatOpen,
      liveName: pendingRequestName,
      onAccept: () {
        if (_chatOpen) return;
        state = state.copyWith(isConnected: true);
        state = state.copyWith(peers: const []);
        final pending = _pendingRemote;
        if (pending != null) {
          final current = state.connectedDevice;
          state = state.copyWith(
            connectedDevice: WdPeerInfo(
              deviceAddress: _isUsableMac(current?.deviceAddress)
                  ? current!.deviceAddress
                  : pending.deviceAddress,
              deviceName: current?.deviceName ?? pending.deviceName,
              ip: pending.ip,
              port: pending.port,
              isGroupOwner: pending.isGroupOwner,
              peerId: current?.peerId ?? pending.peerId,
            ),
          );
        }
        _pendingRemote = null;
        _service.sendString(_connectReadyFrame);
        unawaited(_sendOwnName());
        _openChat();
      },
      onDecline: () {
        if (!_pendingAccept) {
          state = state.copyWith(
            connectedDevice: null,
            isConnected: false,
            clearConnectedDevice: true,
          );
          _service.disconnect();
        }
      },
    );
  }

  void _startWaitingAcceptance() {
    _pendingAccept = true;
  }

  void _dispatchSocketData(
    Uint8List bytes,
    String text, {
    required String kind,
  }) {
    if (text == _connectReadyFrame) {
      _settleDial();
      _pendingAccept = false;
      _connectInitiatedAt = null;
      ConnectionRequestBanner.dismiss();
      state = state.copyWith(isConnected: true);
      state = state.copyWith(peers: const []);
      state = state.copyWith(
        connectedDevice: state.connectedDevice ?? _pendingRemote,
      );
      if (state.connectedDevice != null) {
        final current = state.connectedDevice!;
        state = state.copyWith(
          connectedDevice: WdPeerInfo(
            deviceAddress: _lastConnectAddress ?? current.deviceAddress,
            deviceName: current.deviceName ?? _pendingPeerName,
            ip: current.ip,
            port: current.port,
            isGroupOwner: current.isGroupOwner,
            peerId: current.peerId,
          ),
        );
      }
      _pendingRemote = null;
      _openChat();
      unawaited(_sendOwnName());
      return;
    }
    if (text.startsWith(_connectIdFrame)) {
      final body = text.substring(_connectIdFrame.length).trim();
      final parts = body.split('|');
      final String? uid = parts.isNotEmpty ? parts[0].trim() : null;
      final String? mac = parts.length > 1 ? parts[1].trim() : null;
      final String name =
          parts.length > 2 ? parts.sublist(2).join('|').trim() : '';
      _applyPeerIdentity(uid, mac, name);
      return;
    }
    if (text.startsWith(_connectNameFrame)) {
      _applyPeerName(text.substring(_connectNameFrame.length).trim());
      return;
    }
    _chatDataCallback?.call(bytes, text, kind: kind);
  }

  void _applyPeerName(String name) {
    if (name.isEmpty) return;
    pendingRequestName.value = name;
    final current = state.connectedDevice;
    state = state.copyWith(
      connectedDevice: WdPeerInfo(
        deviceAddress: current?.deviceAddress ?? _lastConnectAddress ?? 'unknown',
        deviceName: name,
        ip: current?.ip,
        port: current?.port,
        isGroupOwner: current?.isGroupOwner,
        peerId: current?.peerId,
      ),
    );
    onPeerNameForChat?.call(name);
  }

  bool _isUsableMac(String? mac) =>
      mac != null && mac.isNotEmpty && mac != 'unknown' && mac != '02:00:00:00:00:00';

  void _applyPeerIdentity(String? uid, String? mac, String name) {
    final hasUid = uid != null && uid.isNotEmpty && uid != 'unknown' && uid != '02:00:00:00:00:00';
    final hasMac = _isUsableMac(mac);
    if (name.isNotEmpty) {
      pendingRequestName.value = name;
    }
    if (hasUid || hasMac || name.isNotEmpty) {
      final current = state.connectedDevice;
      state = state.copyWith(
        connectedDevice: WdPeerInfo(
          deviceAddress: hasMac
              ? mac!
              : (current?.deviceAddress ?? _lastConnectAddress ?? 'unknown'),
          deviceName: name.isNotEmpty ? name : current?.deviceName,
          ip: current?.ip,
          port: current?.port,
          isGroupOwner: current?.isGroupOwner,
          peerId: hasUid ? uid : current?.peerId,
        ),
      );
    }
    if (name.isNotEmpty) {
      onPeerNameForChat?.call(name);
    }
  }

  Future<void> _sendOwnName() async {
    try {
      final name = _ownDeviceName ??=
          (await DeviceInfoPlugin().androidInfo).model.trim();
      if (name.isEmpty) return;
      final uid = await DeviceIdService.get();
      if (uid.isEmpty) return;
      _ownP2pMac ??= await _service.getThisDeviceAddress();
      final mac = _isUsableMac(_ownP2pMac) ? _ownP2pMac! : '';
      await _service.sendString('$_connectIdFrame$uid|$mac|$name');
    } catch (e) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Send own device name failed: $e');
      }
    }
  }

  void _wireCallbacks() {
    _service.onPeerFound = (peer) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Peer found: ${peer.deviceName} (${peer.deviceAddress})');
      }
      if (!state.peers.any((p) => p.deviceAddress == peer.deviceAddress)) {
        state = state.copyWith(peers: [...state.peers, peer]);
      }
    };
    _service.onScanError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Scan error: $message');
      }
      state = state.copyWith(isScanning: false);
      state = state.copyWith(lastConnectError: message);
      if (_suppressScanErrors) return;
      final messenger = scaffoldMessengerKey.currentState;
      messenger?.showSnackBar(
        SnackBar(
          content: Text('${translate('scanErrorTitle')}: $message'),
        ),
      );
    };
    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error: $message');
      }
    };
    _service.onSocketData = _dispatchSocketData;
    _service.onSocketConnected = (remote) {
      _pendingRemote = remote;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket connected: ${remote.deviceAddress}');
      }
      final bool withinInitiationWindow =
          _connectInitiatedAt != null &&
          DateTime.now().difference(_connectInitiatedAt!).inSeconds < 20;

      if (_outgoingConnect || _pendingAccept || withinInitiationWindow) {
        _startWaitingAcceptance();
      } else {
        if (state.isScanning) {
          state = state.copyWith(isScanning: false);
          unawaited(_service.stopDiscovery());
        }
        _showIncomingRequest(remote.deviceName ?? remote.deviceAddress);
      }
      unawaited(_sendOwnName());
    };
    _service.onSocketDisconnected = (reason) {
      _settleDial();
      final bool wasConnected = state.isConnected;
      state = state.copyWith(isConnected: false);
      ConnectionRequestBanner.dismiss();
      // Same window rule as the BT transport: don't wipe the initiation
      // window while our dial is in flight (a mid-attempt disconnect must
      // not make our own late socket read as an incoming request).
      if (!_outgoingConnect) {
        _connectInitiatedAt = null;
      }
      if (_pendingAccept) {
        _pendingAccept = false;
        _pendingRemote = null;
        final messenger = scaffoldMessengerKey.currentState;
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              '${translate('connectionDeclinedTitle')}: '
              '${translate('connectionDeclinedMessage')}',
            ),
          ),
        );
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket disconnected: $reason');
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

  /// Completes when the current dial reaches a terminal state (accepted
  /// link, peer rejection, drop or cancel) — the connecting panel stays up
  /// until then; the cap prevents a stuck panel if no event arrives.
  Future<void> get dialSettled async {
    final s = _dialSettle;
    if (s == null) return;
    await s.future.timeout(const Duration(seconds: 30), onTimeout: () {});
  }

  void _settleDial() {
    final s = _dialSettle;
    if (s != null && !s.isCompleted) s.complete();
  }

  /// UI "İptal" on the connecting panel: abandons the pending dial (its
  /// wait resolves as a cancellation — screens skip the failure snackbar)
  /// and closes the attempt so a late accept cannot land a link.
  Future<void> cancelPendingConnect() async {
    _settleDial();
    final c = _pendingConnectCompleter;
    _pendingConnectCompleter = null;
    await _service.disconnect();
    if (c != null && !c.isCompleted) c.complete(false);
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
}

/// ============================================================================
/// Providers
/// ============================================================================

/// Global Bluetooth transport (app-wide singleton; service lifetime).
final btTransportProvider =
    NotifierProvider<BtTransportNotifier, BtTransportState>(
  BtTransportNotifier.new,
);

/// Global Wi‑Fi Direct transport (app-wide singleton; service lifetime).
final wdTransportProvider =
    NotifierProvider<WdTransportNotifier, WdTransportState>(
  WdTransportNotifier.new,
);