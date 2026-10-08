import 'dart:async';
import 'package:chatblue/core/platform/nearby_platform_channel.dart';
import 'package:flutter/services.dart';

/// High-level Nearby Connections service wrapper over [NearbyPlatformChannel].
/// Responsibilities:
/// - Preconditions: permissions, Play Services / Bluetooth status
/// - Advertising + discovery lifecycle and results cache
/// - Connection request/accept/reject lifecycle
/// - Framed text/bytes transfer with progress events
/// - Strongly-typed scan/socket event streams
class NearbyService {
  NearbyService();

  final NearbyPlatformChannel _platform = NearbyPlatformChannel.instance;

  final Map<String, NearbyPeerInfo> _peersByEndpointId = <String, NearbyPeerInfo>{};

  StreamSubscription<dynamic>? _scanSubscription;
  StreamSubscription<dynamic>? _socketSubscription;
  final StreamController<NearbyScanEvent> _scanEventsController =
      StreamController<NearbyScanEvent>.broadcast();
  final StreamController<NearbySocketEvent> _socketEventsController =
      StreamController<NearbySocketEvent>.broadcast();

  // region Callbacks
  void Function()? onScanStarted;
  void Function(NearbyPeerInfo peer)? onPeerFound;
  void Function(String endpointId)? onEndpointLost;
  void Function()? onScanFinished;
  void Function(String message)? onScanError;

  void Function(NearbyPeerInfo peer, {required bool incoming, required String authDigits})?
      onConnectionInitiated;
  void Function(NearbyPeerInfo peer)? onSocketConnected;
  void Function(String endpointId)? onConnectionRejected;
  void Function(String reason)? onSocketDisconnected;
  void Function(Uint8List bytes, String text, {required String kind})? onSocketData;
  void Function({
    required String direction,
    required int current,
    required int total,
    required String kind,
  })?
  onTransferProgress;
  void Function(String message)? onSocketError;
  // endregion

  Future<void> initialize() async {
    await _platform.requestNearbyPermissions();
    _ensureEventSubscriptions();
  }

  /// Play Services / Bluetooth status. Fail-open: true/true when the channel
  /// is unavailable (never blocks the normal flow on channel errors).
  Future<NearbyStatus> getStatus() async {
    try {
      final map = await _platform.getNearbyStatus();
      return NearbyStatus.fromMap(map);
    } catch (_) {
      return const NearbyStatus(playServices: true, bluetoothEnabled: true);
    }
  }

  /// Best-effort user-visible device name (OS/Bluetooth name on the native
  /// side, model fallback) — sent as this device's identity bytes so peers
  /// show a recognizable name instead of the hardware model code.
  Future<String> getDeviceName() async {
    try {
      return (await _platform.getDeviceName()).trim();
    } catch (_) {
      return '';
    }
  }

  Future<bool> requestEnableBluetooth() async {
    try {
      return await _platform.requestEnableBluetooth();
    } catch (_) {
      return false;
    }
  }

  // region Discovery / Advertising
  Future<void> startScan({required String name, required String uid}) async {
    _ensureEventSubscriptions();
    _peersByEndpointId.clear();
    await _platform.startScan(uid: uid, name: name);
  }

  Future<void> stopScan() async {
    await _platform.stopScan();
  }

  List<NearbyPeerInfo> get discoveredPeers => _peersByEndpointId.values.toList();
  // endregion

  // region Connection lifecycle
  Future<void> connect(String endpointId, {required String uid, required String name}) async {
    await _platform.connect(endpointId, uid: uid, name: name);
  }

  Future<void> accept(String endpointId) async {
    await _platform.accept(endpointId);
  }

  Future<void> reject(String endpointId) async {
    await _platform.reject(endpointId);
  }

  Future<void> disconnect() async {
    await _platform.disconnect();
  }

  /// Aborts a pending outgoing request (UI "İptal"); best effort.
  Future<void> cancelConnect() async {
    try {
      await _platform.cancelConnect();
    } catch (_) {
      // Fail-open: the wait still resolves via cancelPendingConnect.
    }
  }

  Future<bool> isConnected() {
    return _platform.isConnected();
  }
  // endregion

