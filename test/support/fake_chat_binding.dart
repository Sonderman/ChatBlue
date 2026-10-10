// Shared fake transport binding for the chat-controller and chat-UI tests:
// records every transport call and lets a test fire signals/events
// synchronously. Lives in support/ so both test files exercise the same
// surface (the controller tests + the transport-picker widget tests).
import 'dart:async';
import 'dart:typed_data';

import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/models/chatsession_model.dart';

class FakeChatBinding implements ChatTransportBinding {
  FakeChatBinding({this.transport = ChatSessionModel.transportBluetooth});

  final String transport;
  bool connected = false;
  String? deviceKey;
  String? deviceId;
  String? deviceName;
  int? deviceRssi;
  bool awaiting = false;
  String? connectError;

  final List<String> sentMessages = [];
  final List<Uint8List> sentBytes = [];
  int disconnectCalls = 0;
  int chatOpenedCalls = 0;
  int chatClosedCalls = 0;
  int dialSettledReads = 0;
  int cancelPendingConnectCalls = 0;
  Completer<void>? holdSendMessage;
  Completer<void>? holdConnect;
  Completer<void>? holdDialSettled;
  bool failSendMessage = false;
  final List<({String? address, String? name})> connectCalls = [];
  void Function(Uint8List bytes, String text, {required String kind})?
      dataCallback;
  void Function({
    required String direction,
    required int current,
    required int total,
    required String kind,
  })? progressCallback;
  final List<ChatTransportListener> listeners = [];

  @override
  bool get isConnected => connected;

  @override
  String? get connectedDeviceKey => deviceKey;

  @override
  String? get connectedDeviceId => deviceId;

  @override
  String? get connectedDeviceName => deviceName;

  @override
  int? get connectedDeviceRssi => deviceRssi;

  int? linkQualityValue;

  @override
  int? get linkQuality => linkQualityValue;

  int? liveRssi;

  @override
  Future<int?> getLiveRssi() async => connected ? liveRssi : null;

  @override
  String get transportType => transport;

  @override
  bool get isAwaitingAcceptance => awaiting;

  @override
  String? get lastConnectError => connectError;

  @override
  void addListener(ChatTransportListener listener) => listeners.add(listener);

  @override
  void removeListener(ChatTransportListener listener) =>
      listeners.remove(listener);

  @override
  Future<bool> connectToSessionPeer(
      {required String? address, String? name}) async {
    final hold = holdConnect;
    if (hold != null) await hold.future;
    connectCalls.add((address: address, name: name));
    return true;
  }

  @override
  Future<void> disconnectFromDevice() async {
    disconnectCalls++;
  }

  @override
  Future<void> get dialSettled {
    dialSettledReads++;
    return holdDialSettled?.future ?? Future<void>.value();
  }

  @override
  Future<void> cancelPendingConnect() async {
    cancelPendingConnectCalls++;
  }

  @override
  Future<void> sendMessage(String message) async {
    final hold = holdSendMessage;
    if (hold != null) await hold.future;
    if (failSendMessage) throw StateError('socket write failed');
    sentMessages.add(message);
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sentBytes.add(bytes);
  }

  @override
  void onChatOpened() => chatOpenedCalls++;

  @override
  void onChatClosed() => chatClosedCalls++;

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      dataCallback = callback;

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      progressCallback = callback;

  void emitConnection(bool c) {
    connected = c;
    for (final l in List.of(listeners)) {
      l.onTransportConnectionChanged(c);
    }
  }

  void emitReason(String r) {
    for (final l in List.of(listeners)) {
      l.onTransportDisconnectReason(r);
    }
  }

  void emitPeerName(String n) {
    for (final l in List.of(listeners)) {
      l.onTransportPeerName(n);
    }
  }

  void emitData(Uint8List bytes, String text, {required String kind}) =>
      dataCallback?.call(bytes, text, kind: kind);

  void emitProgress({
    required String direction,
    required int current,
    required int total,
    required String kind,
  }) =>
      progressCallback?.call(
        direction: direction,
        current: current,
        total: total,
        kind: kind,
      );
}
