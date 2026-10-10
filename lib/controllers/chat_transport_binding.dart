import 'dart:typed_data';

import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Receives transport events for one open chat — the GetX-free replacement
/// for the Rx listeners the old GetX bridge mirrored.
abstract class ChatTransportListener {
  void onTransportConnectionChanged(bool connected);
  void onTransportDisconnectReason(String reason);
  void onTransportPeerName(String name);
}

/// Rx'siz transport yüzeyi: bir chat oturumunun ihtiyaç duyduğu her şey.
/// Getter'lar canlı state okur; metotlar transport notifier'ına delege eder.
abstract interface class ChatTransportBinding {
  bool get isConnected;
  String? get connectedDeviceKey;
  String? get connectedDeviceId;
  String? get connectedDeviceName;

  /// Dial-time signal reading for the connection-quality panel (Bluetooth
  /// only — the other transports expose no signal metric).
  int? get connectedDeviceRssi;

  /// Live link RSSI readback for the quality panel; null when the
  /// transport/platform exposes none.
  Future<int?> getLiveRssi();

  /// Coarse live link-quality code for the quality panel (Nearby
  /// Connections only — GMS bandwidth-change events; null while
  /// disconnected or on transports whose platform exposes no such metric).
  int? get linkQuality;

  String get transportType;
  bool get isAwaitingAcceptance;
  String? get lastConnectError;

  void addListener(ChatTransportListener listener);
  void removeListener(ChatTransportListener listener);

  Future<bool> connectToSessionPeer({required String? address, String? name});
  Future<void> disconnectFromDevice();
  Future<void> sendMessage(String message);
  Future<void> sendBytes(Uint8List bytes);
  void onChatOpened();
  void onChatClosed();
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
}

/// Transport başına tek binding (`ChatSessionModel.transportBluetooth` /
/// `transportWifiDirect` / `transportNearby`). Olaylar DEĞİŞİM bazlı
/// sinyallerle chat listener'larına fan-out edilir — GetX Rx semantiği
/// birebir: aynı değerin yeniden yazımı sinyal üretmez.
final chatBindingProvider = Provider.family<ChatTransportBinding, String>(
  (ref, kind) => switch (kind) {
    ChatSessionModel.transportBluetooth => _BtChatBinding(ref),
    ChatSessionModel.transportWifiDirect => _WdChatBinding(ref),
    ChatSessionModel.transportNearby => _NearbyChatBinding(ref),
    _ => throw ArgumentError('Unknown transport kind: $kind'),
  },
);

abstract class _BindingBase {
  _BindingBase(this._ref);

  final Ref _ref;
  final List<ChatTransportListener> _listeners = <ChatTransportListener>[];

  void addListener(ChatTransportListener listener) => _listeners.add(listener);

  void removeListener(ChatTransportListener listener) =>
      _listeners.remove(listener);

  void _emitConnection(bool connected) {
    // Kopya üzerinde döngü: bir listener'ın kendini çıkarması iterasyonu
    // bozmasın (re-entrancy).
    for (final listener in List.of(_listeners)) {
      listener.onTransportConnectionChanged(connected);
    }
  }

  void _emitReason(String reason) {
    for (final listener in List.of(_listeners)) {
      listener.onTransportDisconnectReason(reason);
    }
  }

  void _emitPeerName(String name) {
    for (final listener in List.of(_listeners)) {
      listener.onTransportPeerName(name);
    }
  }
}

class _BtChatBinding extends _BindingBase implements ChatTransportBinding {
  _BtChatBinding(Ref ref) : super(ref) {
    // Değişim takibi kendi alanlarımızda: `ref.listen`'in `previous`
    // parametresi ilk fire'da null olabilir — semantiği o taşımaz.
    _lastConnected = ref.read(btTransportProvider).isConnected;
    _lastReason = ref.read(btTransportProvider).lastDisconnectReason;
    ref.listen(btTransportProvider, _onState);
  }

  bool _lastConnected = false;
  String? _lastReason;

