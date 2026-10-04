import 'dart:async';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/screens/b_chatscreen/b_chat_screen.dart';
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
  @override
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  @override
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();
  @override
  final Rxn<String> lastDisconnectReason = Rxn<String>();
  Timer? _serverAutoStopTimer;

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
      Get.snackbar('Scan error', message);
    };

    _service.onSocketConnected = (remote) {
      isConnected.value = true;
      connectedDevice = remote;
      // Refresh paired devices list from native on any new connection
      refreshPairedDevices();
      if (kDebugMode) {
        debugPrint('Socket connected to ${remote.address}');
      }

      if (!_chatOpen) {
        _chatOpen = true;
        // The scan screen's loading dialog may still be on top: dismiss it
        // BEFORE pushing the chat screen, so no later pop (which removes the
        // top route) can ever close the chat screen by mistake.
        if (Get.isDialogOpen == true) {
          Navigator.of(Get.overlayContext!, rootNavigator: true).pop();
        }
        Get.to(() => const BChatScreen());
      }
    };

    _service.onSocketDisconnected = (reason) {
      isConnected.value = false;
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

    super.onInit();
  }

  @override
  String? get connectedDeviceKey => connectedDevice?.address;

  @override
  String? get connectedDeviceName => connectedDevice?.name;

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
    _service.onSocketData = callback;
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

  /// Connect to a discovered or paired device and await connection result.
  Future<bool> connectToDevice(BtDeviceInfo device) => connectToPeer(device.address);

  /// Connect to a peer by MAC address and await the connection result.
  @override
  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();

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
