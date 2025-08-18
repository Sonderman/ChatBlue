import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/screens/chat_screen.dart';

/// High-level GetX controller that orchestrates Bluetooth Classic operations
/// through BtClassicService and exposes reactive UI state.
class BtController extends GetxController {
  final RxBool isConnected = false.obs;
  final RxBool isServerModeActive = false.obs;
  final RxBool isScanning = false.obs;

  final RxList<BtDeviceInfo> scanResults = <BtDeviceInfo>[].obs;
  final RxList<BtDeviceInfo> pairedDevices = <BtDeviceInfo>[].obs;
  BtDeviceInfo? connectedDevice;
  bool _chatOpen = false;
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();
  final Rxn<String> lastDisconnectReason = Rxn<String>();

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
        print('Scan finished');
      }
    };

    _service.onScanError = (message) {
      if (kDebugMode) {
        print('Scan error: $message');
      }
    };

    _service.onSocketConnected = (remote) {
      isConnected.value = true;
      connectedDevice = remote;
      // Refresh paired devices list from native on any new connection
      refreshPairedDevices();
      if (kDebugMode) {
        print('Socket connected to ${remote.address}');
      }

      if (!_chatOpen) {
        _chatOpen = true;
        Get.to(() => const ChatScreen());
      }
    };

    _service.onSocketDisconnected = (reason) {
      isConnected.value = false;
      if (kDebugMode) {
        print('Socket disconnected: $reason');
      }
      // Refresh paired devices list from native on disconnect as well
      refreshPairedDevices();
      lastDisconnectReason.value = reason;
    };

    _service.onSocketError = (message) {
      if (kDebugMode) {
        print('Socket error: $message');
      }
    };

    super.onInit();
  }

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
        print('Failed to load paired devices: $e');
      }
    }
  }

  @override
  void onClose() {
    _service.stopServer();
    _service.stopScan();
    _service.dispose();
    super.onClose();
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
        Future.delayed(Duration(seconds: durationSec), () {
          stopServer();
        });
      }
    } else {
      if (kDebugMode) print('Discoverable request denied');
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
  Future<bool> connectToDevice(BtDeviceInfo device) async {
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
      if (remote.address == device.address && !completer.isCompleted) {
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
      if (kDebugMode) {
        print('Socket error during connect: $message');
      }
      prevError?.call(message);
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    };

    try {
      await _service.connect(device.address);
    } catch (e) {
      if (kDebugMode) {
        print('Error initiating connection: $e');
      }
      // Ensure any lingering dialogs are dismissed
      if (Get.isDialogOpen == true) {
        Get.back();
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
      if (Get.isDialogOpen == true) {
        Get.back();
      }
      return result;
    } catch (_) {
      restore();
      if (Get.isDialogOpen == true) {
        Get.back();
      }
      return false;
    }
  }

  /// Disconnect from current connection
  Future<void> disconnectFromDevice() async {
    if (isConnected.value) {
      await _service.disconnect();
      isConnected.value = false;
    }
  }

  /// Send string to the peer (client/server agnostic)
  Future<void> sendMessage(String message) async {
    if (isConnected.value) {
      await _service.sendString(message);
    }
  }

  /// Send raw bytes (e.g., image) to the peer
  Future<void> sendBytes(Uint8List bytes) async {
    if (isConnected.value) {
      await _service.sendBytes(bytes);
    }
  }

  /// Called by ChatViewController when chat screen is closed
  void onChatClosed() {
    _chatOpen = false;
  }
}
