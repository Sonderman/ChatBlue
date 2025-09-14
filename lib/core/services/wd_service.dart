import 'dart:async';
import 'package:chatblue/core/platform/wd_platform_channel.dart';
import 'package:flutter/services.dart';

/// High-level Wi‑Fi Direct service wrapper over WdPlatformChannel.
/// Responsibilities:
/// - Permissions and capability checks
/// - Peer discovery lifecycle and results cache
/// - Group creation (server) and peer connection (client)
/// - TCP socket data transfer with framed text/bytes and progress events
/// - Strongly-typed scan/socket event streams
class WifiDirectService {
  WifiDirectService();

  final WdPlatformChannel _platform = WdPlatformChannel.instance;

  final Map<String, WdPeerInfo> _peersByAddress = <String, WdPeerInfo>{};

  StreamSubscription<dynamic>? _scanSubscription;
  StreamSubscription<dynamic>? _socketSubscription;
  final StreamController<WdScanEvent> _scanEventsController =
      StreamController<WdScanEvent>.broadcast();
  final StreamController<WdSocketEvent> _socketEventsController =
      StreamController<WdSocketEvent>.broadcast();

  Timer? _scanAutoStopTimer;

  // region Callbacks
  void Function()? onScanStarted;
  void Function(WdPeerInfo peer)? onPeerFound;
  void Function()? onScanFinished;
  void Function(String message)? onScanError;

  void Function(WdPeerInfo remote)? onSocketConnected;
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
    await _platform.requestWifiDirectPermissions();
    _ensureEventSubscriptions();
  }

  // region Discovery
  Future<void> startDiscovery({Duration? autoStopAfter}) async {
    _ensureEventSubscriptions();
    _peersByAddress.clear();
    await _platform.clearDiscoveredPeers();
    await _platform.startDiscovery();
    _scanAutoStopTimer?.cancel();
    if (autoStopAfter != null) {
      _scanAutoStopTimer = Timer(autoStopAfter, () {
        stopDiscovery();
      });
    }
  }

  Future<void> stopDiscovery() async {
    _scanAutoStopTimer?.cancel();
    _scanAutoStopTimer = null;
    await _platform.stopDiscovery();
  }

  List<WdPeerInfo> get discoveredPeers => _peersByAddress.values.toList();
  // endregion

  // region Group/Connection
  Future<void> startServer() async {
    await _platform.createGroup();
  }

  Future<void> stopServer() async {
    await _platform.removeGroup();
  }

  Future<void> connect(String deviceAddress) async {
    await _platform.connect(deviceAddress);
  }

  Future<void> disconnect() async {
    await _platform.disconnect();
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

  Stream<WdScanEvent> scanEvents() => _scanEventsController.stream;
  Stream<WdSocketEvent> socketEvents() => _socketEventsController.stream;

  Future<void> dispose() async {
    _scanAutoStopTimer?.cancel();
    _scanAutoStopTimer = null;
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
          _scanEventsController.add(const WdScanEvent(type: WdScanEventType.started));
          return;
        }
        if (event is Map && event['event'] == 'peer') {
          final Map data = (event['data'] as Map? ?? <String, dynamic>{});
          final WdPeerInfo info = WdPeerInfo.fromMap(data);
          _peersByAddress[info.deviceAddress] = info;
          onPeerFound?.call(info);
          _scanEventsController.add(WdScanEvent(type: WdScanEventType.peer, peer: info));
          return;
        }
        if (event is Map && event['event'] == 'finished') {
          onScanFinished?.call();
          _scanEventsController.add(const WdScanEvent(type: WdScanEventType.finished));
          return;
        }
      },
      onError: (Object error) {
        final String message = _messageFromError(error);
        onScanError?.call(message);
      },
    );

    _socketSubscription ??= _platform.socketEvents().listen(
      (dynamic event) {
        if (event is! Map) return;
        final String? type = event['event'] as String?;
        switch (type) {
          case 'connected':
            final Map remote = (event['remote'] as Map? ?? <String, dynamic>{});
            final WdPeerInfo info = WdPeerInfo.fromMap(remote);
            onSocketConnected?.call(info);
            _socketEventsController.add(WdSocketEvent.connected(remote: info));
            break;
          case 'disconnected':
            final String reason = (event['reason'] as String?) ?? 'unknown';
            onSocketDisconnected?.call(reason);
            _socketEventsController.add(WdSocketEvent.disconnected(reason: reason));
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
            _socketEventsController.add(WdSocketEvent.data(bytes: bytes, text: text));
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
        final String message = _messageFromError(error);
        onSocketError?.call(message);
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

class WdPeerInfo {
  WdPeerInfo({required this.deviceAddress, this.deviceName, this.ip, this.port, this.isGroupOwner});

  final String deviceAddress;
  final String? deviceName;
  final String? ip;
  final int? port;
  final bool? isGroupOwner;

  static WdPeerInfo fromMap(Map<dynamic, dynamic> map) {
    return WdPeerInfo(
      deviceAddress: (map['deviceAddress'] as String?) ?? (map['address'] as String?) ?? 'unknown',
      deviceName: map['deviceName'] as String? ?? map['name'] as String?,
      ip: map['ip'] as String?,
      port: map['port'] is int
          ? map['port'] as int
          : (map['port'] is String ? int.tryParse(map['port'] as String) : null),
      isGroupOwner: map['isGroupOwner'] as bool?,
    );
  }
}

enum WdScanEventType { started, peer, finished }

class WdScanEvent {
  const WdScanEvent({required this.type, this.peer});
  final WdScanEventType type;
  final WdPeerInfo? peer;
}

class WdSocketEvent {
  WdSocketEvent._({required this.type, this.remote, this.reason, this.bytes, this.text});

  final WdSocketEventType type;
  final WdPeerInfo? remote;
  final String? reason;
  final Uint8List? bytes;
  final String? text;

  factory WdSocketEvent.connected({required WdPeerInfo remote}) =>
      WdSocketEvent._(type: WdSocketEventType.connected, remote: remote);

  factory WdSocketEvent.disconnected({required String reason}) =>
      WdSocketEvent._(type: WdSocketEventType.disconnected, reason: reason);

  factory WdSocketEvent.data({required Uint8List bytes, required String text}) =>
      WdSocketEvent._(type: WdSocketEventType.data, bytes: bytes, text: text);
}

enum WdSocketEventType { connected, disconnected, data }
