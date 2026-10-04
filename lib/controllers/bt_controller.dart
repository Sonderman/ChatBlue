import 'dart:async';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
import 'package:chatblue/screens/chat_ui/connection_request.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';

/// High-level GetX controller that orchestrates Bluetooth Classic operations
/// through BtClassicService and exposes reactive UI state.
class BtController extends GetxController implements ChatTransport {
  @override
  final RxBool isConnected = false.obs;
  final RxBool isServerModeActive = false.obs;
  final RxBool isScanning = false.obs;

  final RxList<BtDeviceInfo> scanResults = <BtDeviceInfo>[].obs;
  final RxList<BtDeviceInfo> pairedDevices = <BtDeviceInfo>[].obs;
  BtDeviceInfo? connectedDevice;
  bool _chatOpen = false;

  /// True while this device is the one initiating a connection (no incoming
  /// request banner is shown for self-initiated connects).
  bool _outgoingConnect = false;

  /// When the last `connectToPeer` was started. Incoming socket events
  /// within a short window after an initiation are treated as part of that
  /// initiation (e.g. the peer connecting back simultaneously), so a
  /// "Connection request" card can never appear for a link we started.
  DateTime? _connectInitiatedAt;
  @override
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  @override
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();
  @override
  final Rxn<String> lastDisconnectReason = Rxn<String>();
  Timer? _serverAutoStopTimer;

  /// Frame the ACCEPTING side sends once the user approved the connection;
  /// the initiating side opens its chat only upon receiving it.
  static const String _connectReadyFrame = '@@CHATBLUE_CONNECT@@';

  /// Peer of the pending (not yet accepted) connection attempt.
  BtDeviceInfo? _pendingRemote;

  /// True while THIS device is waiting for the peer's acceptance (initiator
  /// side) — the link exists but is not yet "connected".
  bool _pendingAccept = false;

  /// Data consumer registered by the chat screen; the controller owns the
  /// service's onSocketData slot and delegates through [_dispatchSocketData].
  void Function(Uint8List bytes, String text, {required String kind})?
      _chatDataCallback;

  late BtClassicService _service;

  @override
  void onInit() async {
    _service = BtClassicService();
    await _service.initialize(requestEnableIfDisabled: true);
    await refreshPairedDevices();

    // Wire callbacks (no streams)
    _service.onScanStarted = () {
      isScanning.value = true;
      scanResults.clear();
    };

    _service.onDeviceFound = (d) {
      if (!scanResults.any((e) => e.address == d.address)) {
        scanResults.add(d);
      } else {
        final idx = scanResults.indexWhere((e) => e.address == d.address);
        if (idx != -1) scanResults[idx] = d;
      }
    };

    _service.onScanFinished = () {
      isScanning.value = false;
      if (kDebugMode) {
        debugPrint('Scan finished');
      }
    };

    _service.onScanError = (message) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Scan error: $message');
      }
      isScanning.value = false;
      Get.snackbar('scanErrorTitle'.tr, message);
    };

    _service.onSocketConnected = (remote) {
      _pendingRemote = remote;
      // Refresh paired devices list from native on any new connection
      refreshPairedDevices();
      if (kDebugMode) {
        debugPrint('Socket connected to ${remote.address}');
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
        _showIncomingRequest(remote.name ?? remote.address);
      }
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
      if (kDebugMode) {
        debugPrint('Socket disconnected: $reason');
      }
      // Refresh paired devices list from native on disconnect as well
      refreshPairedDevices();
      lastDisconnectReason.value = reason;
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

    super.onInit();
  }

  @override
  String? get connectedDeviceKey => connectedDevice?.address;

  /// BT has no stable per-install peer id; session keying falls back to the
  /// device address (unchanged behavior).
  @override
  String? get connectedDeviceId => null;

  @override
  String? get connectedDeviceName => connectedDevice?.name;

  @override
  bool get isAwaitingAcceptance => _pendingAccept;

  @override
  void onClose() {
    _serverAutoStopTimer?.cancel();
    _service.stopServer();
    _service.stopScan();
    _service.dispose();
    super.onClose();
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

  @override
  void onSocketData(Function(Uint8List bytes, String text, {required String kind}) callback) {
    // The controller owns the service slot (for the READY handshake); the
    // chat screen registers its consumer behind the dispatcher.
    _chatDataCallback = callback;
  }

  /// Load paired devices (bonded) from native and publish to UI list
  Future<void> refreshPairedDevices() async {
    try {
      final list = await _service.getPairedDevices();
      pairedDevices.assignAll(list);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to load paired devices: $e');
      }
    }
  }

  /// Server: request discoverable then start SPP server
  Future<void> startServer() async {
    final res = await _service.requestDiscoverable(seconds: 300);
    final bool allowed = (res['allowed'] as bool?) ?? false;
    if (allowed) {
      await _service.startServer(serviceName: 'ChatBlueSPP');
      isServerModeActive.value = true;
      // Auto-stop after discoverable duration if provided
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

  /// Stop SPP server
  Future<void> stopServer() async {
    await _service.stopServer();
    isServerModeActive.value = false;
  }

  /// Start discovery with an auto-stop timer
  Future<void> startScan() async {
    scanResults.clear();
    await _service.startScan(autoStopAfter: const Duration(seconds: 60));
  }

  /// Stop discovery manually
  Future<void> stopScan() async {
    await _service.stopScan();
    isScanning.value = false;
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
    Get.to(() => const BChatScreen());
  }

  /// Shows the incoming connection request banner; Accept marks the link as
  /// connected, notifies the initiator with the READY frame and opens the
  /// chat; Decline (or timeout) tears the socket down.
  void _showIncomingRequest(String deviceName) {
    ConnectionRequestBanner.show(
      deviceName: deviceName,
      onAccept: () {
        if (_chatOpen) return;
        isConnected.value = true;
        connectedDevice = _pendingRemote;
        _pendingRemote = null;
        _service.sendString(_connectReadyFrame);
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
      connectedDevice ??= _pendingRemote;
      _pendingRemote = null;
      _openChat();
      return;
    }
    _chatDataCallback?.call(bytes, text, kind: kind);
  }

  /// Connect to a discovered or paired device and await connection result.
  Future<bool> connectToDevice(BtDeviceInfo device) => connectToPeer(device.address);

  /// Connect to a peer by MAC address and await the connection result.
  @override
  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();
    _outgoingConnect = true;
    _connectInitiatedAt = DateTime.now();

    // Stop scanning if still running to avoid connection interference
    if (isScanning.value) {
      await stopScan();
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
      if (remote.address == address && !completer.isCompleted) {
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
      // Note: intentionally not forwarding to prevError — the connecting
      // screen shows its own result message, and forwarding would queue a
      // snackbar behind the loading dialog.
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

  /// Disconnect from current connection
  @override
  Future<void> disconnectFromDevice() async {
    if (isConnected.value) {
      await _service.disconnect();
      isConnected.value = false;
    }
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

  /// Called by ChatViewController when chat screen is closed
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
}