  // region I/O
  Future<void> sendString(String text) async {
    await _platform.sendString(text);
  }

  Future<void> sendBytes(Uint8List bytes) async {
    await _platform.sendBytes(bytes);
  }
  // endregion

  Stream<NearbyScanEvent> scanEvents() => _scanEventsController.stream;
  Stream<NearbySocketEvent> socketEvents() => _socketEventsController.stream;

  Future<void> dispose() async {
    await _scanSubscription?.cancel();
    await _socketSubscription?.cancel();
    await _scanEventsController.close();
    await _socketEventsController.close();
  }

  void _ensureEventSubscriptions() {
    _scanSubscription ??= _platform.scanEvents().listen(
      (dynamic event) {
        if (event is Map && event['event'] == 'started') {
          onScanStarted?.call();
          _scanEventsController.add(const NearbyScanEvent(type: NearbyScanEventType.started));
          return;
        }
        if (event is Map && event['event'] == 'endpoint') {
          final Map data = (event['data'] as Map? ?? <String, dynamic>{});
          final NearbyPeerInfo info = NearbyPeerInfo.fromMap(data);
          _peersByEndpointId[info.endpointId] = info;
          onPeerFound?.call(info);
          _scanEventsController.add(NearbyScanEvent(type: NearbyScanEventType.peer, peer: info));
          return;
        }
        if (event is Map && event['event'] == 'endpointLost') {
          final Map data = (event['data'] as Map? ?? <String, dynamic>{});
          final String endpointId = (data['endpointId'] as String?) ?? '';
          if (endpointId.isNotEmpty) {
            _peersByEndpointId.remove(endpointId);
          }
          onEndpointLost?.call(endpointId);
          _scanEventsController.add(
            NearbyScanEvent(type: NearbyScanEventType.lost, endpointId: endpointId),
          );
          return;
        }
        if (event is Map && event['event'] == 'finished') {
          onScanFinished?.call();
          _scanEventsController.add(const NearbyScanEvent(type: NearbyScanEventType.finished));
          return;
        }
      },
      onError: (Object error) {
        onScanError?.call(_messageFromError(error));
      },
    );

    _socketSubscription ??= _platform.socketEvents().listen(
      (dynamic event) {
        if (event is! Map) return;
        final String? type = event['event'] as String?;
        switch (type) {
          case 'initiated':
            final Map data = (event['data'] as Map? ?? <String, dynamic>{});
            final NearbyPeerInfo info = NearbyPeerInfo.fromMap(data);
            final bool incoming = (data['incoming'] as bool?) ?? true;
            final String authDigits = (data['authDigits'] as String?) ?? '';
            onConnectionInitiated?.call(info, incoming: incoming, authDigits: authDigits);
            _socketEventsController.add(
              NearbySocketEvent.initiated(peer: info, incoming: incoming, authDigits: authDigits),
            );
            break;
          case 'connected':
            final Map data = (event['data'] as Map? ?? <String, dynamic>{});
            final NearbyPeerInfo info = NearbyPeerInfo.fromMap(data);
            onSocketConnected?.call(info);
            _socketEventsController.add(NearbySocketEvent.connected(peer: info));
            break;
          case 'rejected':
            final Map data = (event['data'] as Map? ?? <String, dynamic>{});
            final String endpointId = (data['endpointId'] as String?) ?? '';
            onConnectionRejected?.call(endpointId);
            _socketEventsController.add(NearbySocketEvent.rejected(endpointId: endpointId));
            break;
          case 'disconnected':
            final String reason = (event['reason'] as String?) ?? 'unknown';
            onSocketDisconnected?.call(reason);
            _socketEventsController.add(NearbySocketEvent.disconnected(reason: reason));
            break;
          case 'data':
            final Uint8List bytes;
            final dynamic raw = event['bytes'];
            if (raw is Uint8List) {
              bytes = raw;
            } else if (raw is List) {
              bytes = Uint8List.fromList(raw.cast<int>());
            } else {
              bytes = Uint8List(0);
            }
            final String text = (event['string'] as String?) ?? '';
            final String kind = (event['kind'] as String?) ?? 'text';
            onSocketData?.call(bytes, text, kind: kind);
            _socketEventsController.add(NearbySocketEvent.data(bytes: bytes, text: text));
            break;
          case 'progress':
            final String direction = (event['direction'] as String?) ?? 'in';
            final int current = (event['current'] as int?) ?? 0;
            final int total = (event['total'] as int?) ?? 0;
            final String kind = (event['kind'] as String?) ?? 'bytes';
            onTransferProgress?.call(
              direction: direction,
              current: current,
              total: total,
              kind: kind,
            );
            break;
        }
      },
      onError: (Object error) {
        onSocketError?.call(_messageFromError(error));
      },
    );
  }