  void _onState(BtTransportState? previous, BtTransportState next) {
    if (next.isConnected != _lastConnected) {
      _lastConnected = next.isConnected;
      _emitConnection(next.isConnected);
    }
    final reason = next.lastDisconnectReason;
    if (reason != null && reason.isNotEmpty && reason != _lastReason) {
      _lastReason = reason;
      _emitReason(reason);
    }
  }

  @override
  bool get isConnected => _ref.read(btTransportProvider).isConnected;

  @override
  String? get lastConnectError =>
      _ref.read(btTransportProvider).lastConnectError;

  @override
  String? get connectedDeviceKey =>
      _ref.read(btTransportProvider.notifier).connectedDeviceKey;

  @override
  String? get connectedDeviceId => null;

  @override
  String? get connectedDeviceName =>
      _ref.read(btTransportProvider.notifier).connectedDeviceName;

  @override
  int? get connectedDeviceRssi =>
      _ref.read(btTransportProvider.notifier).connectedDeviceRssi;

  @override
  Future<int?> getLiveRssi() =>
      _ref.read(btTransportProvider.notifier).getLiveRssi();

  @override
  int? get linkQuality => null;

  @override
  String get transportType =>
      _ref.read(btTransportProvider.notifier).transportType;

  @override
  bool get isAwaitingAcceptance =>
      _ref.read(btTransportProvider.notifier).isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      _ref
          .read(btTransportProvider.notifier)
          .connectToSessionPeer(address: address, name: name);

  @override
  Future<void> disconnectFromDevice() =>
      _ref.read(btTransportProvider.notifier).disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) =>
      _ref.read(btTransportProvider.notifier).sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) =>
      _ref.read(btTransportProvider.notifier).sendBytes(bytes);

  @override
  void onChatOpened() =>
      _ref.read(btTransportProvider.notifier).onChatOpened();

  @override
  void onChatClosed() =>
      _ref.read(btTransportProvider.notifier).onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      _ref.read(btTransportProvider.notifier).onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      _ref.read(btTransportProvider.notifier).onTransferProgress(callback);
}

class _WdChatBinding extends _BindingBase implements ChatTransportBinding {
  _WdChatBinding(Ref ref) : super(ref) {
    _lastConnected = ref.read(wdTransportProvider).isConnected;
    _lastReason = ref.read(wdTransportProvider).lastDisconnectReason;
    ref.listen(wdTransportProvider, _onState);
    // The peer's name frame reaches the chat instantly — the old adapter
    // installed this same hook.
    ref.read(wdTransportProvider.notifier).onPeerNameForChat = _emitPeerName;
  }

  bool _lastConnected = false;
  String? _lastReason;

  void _onState(WdTransportState? previous, WdTransportState next) {
    if (next.isConnected != _lastConnected) {
      _lastConnected = next.isConnected;
      _emitConnection(next.isConnected);
    }
    final reason = next.lastDisconnectReason;
    if (reason != null && reason.isNotEmpty && reason != _lastReason) {
      _lastReason = reason;
      _emitReason(reason);
    }
  }

  @override
  bool get isConnected => _ref.read(wdTransportProvider).isConnected;

  @override
  String? get lastConnectError =>
      _ref.read(wdTransportProvider).lastConnectError;

  @override
  String? get connectedDeviceKey =>
      _ref.read(wdTransportProvider.notifier).connectedDeviceKey;

  @override
  String? get connectedDeviceId =>
      _ref.read(wdTransportProvider.notifier).connectedDeviceId;

  @override
  String? get connectedDeviceName =>
      _ref.read(wdTransportProvider.notifier).connectedDeviceName;

  @override
  int? get connectedDeviceRssi => null;

  @override
  Future<int?> getLiveRssi() =>
      _ref.read(wdTransportProvider.notifier).getLiveRssi();

  @override
  int? get linkQuality => null;

  @override
  String get transportType =>
      _ref.read(wdTransportProvider.notifier).transportType;

