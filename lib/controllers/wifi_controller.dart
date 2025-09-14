import 'dart:async';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/screens/w_chatscreen/w_chat_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

class WifiController extends GetxController {
  final RxList<WdPeerInfo> peers = <WdPeerInfo>[].obs;
  final RxBool isServerModeActive = false.obs;
  final RxBool isScanning = false.obs;
  final RxBool isConnected = false.obs;
  WdPeerInfo? connectedDevice;
  late WifiDirectService _service;
  late Rxn<String> lastDisconnectReason;
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();
  bool _chatOpen = false;

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

  /// Connect to a discovered or paired device and await connection result.
  Future<bool> connectToDevice(WdPeerInfo device) async {
    final Completer<bool> completer = Completer<bool>();
    if (kDebugMode) {
      print('connecting to device: ${device.deviceName}');
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
      if (remote.deviceAddress == device.deviceAddress && !completer.isCompleted) {
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
      await _service.connect(device.deviceAddress);
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

  Future<void> disconnectFromDevice() async {
    if (isConnected.value) {
      await _service.disconnect();
      isConnected.value = false;
    }
  }

  void onChatClosed() {
    _chatOpen = false;
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

  void onSocketData(Function(Uint8List bytes, String text, {required String kind}) callback) {
    _service.onSocketData = callback;
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

  void setupListeners() {
    _service.onPeerFound = (peer) {
      print('Peer found: ${peer.deviceName} (${peer.deviceAddress})');
      peers.add(peer);
      update();
    };
    _service.onSocketError = (error) {
      print('Socket error: $error');
    };
    _service.onSocketConnected = (remote) {
      isConnected.value = true;
      connectedDevice = remote;
      print('Socket connected: ${remote.deviceAddress}');
      if (!_chatOpen) {
        _chatOpen = true;
        Get.to(() => const WChatScreen());
      }
    };
    _service.onSocketDisconnected = (reason) {
      isConnected.value = false;
      print('Socket disconnected: $reason');
      update();
    };
  }
}
