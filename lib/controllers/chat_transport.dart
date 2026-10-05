import 'dart:typed_data';

import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:get/get.dart';

/// Returns the registered instance of [T], or registers a fresh [instance]
/// when none exists yet.
///
/// Screens call this on first access so controllers are created lazily (no
/// permission dialogs at app startup) without depending on `main()` having
/// run — hot reloads re-build the widget tree but do not re-run `main()`.
T ensureRegistered<T extends GetxController>(T instance) {
  if (Get.isRegistered<T>()) {
    return Get.find<T>();
  }
  Get.put<T>(instance);
  return instance;
}

/// Uniform surface over [BtController] and [WifiController] used by the shared
/// chat screen controller so both transports share one implementation.
abstract interface class ChatTransport {
  RxBool get isConnected;
  Rxn<String> get lastDisconnectReason;
  Rxn<TransferState> get outgoingTransfer;
  Rxn<TransferState> get incomingTransfer;

  /// Stable identifier of the connected peer (BT MAC / WFD address).
  String? get connectedDeviceKey;

  /// Stable per-install identifier of the connected peer — used to KEY the
  /// chat session so the same peer always merges into one session. WFD
  /// shares the peer's device uuid over the identity frame (P2P MACs are
  /// randomized and rotate); Bluetooth has no equivalent and returns null,
  /// falling back to [connectedDeviceKey].
  String? get connectedDeviceId => null;

  /// Human-readable name of the connected peer.
  String? get connectedDeviceName;

  /// Identifier of this transport ('bt' for Bluetooth, 'wfd' for Wi‑Fi
  /// Direct — see ChatSessionModel.transportBluetooth/transportWifiDirect)
  /// recorded on chat sessions so the home list can label each chat with
  /// its channel and reopen it through the same transport.
  String get transportType;

  /// Detailed native reason of the most recent failed connect attempt
  /// (e.g. "Location is turned off", "connect failed: BUSY (2)"); the UI
  /// shows it instead of the generic failure message when set.
  Rxn<String> get lastConnectError;

  /// Reconnects to the peer of an opened chat session from its stored
  /// identity. Bluetooth dials the stored address directly; Wi‑Fi Direct
  /// runs discovery first (P2P addresses rotate) and connects on a match,
  /// using [name] as the fallback when the address went stale. Same result
  /// contract as [connectToPeer]; a failure reason lands in
  /// [lastConnectError].
  Future<bool> connectToSessionPeer({
    required String? address,
    String? name,
  });

  /// True while this device initiated a connect and the peer's acceptance
  /// (READY frame) is still pending — the link is alive but not yet
  /// "connected". Callers use this to avoid reporting a false failure when
  /// `connectToPeer` times out while the peer is still deciding.
  bool get isAwaitingAcceptance => false;

  Future<void> disconnectFromDevice();
  Future<void> sendMessage(String message);
  Future<void> sendBytes(Uint8List bytes);

  /// Connects to a peer by its stable address and resolves when the attempt
  /// finishes (or times out). Used by scan screens and by the chat screen's
  /// reconnect button.
  Future<bool> connectToPeer(String address);

  /// Called by the chat screen when it opens. Suppresses the automatic
  /// chat navigation when a connection is established while the chat screen
  /// is already visible (e.g. reconnecting from an opened chat session).
  void onChatOpened();

  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  );

  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  );

  void onChatClosed();
}