  String _messageFromError(Object error) {
    if (error is PlatformException) {
      return error.message ?? error.code;
    }
    return error.toString();
  }
}

/// Play Services / Bluetooth availability for the Nearby transport.
class NearbyStatus {
  const NearbyStatus({
    required this.playServices,
    required this.bluetoothEnabled,
    this.canAdvertise = true,
  });

  final bool playServices;
  final bool bluetoothEnabled;

  /// Whether the device's Bluetooth stack can advertise over BLE at all.
  /// False only when positively detected (old budget stacks); defaults to
  /// true so an older native side / channel failure never shows a warning.
  final bool canAdvertise;

  static NearbyStatus fromMap(Map<dynamic, dynamic> map) => NearbyStatus(
        playServices: (map['playServices'] as bool?) ?? true,
        bluetoothEnabled: (map['bluetoothEnabled'] as bool?) ?? true,
        canAdvertise: (map['canAdvertise'] as bool?) ?? true,
      );
}

/// A discovered/reachable Nearby endpoint. [uid] is the peer's stable
/// per-install device id (session key); null when the identity bytes were
/// missing or malformed.
class NearbyPeerInfo {
  NearbyPeerInfo({
    required this.endpointId,
    this.endpointName = '',
    this.uid,
  });

  final String endpointId;
  final String endpointName;
  final String? uid;

  static NearbyPeerInfo fromMap(Map<dynamic, dynamic> map) {
    final String rawUid = ((map['uid'] as String?) ?? '').trim();
    return NearbyPeerInfo(
      endpointId: (map['endpointId'] as String?) ?? 'unknown',
      endpointName: ((map['endpointName'] as String?) ?? '').trim(),
      uid: rawUid.isEmpty ? null : rawUid,
    );
  }
}

enum NearbyScanEventType { started, peer, lost, finished }

class NearbyScanEvent {
  const NearbyScanEvent({required this.type, this.peer, this.endpointId});
  final NearbyScanEventType type;
  final NearbyPeerInfo? peer;
  final String? endpointId;
}

enum NearbySocketEventType { initiated, connected, rejected, disconnected, data }

class NearbySocketEvent {
  NearbySocketEvent._({
    required this.type,
    this.peer,
    this.endpointId,
    this.incoming,
    this.authDigits,
    this.reason,
    this.bytes,
    this.text,
  });

  final NearbySocketEventType type;
  final NearbyPeerInfo? peer;
  final String? endpointId;
  final bool? incoming;
  final String? authDigits;
  final String? reason;
  final Uint8List? bytes;
  final String? text;

  factory NearbySocketEvent.initiated({
    required NearbyPeerInfo peer,
    required bool incoming,
    required String authDigits,
  }) =>
      NearbySocketEvent._(
        type: NearbySocketEventType.initiated,
        peer: peer,
        incoming: incoming,
        authDigits: authDigits,
      );

  factory NearbySocketEvent.connected({required NearbyPeerInfo peer}) =>
      NearbySocketEvent._(type: NearbySocketEventType.connected, peer: peer);

  factory NearbySocketEvent.rejected({required String endpointId}) =>
      NearbySocketEvent._(type: NearbySocketEventType.rejected, endpointId: endpointId);

  factory NearbySocketEvent.disconnected({required String reason}) =>
      NearbySocketEvent._(type: NearbySocketEventType.disconnected, reason: reason);

  factory NearbySocketEvent.data({required Uint8List bytes, required String text}) =>
      NearbySocketEvent._(type: NearbySocketEventType.data, bytes: bytes, text: text);
}
