import 'dart:typed_data';

import 'package:chatblue/controllers/chat_transport.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:chatblue/screens/w_chatscreen/w_chatscreen_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';

/// GetX→Riverpod köprüsü: transport notifier'larını Rx'li [ChatTransport]
/// olarak sunar. GetX chat tarafı (chat controller + Obx UI) F3'e kadar bu
/// adapter'ı `Get.put` üzerinden kullanır; F3'te sökülür.
///
/// Rx'ler notifier state'inden beslenir (tek yönlü: değerler her zaman
/// notifier'da doğar; transfer state'leri hariç — onlar doğrudan Rx'te
/// tutulur çünkü değerlerini chat tarafı üretir).
abstract class _TransportAdapterBase<TNotifier extends Notifier<TState>, TState>
    extends GetxController implements ChatTransport {
  _TransportAdapterBase(this._provider, this.notifier) {
    // fireImmediately: the adapter is created when the chat screen opens,
    // which can happen AFTER the connection is established (the notifier
    // flips `isConnected` while the scan screen / incoming-request banner is
    // up). Without fireImmediately the current state is never mirrored and
    // the chat UI renders "not connected" (Connect button, no composer)
    // even though the transport is up.
    _sub = rootProviderContainer?.listen(_provider, (_, next) {
      _sync(next);
    }, fireImmediately: true);
  }

  final NotifierProvider<TNotifier, TState> _provider;
  final TNotifier notifier;
  ProviderSubscription<TState>? _sub;

  @override
  final RxBool isConnected = false.obs;
  @override
  final Rxn<String> lastDisconnectReason = Rxn<String>();
  @override
  final Rxn<String> lastConnectError = Rxn<String>();
  @override
  final Rxn<TransferState> outgoingTransfer = Rxn<TransferState>();
  @override
  final Rxn<TransferState> incomingTransfer = Rxn<TransferState>();

  void _sync(TState state);

  @override
  void onClose() {
    _sub?.close();
    super.onClose();
  }
}

/// Bluetooth chat transport bridge (GetX side). Requires the root
/// ProviderContainer (attached in `main()`).
class BtTransportAdapter
    extends _TransportAdapterBase<BtTransportNotifier, BtTransportState> {
  BtTransportAdapter()
      : super(
          btTransportProvider,
          rootProviderContainer!.read(btTransportProvider.notifier),
        ) {
    // GetX çevirileri notifier'ın key-based köprüsüne bağlanır (notifier
    // GetX'sizdir; F4'te çeviri kaynağı gen_l10n olur).
    notifier.translate = (key, {params}) => key.trParams(params ?? const {});
  }

  @override
  void _sync(BtTransportState s) {
    isConnected.value = s.isConnected;
    lastDisconnectReason.value = s.lastDisconnectReason;
    lastConnectError.value = s.lastConnectError;
  }

  @override
  String? get connectedDeviceKey => notifier.connectedDeviceKey;

  @override
  String? get connectedDeviceId => null;

  @override
  String? get connectedDeviceName => notifier.connectedDeviceName;

  @override
  String get transportType => notifier.transportType;

  @override
  bool get isAwaitingAcceptance => notifier.isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      notifier.connectToSessionPeer(address: address, name: name);

  @override
  Future<bool> connectToPeer(String address) => notifier.connectToPeer(address);

  @override
  Future<void> disconnectFromDevice() => notifier.disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) => notifier.sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) => notifier.sendBytes(bytes);

  @override
  void onChatOpened() => notifier.onChatOpened();

  @override
  void onChatClosed() => notifier.onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      notifier.onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      notifier.onTransferProgress(callback);
}

/// Wi‑Fi Direct chat transport bridge (GetX side). Requires the root
/// ProviderContainer (attached in `main()`).
class WdTransportAdapter
    extends _TransportAdapterBase<WdTransportNotifier, WdTransportState> {
  WdTransportAdapter()
      : super(
          wdTransportProvider,
          rootProviderContainer!.read(wdTransportProvider.notifier),
        ) {
    // GetX çevirileri notifier'ın key-based köprüsüne bağlanır (notifier
    // GetX'sizdir; F4'te çeviri kaynağı gen_l10n olur).
    notifier.translate = (key, {params}) => key.trParams(params ?? const {});
    notifier.onPeerNameForChat = (name) {
      if (Get.isRegistered<WChatScreenController>()) {
        Get.find<WChatScreenController>().updateSessionName(name);
      }
    };
  }

  @override
  void _sync(WdTransportState s) {
    isConnected.value = s.isConnected;
    lastDisconnectReason.value = s.lastDisconnectReason;
    lastConnectError.value = s.lastConnectError;
  }

  @override
  String? get connectedDeviceKey => notifier.connectedDeviceKey;

  @override
  String? get connectedDeviceId => notifier.connectedDeviceId;

  @override
  String? get connectedDeviceName => notifier.connectedDeviceName;

  @override
  String get transportType => notifier.transportType;

  @override
  bool get isAwaitingAcceptance => notifier.isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      notifier.connectToSessionPeer(address: address, name: name);

  @override
  Future<bool> connectToPeer(String address) => notifier.connectToPeer(address);

  @override
  Future<void> disconnectFromDevice() => notifier.disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) => notifier.sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) => notifier.sendBytes(bytes);

  @override
  void onChatOpened() => notifier.onChatOpened();

  @override
  void onChatClosed() => notifier.onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      notifier.onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      notifier.onTransferProgress(callback);
}

/// Nearby Connections chat transport bridge (GetX side). Requires the root
/// ProviderContainer (attached in `main()`).
class NearbyTransportAdapter
    extends _TransportAdapterBase<NearbyTransportNotifier, NearbyTransportState> {
  NearbyTransportAdapter()
      : super(
          nearbyTransportProvider,
          rootProviderContainer!.read(nearbyTransportProvider.notifier),
        ) {
    // GetX çevirileri notifier'ın key-based köprüsüne bağlanır (notifier
    // GetX'sizdir; ported ekranlar gen_l10n eşlemesini kurar).
    notifier.translate = (key, {params}) => key.trParams(params ?? const {});
  }

  @override
  void _sync(NearbyTransportState s) {
    isConnected.value = s.isConnected;
    lastDisconnectReason.value = s.lastDisconnectReason;
    lastConnectError.value = s.lastConnectError;
  }

  @override
  String? get connectedDeviceKey => notifier.connectedDeviceKey;

  @override
  String? get connectedDeviceId => notifier.connectedDeviceId;

  @override
  String? get connectedDeviceName => notifier.connectedDeviceName;

  @override
  String get transportType => notifier.transportType;

  @override
  bool get isAwaitingAcceptance => notifier.isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      notifier.connectToSessionPeer(address: address, name: name);

  @override
  Future<bool> connectToPeer(String address) => notifier.connectToPeer(address);

  @override
  Future<void> disconnectFromDevice() => notifier.disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) => notifier.sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) => notifier.sendBytes(bytes);

  @override
  void onChatOpened() => notifier.onChatOpened();

  @override
  void onChatClosed() => notifier.onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      notifier.onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      notifier.onTransferProgress(callback);
}