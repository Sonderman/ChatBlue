import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';

/// Platform channel wrapper for Android Wi‑Fi Direct (Wi‑Fi P2P).
/// Provides discovery, connection lifecycle, and framed socket I/O for
/// String/Uint8List data similar to BtPlatformChannel.
class WdPlatformChannel {
  WdPlatformChannel._();
  static final WdPlatformChannel instance = WdPlatformChannel._();

  // Channel names must match native side in MainActivity/WifiDirectManager
  static const MethodChannel _method = MethodChannel('com.sondermium.chatblue/wd');
  static const EventChannel _scanEvents = EventChannel('com.sondermium.chatblue/wd_scan');
  static const EventChannel _socketEvents = EventChannel('com.sondermium.chatblue/wd_socket');

  Stream<dynamic>? _scanStream;
  Stream<dynamic>? _socketStream;

  // region Permissions / Capability
  Future<Map> requestWifiDirectPermissions() async {
    final Map result = await _method.invokeMethod('requestWifiDirectPermissions');
    return result;
  }

  Future<bool> isWifiP2pSupported() async {
    final bool ok = await _method.invokeMethod('isWifiP2pSupported');
    return ok;
  }
  // endregion

  // region Discovery
  Future<bool> startDiscovery() async {
    final bool ok = await _method.invokeMethod('startDiscovery');
    return ok;
  }

  Future<bool> stopDiscovery() async {
    final bool ok = await _method.invokeMethod('stopDiscovery');
    return ok;
  }

  Future<List<Map>> getDiscoveredPeers() async {
    final List list = await _method.invokeMethod('getDiscoveredPeers');
    return list.cast<Map>();
  }

  Future<bool> clearDiscoveredPeers() async {
    final bool ok = await _method.invokeMethod('clearDiscoveredPeers');
    return ok;
  }

  /// Scan events yield maps like:
  /// { 'event': 'started' | 'peer' | 'finished', 'data'?: {deviceName, deviceAddress, ...} }
  Stream<dynamic> scanEvents() {
    return _scanStream ??= _scanEvents.receiveBroadcastStream().asBroadcastStream();
  }
  // endregion

  // region Group / Connection
  /// Attempts to create a group and become a Group Owner (server).
  Future<bool> createGroup() async {
    final bool ok = await _method.invokeMethod('createGroup');
    return ok;
  }

  /// Remove current group (disconnects peers and closes sockets).
  Future<bool> removeGroup() async {
    final bool ok = await _method.invokeMethod('removeGroup');
    return ok;
  }

  /// Connect to a peer by its Wi‑Fi P2P device address.
  Future<bool> connect(String deviceAddress) async {
    final bool ok = await _method.invokeMethod('connect', {'deviceAddress': deviceAddress});
    return ok;
  }

  Future<bool> disconnect() async {
    final bool ok = await _method.invokeMethod('disconnect');
    return ok;
  }

  Future<bool> isConnected() async {
    final bool ok = await _method.invokeMethod('isConnected');
    return ok;
  }
  // endregion

  // region Socket I/O
  Future<bool> sendString(String text) async {
    final bool ok = await _method.invokeMethod('sendString', {'text': text});
    return ok;
  }

  Future<bool> sendBytes(Uint8List bytes) async {
    final bool ok = await _method.invokeMethod('sendBytes', {'bytes': bytes});
    return ok;
  }

  /// Socket events yield:
  /// - { 'event': 'connected', 'remote': { deviceName, deviceAddress, ip, port, isGroupOwner } }
  /// - { 'event': 'disconnected', 'reason': String }
  /// - { 'event': 'data', 'kind': 'text'|'bytes', 'bytes': Uint8List, 'string': String }
  /// - { 'event': 'progress', 'direction': 'in'|'out', 'current': int, 'total': int, 'kind': 'text'|'bytes' }
  Stream<dynamic> socketEvents() {
    return _socketStream ??= _socketEvents.receiveBroadcastStream().map((dynamic event) {
      if (event is Map && event['event'] == 'data') {
        final dynamic raw = event['bytes'];
        if (raw is! Uint8List && raw is List) {
          return {...event, 'bytes': Uint8List.fromList(raw.cast<int>())};
        }
      }
      return event;
    }).asBroadcastStream();
  }

  // endregion
}
