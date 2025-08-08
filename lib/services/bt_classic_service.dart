import 'dart:async';

import 'package:chatblue/platform/bt_platform_channel.dart';
import 'package:flutter/services.dart';

/// High-level service wrapper over BtPlatformChannel for Bluetooth Classic.
/// Responsibilities:
/// - Permissions and enabling Bluetooth
/// - Discoverable request flow
/// - Device discovery (scan) lifecycle and results cache
/// - Paired devices listing
/// - RFCOMM server/client connection and data transfer (String/Uint8List)
/// - Exposes strongly-typed scan/socket event streams
class BtClassicService {
  BtClassicService();

  final BtPlatformChannel _platform = BtPlatformChannel.instance;

  final Map<String, BtDeviceInfo> _discoveredByAddress = <String, BtDeviceInfo>{};

  StreamSubscription<dynamic>? _scanSubscription;
  StreamSubscription<dynamic>? _socketSubscription;
  final StreamController<BtScanEvent> _scanEventsController =
      StreamController<BtScanEvent>.broadcast();
  final StreamController<BtSocketEvent> _socketEventsController =
      StreamController<BtSocketEvent>.broadcast();

  Timer? _scanAutoStopTimer;

  // region Callbacks
  /// Called when discovery starts.
  void Function()? onScanStarted;

  /// Called when a device is found during discovery.
  void Function(BtDeviceInfo device)? onDeviceFound;

  /// Called when discovery finishes.
  void Function()? onScanFinished;

  /// Called when a scan error occurs (platform stream error).
  void Function(String message)? onScanError;

  /// Called when RFCOMM socket connection is established.
  void Function(BtDeviceInfo remote)? onSocketConnected;

  /// Called when RFCOMM socket disconnects.
  void Function(String reason)? onSocketDisconnected;

  /// Called when data is received over RFCOMM.
  void Function(Uint8List bytes, String text, {required String kind})? onSocketData;

  /// Called when a socket error occurs (platform stream error).
  void Function(String message)? onSocketError;

  /// Called for transfer progress updates.
  /// direction: 'in' or 'out'; kind: 'text' or 'bytes'; current/total bytes
  void Function({
    required String direction,
    required int current,
    required int total,
    required String kind,
  })?
  onTransferProgress;
  // endregion

  /// Initialize service: requests runtime permissions and (optionally) asks user
  /// to enable Bluetooth if disabled.
  Future<void> initialize({bool requestEnableIfDisabled = true}) async {
    await _platform.requestBluetoothPermissions();
    final bool enabled = await _platform.isBluetoothEnabled();
    if (!enabled && requestEnableIfDisabled) {
      await _platform.requestEnableBluetooth();
    }
    _ensureEventSubscriptions();
  }

  /// Ask the system to make the device discoverable for [seconds] (1..300).
  Future<Map> requestDiscoverable({int seconds = 120}) {
    return _platform.requestDiscoverable(seconds: seconds);
  }

  /// Start discovery (scanning). If [autoStopAfter] set, discovery will be
  /// automatically stopped after the duration.
  Future<void> startScan({Duration? autoStopAfter}) async {
    _ensureEventSubscriptions();
    _discoveredByAddress.clear();
    await _platform.clearDiscoveredDevices();
    await _platform.startScan();
    _scanAutoStopTimer?.cancel();
    if (autoStopAfter != null) {
      _scanAutoStopTimer = Timer(autoStopAfter, () {
        stopScan();
      });
    }
  }

  /// Stop discovery (scanning).
  Future<void> stopScan() async {
    _scanAutoStopTimer?.cancel();
    _scanAutoStopTimer = null;
    await _platform.stopScan();
  }

