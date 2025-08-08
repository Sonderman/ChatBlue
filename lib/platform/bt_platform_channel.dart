import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Platform channel wrapper for Android Bluetooth Classic operations.
/// This provides discovery (scan), discoverable mode request, paired devices,
/// server/client RFCOMM connection, and data transfer for String/Uint8List.
class BtPlatformChannel {
  BtPlatformChannel._();
  static final BtPlatformChannel instance = BtPlatformChannel._();

  // Channels must match native side channel names
  static const MethodChannel _method = MethodChannel('com.sondermium.chatblue/bt');
  static const EventChannel _scanEvents = EventChannel('com.sondermium.chatblue/scan');
  static const EventChannel _socketEvents = EventChannel('com.sondermium.chatblue/socket');

  Stream<dynamic>? _scanStream;
  Stream<dynamic>? _socketStream;

  // region Generic / Permissions
  Future<bool> isBluetoothAvailable() async {
    final bool available = await _method.invokeMethod('isBluetoothAvailable');
    return available;
  }

  Future<bool> isBluetoothEnabled() async {
    final bool enabled = await _method.invokeMethod('isBluetoothEnabled');
    return enabled;
  }

  Future<bool> requestEnableBluetooth() async {
    final bool allowed = await _method.invokeMethod('requestEnableBluetooth');
    return allowed;
  }

  Future<Map> requestBluetoothPermissions() async {
    final Map result = await _method.invokeMethod('requestBluetoothPermissions');
    return result;
  }

  Future<Map> requestDiscoverable({int seconds = 120}) async {
    final Map result = await _method.invokeMethod('requestDiscoverable', {'seconds': seconds});
    return result;
  }
  // endregion

  // region Scan / Discovery
  Future<bool> startScan() async {
    final bool ok = await _method.invokeMethod('startScan');
    return ok;
  }

  Future<bool> stopScan() async {
    final bool ok = await _method.invokeMethod('stopScan');
    return ok;
  }

  /// Returns the last discovered devices set (address de-duplicated)
  Future<List<Map>> getDiscoveredDevices() async {
    final List list = await _method.invokeMethod('getDiscoveredDevices');
    return list.cast<Map>();
  }

  Future<bool> clearDiscoveredDevices() async {
    final bool ok = await _method.invokeMethod('clearDiscoveredDevices');
    return ok;
  }

  /// Paired devices from the system (bonded)
  Future<List<Map>> getPairedDevices() async {
    final List list = await _method.invokeMethod('getPairedDevices');
    return list.cast<Map>();
  }

  /// Scan event stream with event maps:
  /// { 'event': 'started' | 'device' | 'finished', 'data'?: {name, address, rssi,...}}
  Stream<dynamic> scanEvents() {
    return _scanStream ??= _scanEvents.receiveBroadcastStream().asBroadcastStream();
  }
  // endregion

  // region RFCOMM socket
  Future<bool> startServer({String serviceName = 'ChatBlueSPP', String? uuid}) async {
    final bool ok = await _method.invokeMethod('startServer', {
      'serviceName': serviceName,
      'uuid': uuid,
    });
    return ok;
  }

  Future<bool> stopServer() async {
    final bool ok = await _method.invokeMethod('stopServer');
    return ok;
  }

  Future<bool> connect(String address, {String? uuid}) async {
    final bool ok = await _method.invokeMethod('connect', {'address': address, 'uuid': uuid});
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

  Future<bool> sendString(String text) async {
    final bool ok = await _method.invokeMethod('sendString', {'text': text});
    return ok;
  }

  Future<bool> sendBytes(Uint8List bytes) async {
    final bool ok = await _method.invokeMethod('sendBytes', {'bytes': bytes});
    return ok;
  }

  /// Socket event stream with events:
  /// - { 'event': 'connected', 'remote': { name, address, ... } }
  /// - { 'event': 'disconnected', 'reason': String }
  /// - { 'event': 'data', 'bytes': Uint8List, 'string': String }
  Stream<dynamic> socketEvents() {
    return _socketStream ??= _socketEvents.receiveBroadcastStream().map((dynamic event) {
      if (event is Map && event['event'] == 'data') {
        // Ensure bytes is Uint8List for convenience
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
