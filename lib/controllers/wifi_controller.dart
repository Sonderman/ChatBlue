import 'dart:async';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/device_id_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/screens/chat_ui/connection_request.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:chatblue/screens/w_chatscreen/w_chatscreen_controller.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WifiController extends GetxController implements ChatTransport {
  final RxList<WdPeerInfo> peers = <WdPeerInfo>[].obs;
  final RxBool isServerModeActive = false.obs;
  final RxBool isScanning = false.obs;

  /// Whether the device's Wi‑Fi radio is on; the scan screen shows a
  /// "turn on Wi‑Fi" panel button while off (no silent-enable is possible
  /// on Android 10+).
  final RxBool isWifiOn = true.obs;

  /// True while the enable-Wi‑Fi flow (panel launch + polling) is in flight.
  final RxBool isWifiEnableInFlight = false.obs;
  bool _wifiEnableInFlight = false;
  @override
  final RxBool isConnected = false.obs;
  WdPeerInfo? connectedDevice;
  late WifiDirectService _service;
  bool _chatOpen = false;
  @override
  final Rxn<String> lastDisconnectReason = Rxn<String>();

  /// Detailed native error of the most recent failed connect attempt
  /// (e.g. "Wi‑Fi Direct is disabled", "connect failed: BUSY (2)") — the
  /// generic "Could not connect!" snackbar alone hides the actual reason.
  final Rxn<String> lastConnectError = Rxn<String>();
  @override
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  @override
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();

  /// True while this device is the one initiating a connection (no incoming
  /// request banner is shown for self-initiated connects).
  bool _outgoingConnect = false;

  /// When the last `connectToPeer` was started. Incoming socket events
  /// within a short window after an initiation are treated as part of that
  /// initiation (e.g. the peer connecting back simultaneously), so a
  /// "Connection request" card can never appear for a link we started.
  DateTime? _connectInitiatedAt;

  /// Frame the ACCEPTING side sends once the user approved the connection;
  /// the initiating side opens its chat only upon receiving it.
  static const String _connectReadyFrame = '@@CHATBLUE_CONNECT@@';

  /// Device-name frame (`@@CHATBLUE_NAME@@<name>`): both sides send their
  /// own model name once connected, because the WFD socket carries no peer
  /// name — without this every chat app bar would show a MAC/UUID fallback.
  static const String _connectNameFrame = '@@CHATBLUE_NAME@@';

  /// Identity frame (`@@CHATBLUE_ID@@<mac>|<name>`): like the name frame,
  /// but also carries the sender's P2P MAC — the receiver keys its chat
  /// session on it (the socket map has neither name nor address).
  static const String _connectIdFrame = '@@CHATBLUE_ID@@';

  /// Peer of the pending (not yet accepted) connection attempt.
  WdPeerInfo? _pendingRemote;

  /// Name of the peer entry the user tapped in the scan list; patched into
  /// the connection identity because the native WFD socket map carries
  /// neither a name nor a device address.
  String? _pendingPeerName;

  /// Address of the last `connectToPeer` attempt (same rationale: the
  /// socket-connected remote map has no device address).
  String? _lastConnectAddress;

  /// Cached own model name (sent to the peer as the display name).
  String? _ownDeviceName;

  /// Cached own P2P MAC (from the native this-device broadcast); rides in
  /// the identity frame so the peer can key its chat session.
  String? _ownP2pMac;

  /// Live name of the pending incoming request; updates the request banner
  /// title in place when the peer's @@CHATBLUE_NAME@@ frame arrives before
  /// the user accepts (WFD sockets carry no peer name pre-accept).
  final Rxn<String> pendingRequestName = Rxn<String>();

  /// True while THIS device is waiting for the peer's acceptance (initiator
  /// side) — the link exists but is not yet "connected".
  bool _pendingAccept = false;

  /// Data consumer registered by the chat screen; the controller owns the
  /// service's onSocketData slot and delegates through [_dispatchSocketData].
  void Function(Uint8List bytes, String text, {required String kind})?
      _chatDataCallback;

  @override
  String? get connectedDeviceKey => connectedDevice?.deviceAddress;

  /// The peer's stable per-install id (identity frame) — the chat session
  /// is keyed on this, NOT on the rotating P2P MAC.
  @override
  String? get connectedDeviceId => connectedDevice?.peerId;

  @override
  String? get connectedDeviceName => connectedDevice?.deviceName;

  @override
  bool get isAwaitingAcceptance => _pendingAccept;

  @override
  void onInit() async {
    //await WifiDirectPlugin.initialize();
    _service = WifiDirectService();
    await _service.initialize();
    setupListeners();
    await _refreshWifiState();
    super.onInit();
  }

  @override
  void onClose() {
    _service.dispose();
    super.onClose();
  }

  Future<void> startServer() async {
    await _service.startServer();
    isServerModeActive.value = true;
  }

  Future<void> stopServer() async {
    await _service.stopServer();
    isServerModeActive.value = false;
  }

  Future<void> startDiscovery() async {
    await _refreshWifiState();
    if (!isWifiOn.value) return; // screen shows the "turn on Wi‑Fi" state
    peers.clear();
    await _service.startDiscovery();
    isScanning.value = true;
  }

  Future<void> stopDiscovery() async {
    await _service.stopDiscovery();
    isScanning.value = false;
  }

  Future<void> _refreshWifiState() async {
    try {
      isWifiOn.value = await _service.isWifiEnabled();
    } catch (_) {
      // fail-open: keep the last known state
    }
  }

  /// Opens the system Wi‑Fi panel and waits (polling) until the radio is on
  /// or a ~15 s window passes; the scan screen flips back to the normal
  /// controls automatically once Wi‑Fi is enabled.
  Future<void> enableWifi() async {
    if (_wifiEnableInFlight) return;
    _wifiEnableInFlight = true;
    isWifiEnableInFlight.value = true;
    try {
      final opened = await _service.requestEnableWifi();
      if (!opened) return;
      for (var i = 0; i < 30; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _refreshWifiState();
        if (isWifiOn.value) return;
      }
    } finally {
      _wifiEnableInFlight = false;
      isWifiEnableInFlight.value = false;
    }
  }

  /// Connect to a discovered peer and await connection result.
  Future<bool> connectToDevice(WdPeerInfo device) {
    _pendingPeerName = device.deviceName;
    return connectToPeer(device.deviceAddress);
  }

  /// Connect to a peer by address and await the connection result.
  @override
  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();
    _outgoingConnect = true;
    _connectInitiatedAt = DateTime.now();
    _lastConnectAddress = address;
    lastConnectError.value = null;
    if (kDebugMode) {
      debugPrint('connecting to device: $address');
    }

    // Stop scanning if still running to avoid connection interference
    if (isScanning.value) {
      await stopDiscovery();
    }
    if (isServerModeActive.value) {
      await stopServer();
    }

    // Temporarily extend callbacks to resolve this connect attempt
    final prevConnected = _service.onSocketConnected;
    final prevDisconnected = _service.onSocketDisconnected;
    final prevError = _service.onSocketError;

    void restore() {
      _service.onSocketConnected = prevConnected;
      _service.onSocketDisconnected = prevDisconnected;
      _service.onSocketError = prevError;
      _outgoingConnect = false;
    }

    _service.onSocketConnected = (remote) {
      // Keep original behavior
      prevConnected?.call(remote);
      if (remote.deviceAddress == address && !completer.isCompleted) {
        completer.complete(true);
      }
    };

    _service.onSocketDisconnected = (reason) {
      prevDisconnected?.call(reason);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    };

    // If any socket error occurs during the connection attempt,
    // immediately fail this attempt without waiting.
    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error during connect: $message');
      }
      // Keep the DETAILED reason: the scan screen shows it instead of the
      // generic "Could not connect!" so a preflight failure ("Wi‑Fi Direct
      // is disabled", "Location is turned off") or a negotiation error
      // (BUSY/ERROR) is visible. Not forwarded to prevError — the
      // connecting screen shows its own result message, and forwarding
      // would queue a snackbar behind the loading dialog.
      lastConnectError.value = message;
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
        // Negotiation can exceed 10 s (the native retry after a P2P service
        // restart waits ~5 s before its second attempt). A timeout with NO
        // negative signal is NOT a failure — see onTimeout.
        const Duration(seconds: 10),
        onTimeout: () async {
          final bool socketUp = await _service.isConnected();
          if (socketUp) return true;
          // No socket error and no disconnect yet: the link may still be
          // forming (slow OEM negotiation, native retry pending). Holding
          // the attempt in awaiting-acceptance instead of hard-failing
          // prevents the misleading "Could not connect!" popup that
          // appeared while the peer's request card was still up — the
          // pending socket/error/disconnect signals get a second window,
          // and the READY frame still opens the chat afterwards.
          _pendingAccept = true;
          return completer.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () => _service.isConnected(),
          );
        },
      );
      restore();
      if (!result) {
        // Deliberately NOT clearing _pendingAccept here: the socket may
        // still be alive (the peer's accept can arrive late). The flag
        // stays set until the READY frame is received or the socket
        // disconnects, so a late event can never surface a
        // "Connection request" card for a link we initiated ourselves.
        ConnectionRequestBanner.dismiss();
      }
      return result;
    } catch (_) {
      restore();
      return false;
    }
  }

  /// Opens the chat screen for the current connection (guarding against
  /// double navigation, and dismissing any loading dialog on top first).
  void _openChat() {
    if (_chatOpen) return;
    _chatOpen = true;
    // The scan screen's loading dialog may still be on top: dismiss it
    // BEFORE pushing the chat screen, so no later pop (which removes the
    // top route) can ever close the chat screen by mistake.
    if (Get.isDialogOpen == true) {
      Navigator.of(Get.overlayContext!, rootNavigator: true).pop();
    }
    Get.to(() => const WChatScreen());
  }

  /// Shows the incoming connection request banner; Accept marks the link as
  /// connected, notifies the initiator with the READY frame and opens the
  /// chat; Decline (or timeout) tears the socket down.
  void _showIncomingRequest(String deviceName) {
    // The socket map carries no name pre-accept ('unknown' placeholder);
    // the live source gets the real name when the peer's name frame lands
    // while the banner is up.
    final initialName =
        (deviceName.trim().isEmpty || deviceName.trim() == 'unknown')
            ? null
            : deviceName.trim();
    pendingRequestName.value = initialName;
    ConnectionRequestBanner.show(
      deviceName: initialName ?? '',
      liveName: pendingRequestName,
      onAccept: () {
        if (_chatOpen) return;
        isConnected.value = true;
        // The scan list is stale once a session begins: clear it so the
        // Wi‑Fi screen starts fresh after the chat closes.
        peers.clear();
        final pending = _pendingRemote;
        if (pending != null) {
          // MERGE, don't replace: the peer's identity frame may already
          // have set the uid/name on connectedDevice — the socket map
          // (pending) carries none of those and replacing would wipe the
          // session key.
          connectedDevice = WdPeerInfo(
            deviceAddress: _isUsableMac(connectedDevice?.deviceAddress)
                ? connectedDevice!.deviceAddress
                : pending.deviceAddress,
            deviceName: connectedDevice?.deviceName ?? pending.deviceName,
            ip: pending.ip,
            port: pending.port,
            isGroupOwner: pending.isGroupOwner,
            peerId: connectedDevice?.peerId ?? pending.peerId,
          );
        }
        _pendingRemote = null;
        _service.sendString(_connectReadyFrame);
        // Tell the initiator our device name (the socket carries none).
        unawaited(_sendOwnName());
        _openChat();
      },
      onDecline: () {
        if (!_pendingAccept) {
          // Request side: full teardown.
          connectedDevice = null;
          isConnected.value = false;
          _service.disconnect();
        }
      },
    );
  }

  /// Marks the initiating side as awaiting acceptance. No banner is shown:
  /// the user already knows they asked to connect; the peer's decision
  /// surfaces through isConnected or the declined snackbar on disconnect.
  void _startWaitingAcceptance() {
    _pendingAccept = true;
  }

  /// Intercepts the READY handshake frame, then delegates everything else to
  /// the chat screen's consumer.
  ///
  /// The frame is matched unconditionally (not only while [_pendingAccept]):
  /// if the initiator's connect attempt timed out while the peer was still
  /// deciding, the READY frame may arrive after [_pendingAccept] was reset —
  /// it must still bind the connection and never leak into the chat as a
  /// user-visible message.
  void _dispatchSocketData(
    Uint8List bytes,
    String text, {
    required String kind,
  }) {
    if (text == _connectReadyFrame) {
      _pendingAccept = false;
      _connectInitiatedAt = null;
      ConnectionRequestBanner.dismiss();
      isConnected.value = true;
      // The scan list is stale once a session begins: clear it so the
      // Wi‑Fi screen starts fresh after the chat closes.
      peers.clear();
      connectedDevice ??= _pendingRemote;
      // The native socket-connected map carries neither name nor device
      // address — patch them from the scan entry we tapped, so the chat
      // session (and its app bar) carry the real peer identity. The peer's
      // full name still arrives later via the @@CHATBLUE_NAME@@ frame.
      if (connectedDevice != null) {
        final current = connectedDevice!;
        connectedDevice = WdPeerInfo(
          deviceAddress: _lastConnectAddress ?? current.deviceAddress,
          deviceName: current.deviceName ?? _pendingPeerName,
          ip: current.ip,
          port: current.port,
          isGroupOwner: current.isGroupOwner,
          peerId: current.peerId,
        );
      }
      _pendingRemote = null;
      _openChat();
      // Tell the peer our device name — it has no other way to learn it.
      unawaited(_sendOwnName());
      return;
    }
    if (text.startsWith(_connectIdFrame)) {
      // Format: @@CHATBLUE_ID@@<uid>|<mac>|<name> (mac may be empty).
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

  /// Applies the peer's self-reported device name (arrives right after the
  /// handshake) to the connection identity and the open chat session/app
  /// bar.
  void _applyPeerName(String name) {
    if (name.isEmpty) return;
    // Live-update the request banner while it is still pending.
    pendingRequestName.value = name;
    final current = connectedDevice;
    connectedDevice = WdPeerInfo(
      deviceAddress: current?.deviceAddress ?? _lastConnectAddress ?? 'unknown',
      deviceName: name,
      ip: current?.ip,
      port: current?.port,
      isGroupOwner: current?.isGroupOwner,
      peerId: current?.peerId,
    );
    if (Get.isRegistered<WChatScreenController>()) {
      Get.find<WChatScreenController>().updateSessionName(name);
    }
  }

  /// Whether a string is a real P2P MAC: the framework uses the literal
  /// 'unknown' and the unresolved dummy 02:00:00:00:00:00 for unknown
  /// identities — neither may become a chat session key.
  bool _isUsableMac(String? mac) =>
      mac != null &&
      mac.isNotEmpty &&
      mac != 'unknown' &&
      mac != '02:00:00:00:00:00';

  /// Applies the peer's identity frame: uid (stable per-install id —
  /// authoritative for session KEYING), MAC (display/address) and device
  /// name (banner + app bar + persisted session).
  void _applyPeerIdentity(String? uid, String? mac, String name) {
    final hasUid = uid != null &&
        uid.isNotEmpty &&
        uid != 'unknown' &&
        uid != '02:00:00:00:00:00';
    final hasMac = _isUsableMac(mac);
    if (name.isNotEmpty) {
      pendingRequestName.value = name;
    }
    if (hasUid || hasMac || name.isNotEmpty) {
      final current = connectedDevice;
      connectedDevice = WdPeerInfo(
        deviceAddress: hasMac
            ? mac!
            : (current?.deviceAddress ?? _lastConnectAddress ?? 'unknown'),
        deviceName: name.isNotEmpty ? name : current?.deviceName,
        ip: current?.ip,
        port: current?.port,
        isGroupOwner: current?.isGroupOwner,
        peerId: hasUid ? uid : current?.peerId,
      );
    }
    if (name.isNotEmpty && Get.isRegistered<WChatScreenController>()) {
      Get.find<WChatScreenController>().updateSessionName(name);
    }
  }

  /// Sends this device's identity to the peer as
  /// `@@CHATBLUE_ID@@<uid>|<mac>|<name>` — the uid is the stable session
  /// key for the peer, the MAC/name are display data. Sent once per
  /// connection from both sides, right after the socket is up (before the
  /// READY handshake).
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

  @override
  Future<void> disconnectFromDevice() async {
    if (isConnected.value) {
      await _service.disconnect();
      isConnected.value = false;
    }
  }

  @override
  void onChatClosed() {
    _chatOpen = false;
  }

  /// Called by the chat screen when it opens: suppresses the automatic chat
  /// navigation if a connection arrives while the screen is already visible.
  @override
  void onChatOpened() {
    _chatOpen = true;
  }

  /// Send string to the peer (client/server agnostic)
  @override
  Future<void> sendMessage(String message) async {
    if (isConnected.value) {
      await _service.sendString(message);
    }
  }

  /// Send raw bytes (e.g., image) to the peer
  @override
  Future<void> sendBytes(Uint8List bytes) async {
    if (isConnected.value) {
      await _service.sendBytes(bytes);
    }
  }

  @override
  void onSocketData(Function(Uint8List bytes, String text, {required String kind}) callback) {
    // The controller owns the service slot (for the READY handshake); the
    // chat screen registers its consumer behind the dispatcher.
    _chatDataCallback = callback;
  }

  @override
  void onTransferProgress(
    Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    })
    callback,
  ) {
    _service.onTransferProgress = callback;
  }

  void setupListeners() {
    _service.onPeerFound = (peer) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Peer found: ${peer.deviceName} (${peer.deviceAddress})');
      }
      if (!peers.any((p) => p.deviceAddress == peer.deviceAddress)) {
        peers.add(peer);
      }
    };
    _service.onScanError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Scan error: $message');
      }
      isScanning.value = false;
      Get.snackbar('scanErrorTitle'.tr, message);
    };
    _service.onSocketError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error: $message');
      }
      // Deliberately not surfaced as a snackbar/modal: transient link errors
      // during scanning are common and would spam the UI.
    };
    // The controller owns the service data slot so the READY handshake frame
    // can be intercepted before the chat screen (which is closed at that
    // point) would consume it.
    _service.onSocketData = _dispatchSocketData;
    _service.onSocketConnected = (remote) {
      _pendingRemote = remote;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket connected: ${remote.deviceAddress}');
      }
      // Treat connections arriving shortly after we initiated as part of
      // our own attempt (the peer may be connecting back simultaneously).
      final bool withinInitiationWindow =
          _connectInitiatedAt != null &&
          DateTime.now().difference(_connectInitiatedAt!).inSeconds < 20;

      if (_outgoingConnect || _pendingAccept || withinInitiationWindow) {
        // We initiated the connection (or are still awaiting our own
        // request's acceptance): hold off isConnected/chat until the peer's
        // READY frame arrives. NO banner on this side — the user knows they
        // asked to connect; outcomes surface via isConnected or the
        // declined snackbar.
        _startWaitingAcceptance();
      } else {
        // Incoming request (accepting side): show the request card; the
        // connection only becomes "connected" on user acceptance.
        // The connection supersedes discovery: stop it now (flag AND
        // native) so the scan screen does not show a stale active-scanning
        // state after the chat closes — the framework drops discovery on
        // its own once the group engages; only the Dart flag would linger
        // as "active".
        if (isScanning.value) {
          isScanning.value = false;
          unawaited(_service.stopDiscovery());
        }
        _showIncomingRequest(remote.deviceName ?? remote.deviceAddress);
      }
      // Tell the peer our device name as soon as the socket is up — BEFORE
      // the READY handshake — so its request banner (and chat session) can
      // show a real name instead of "unknown".
      unawaited(_sendOwnName());
    };
    _service.onSocketDisconnected = (reason) {
      isConnected.value = false;
      ConnectionRequestBanner.dismiss();
      _connectInitiatedAt = null;
      if (_pendingAccept) {
        _pendingAccept = false;
        _pendingRemote = null;
        Get.snackbar(
          'connectionDeclinedTitle'.tr,
          'connectionDeclinedMessage'.tr,
          snackPosition: SnackPosition.BOTTOM,
        );
      }
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket disconnected: $reason');
      }
      lastDisconnectReason.value = reason;
    };
  }
}