  /// Read-only snapshot of discovered devices cache.
  List<BtDeviceInfo> get discoveredDevices =>
      _discoveredByAddress.values.toList()
        ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));

  /// Fetch paired (bonded) devices from the system.
  Future<List<BtDeviceInfo>> getPairedDevices() async {
    final List<Map> raw = await _platform.getPairedDevices();
    return raw.map(BtDeviceInfo.fromMap).toList();
  }

  /// Begin SPP server (RFCOMM) with [serviceName] and optional [uuid].
  Future<void> startServer({String serviceName = 'ChatBlueSPP', String? uuid}) async {
    await _platform.startServer(serviceName: serviceName, uuid: uuid);
  }

  /// Stop SPP server.
  Future<void> stopServer() async {
    await _platform.stopServer();
  }

  /// Connect to a device by MAC [address]. Optional [uuid] overrides default SPP UUID.
  Future<void> connect(String address, {String? uuid}) async {
    await _platform.connect(address, uuid: uuid);
  }

  /// Disconnect the current socket connection.
  Future<void> disconnect() async {
    await _platform.disconnect();
  }

  /// Returns whether the socket is connected.
  Future<bool> isConnected() {
    return _platform.isConnected();
  }

  /// Send a UTF-8 encoded text over the socket.
  Future<void> sendString(String text) async {
    await _platform.sendString(text);
  }

  /// Send raw bytes over the socket.
  Future<void> sendBytes(Uint8List bytes) async {
    await _platform.sendBytes(bytes);
  }

  /// Stream of scan events (started, device, finished) with typed payload.
  Stream<BtScanEvent> scanEvents() => _scanEventsController.stream;

  /// Stream of socket events (connected, disconnected, data) with typed payload.
  Stream<BtSocketEvent> socketEvents() => _socketEventsController.stream;

  /// Release resources and subscriptions.
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
          _scanEventsController.add(const BtScanEvent(type: BtScanEventType.started));
          return;
        }
        if (event is Map && event['event'] == 'device') {
          final Map data = (event['data'] as Map? ?? <String, dynamic>{});
          final BtDeviceInfo info = BtDeviceInfo.fromMap(data);
          _discoveredByAddress[info.address] = info;
          onDeviceFound?.call(info);
          _scanEventsController.add(BtScanEvent(type: BtScanEventType.device, device: info));
          return;
        }
        if (event is Map && event['event'] == 'finished') {
          onScanFinished?.call();
          _scanEventsController.add(const BtScanEvent(type: BtScanEventType.finished));
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
            final BtDeviceInfo info = BtDeviceInfo.fromMap(remote);
            onSocketConnected?.call(info);
            _socketEventsController.add(BtSocketEvent.connected(remote: info));
            break;
          case 'disconnected':
            final String reason = (event['reason'] as String?) ?? 'unknown';
            onSocketDisconnected?.call(reason);
            _socketEventsController.add(BtSocketEvent.disconnected(reason: reason));
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
            _socketEventsController.add(BtSocketEvent.data(bytes: bytes, text: text));
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

/// Represents a discovered or remote Bluetooth device snapshot.
class BtDeviceInfo {
  BtDeviceInfo({required this.address, this.name, this.rssi, this.type, this.bondState});

  final String address;
  final String? name;
  final int? rssi;
  final int? type;
  final int? bondState;

  static BtDeviceInfo fromMap(Map<dynamic, dynamic> map) {
    return BtDeviceInfo(
      address: (map['address'] as String?) ?? 'unknown',
      name: map['name'] as String?,
      rssi: (map['rssi'] is int) ? map['rssi'] as int : null,
      type: (map['type'] is int) ? map['type'] as int : null,
      bondState: (map['bondState'] is int) ? map['bondState'] as int : null,
    );
  }
}

/// Scan event types for discovery lifecycle.
enum BtScanEventType { started, device, finished }

/// A single scan event with optional device payload.
class BtScanEvent {
  const BtScanEvent({required this.type, this.device});

  final BtScanEventType type;
  final BtDeviceInfo? device;
}

/// Socket event discriminated union.
class BtSocketEvent {
  BtSocketEvent._({required this.type, this.remote, this.reason, this.bytes, this.text});

  final BtSocketEventType type;
  final BtDeviceInfo? remote;
  final String? reason;
  final Uint8List? bytes;
  final String? text;

  factory BtSocketEvent.connected({required BtDeviceInfo remote}) =>
      BtSocketEvent._(type: BtSocketEventType.connected, remote: remote);

  factory BtSocketEvent.disconnected({required String reason}) =>
      BtSocketEvent._(type: BtSocketEventType.disconnected, reason: reason);

  factory BtSocketEvent.data({required Uint8List bytes, required String text}) =>
      BtSocketEvent._(type: BtSocketEventType.data, bytes: bytes, text: text);
}

class TransferState {
  TransferState({
    required this.direction,
    required this.current,
    required this.total,
    required this.kind,
  });
  final String direction; // 'in' or 'out'
  final int current;
  final int total;
  final String kind; // 'text' | 'bytes'
}

/// Socket event kinds.
enum BtSocketEventType { connected, disconnected, data }