  @override
  bool get isAwaitingAcceptance =>
      _ref.read(wdTransportProvider.notifier).isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      _ref
          .read(wdTransportProvider.notifier)
          .connectToSessionPeer(address: address, name: name);

  @override
  Future<void> disconnectFromDevice() =>
      _ref.read(wdTransportProvider.notifier).disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) =>
      _ref.read(wdTransportProvider.notifier).sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) =>
      _ref.read(wdTransportProvider.notifier).sendBytes(bytes);

  @override
  void onChatOpened() =>
      _ref.read(wdTransportProvider.notifier).onChatOpened();

  @override
  void onChatClosed() =>
      _ref.read(wdTransportProvider.notifier).onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      _ref.read(wdTransportProvider.notifier).onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      _ref.read(wdTransportProvider.notifier).onTransferProgress(callback);
}

class _NearbyChatBinding extends _BindingBase implements ChatTransportBinding {
  _NearbyChatBinding(Ref ref) : super(ref) {
    _lastConnected = ref.read(nearbyTransportProvider).isConnected;
    _lastReason = ref.read(nearbyTransportProvider).lastDisconnectReason;
    ref.listen(nearbyTransportProvider, _onState);
  }

  bool _lastConnected = false;
  String? _lastReason;

  void _onState(NearbyTransportState? previous, NearbyTransportState next) {
    if (next.isConnected != _lastConnected) {
      _lastConnected = next.isConnected;
      _emitConnection(next.isConnected);
    }
    final reason = next.lastDisconnectReason;
    if (reason != null && reason.isNotEmpty && reason != _lastReason) {
      _lastReason = reason;
      _emitReason(reason);
    }
  }

  @override
  bool get isConnected => _ref.read(nearbyTransportProvider).isConnected;

  @override
  String? get lastConnectError =>
      _ref.read(nearbyTransportProvider).lastConnectError;

  @override
  String? get connectedDeviceKey =>
      _ref.read(nearbyTransportProvider.notifier).connectedDeviceKey;

  @override
  String? get connectedDeviceId =>
      _ref.read(nearbyTransportProvider.notifier).connectedDeviceId;

  @override
  String? get connectedDeviceName =>
      _ref.read(nearbyTransportProvider.notifier).connectedDeviceName;

  @override
  int? get connectedDeviceRssi => null;

  @override
  Future<int?> getLiveRssi() async => null;

  @override
  int? get linkQuality =>
      _ref.read(nearbyTransportProvider.notifier).linkQuality;

  @override
  String get transportType =>
      _ref.read(nearbyTransportProvider.notifier).transportType;

  @override
  bool get isAwaitingAcceptance =>
      _ref.read(nearbyTransportProvider.notifier).isAwaitingAcceptance;

  @override
  Future<bool> connectToSessionPeer({required String? address, String? name}) =>
      _ref
          .read(nearbyTransportProvider.notifier)
          .connectToSessionPeer(address: address, name: name);

  @override
  Future<void> disconnectFromDevice() =>
      _ref.read(nearbyTransportProvider.notifier).disconnectFromDevice();

  @override
  Future<void> sendMessage(String message) =>
      _ref.read(nearbyTransportProvider.notifier).sendMessage(message);

  @override
  Future<void> sendBytes(Uint8List bytes) =>
      _ref.read(nearbyTransportProvider.notifier).sendBytes(bytes);

  @override
  void onChatOpened() =>
      _ref.read(nearbyTransportProvider.notifier).onChatOpened();

  @override
  void onChatClosed() =>
      _ref.read(nearbyTransportProvider.notifier).onChatClosed();

  @override
  void onSocketData(
    void Function(Uint8List bytes, String text, {required String kind}) callback,
  ) =>
      _ref.read(nearbyTransportProvider.notifier).onSocketData(callback);

  @override
  void onTransferProgress(
    void Function({
      required String direction,
      required int current,
      required int total,
      required String kind,
    }) callback,
  ) =>
      _ref.read(nearbyTransportProvider.notifier).onTransferProgress(callback);
}
