import 'dart:async';
import 'package:chatblue/config.dart';
import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WifiController extends GetxController implements ChatTransport {
  final RxList<WdPeerInfo> peers = <WdPeerInfo>[].obs;
  final RxBool isServerModeActive = false.obs;
  final RxBool isScanning = false.obs;
  @override
  final RxBool isConnected = false.obs;
  WdPeerInfo? connectedDevice;
  late WifiDirectService _service;
  @override
  final Rxn<String> lastDisconnectReason = Rxn<String>();
  @override
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  @override
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();
  bool _chatOpen = false;

  @override
  String? get connectedDeviceKey => connectedDevice?.deviceAddress;

  @override
  String? get connectedDeviceName => connectedDevice?.deviceName;

  @override
  void onInit() async {
    //await WifiDirectPlugin.initialize();
    _service = WifiDirectService();
    await _service.initialize();
    setupListeners();
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
    peers.clear();
    await _service.startDiscovery();
    isScanning.value = true;
  }

  Future<void> stopDiscovery() async {
    await _service.stopDiscovery();
    isScanning.value = false;
  }

  /// Connect to a discovered peer and await connection result.
  Future<bool> connectToDevice(WdPeerInfo device) => connectToPeer(device.deviceAddress);

  /// Connect to a peer by address and await the connection result.
  @override
  Future<bool> connectToPeer(String address) async {
    final Completer<bool> completer = Completer<bool>();
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
    _service.onSocketData = callback;
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
      Get.snackbar('Scan error', message);
    };
    _service.onSocketError = (error) {
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket error: $error');
      }
      // Deliberately not surfaced as a snackbar/modal: transient link errors
      // during scanning are common and would spam the UI.
    };
    _service.onSocketConnected = (remote) {
      isConnected.value = true;
      connectedDevice = remote;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket connected: ${remote.deviceAddress}');
      }
      if (!_chatOpen) {
        _chatOpen = true;
        // The scan screen's loading dialog may still be on top: dismiss it
        // BEFORE pushing the chat screen, so no later pop (which removes the
        // top route) can ever close the chat screen by mistake.
        if (Get.isDialogOpen == true) {
          Navigator.of(Get.overlayContext!, rootNavigator: true).pop();
        }
        Get.to(() => const WChatScreen());
      }
    };
    _service.onSocketDisconnected = (reason) {
      isConnected.value = false;
      if (kDebugMode && showDebugLogs) {
        debugPrint('Socket disconnected: $reason');
      }
      lastDisconnectReason.value = reason;
    };
  }
}
