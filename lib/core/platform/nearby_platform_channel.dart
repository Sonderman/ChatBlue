import 'dart:async';
import 'package:flutter/services.dart';

/// Platform channel wrapper for Google Nearby Connections (Android).
/// Mirrors [WdPlatformChannel]: advertising/discovery lifecycle, connection
/// request/accept/reject, and framed byte-stream I/O — exposed as method
/// calls and event streams.
class NearbyPlatformChannel {
  NearbyPlatformChannel._();
  static final NearbyPlatformChannel instance = NearbyPlatformChannel._();

  // Channel names must match the native side (MainActivity/NearbyManager).
  static const MethodChannel _method = MethodChannel('com.sondermium.chatblue/nearby');
  static const EventChannel _scanEvents = EventChannel('com.sondermium.chatblue/nearby_scan');
  static const EventChannel _socketEvents = EventChannel('com.sondermium.chatblue/nearby_socket');

  Stream<dynamic>? _scanStream;
  Stream<dynamic>? _socketStream;

  // region Permissions / Status
  Future<Map> requestNearbyPermissions() async {
    final Map result = await _method.invokeMethod('requestNearbyPermissions');
    return result;
  }

  Future<Map> getNearbyStatus() async {
    final Map result = await _method.invokeMethod('getNearbyStatus');
    return result;
  }

  /// The user-visible device name (Settings/Bluetooth name on the native
  /// side) used as this device's identity when advertising/connecting.
  Future<String> getDeviceName() async {
    final String? name = await _method.invokeMethod('getDeviceName');
    return name ?? '';
  }

  Future<bool> requestEnableBluetooth() async {
    final bool ok = await _method.invokeMethod('requestEnableBluetooth');
    return ok;
  }
  // endregion

  // region Discovery / Advertising
  Future<bool> startScan({required String uid, required String name}) async {
    final bool ok =
        await _method.invokeMethod('startScan', {'uid': uid, 'name': name});
    return ok;
  }

  Future<bool> stopScan() async {
    final bool ok = await _method.invokeMethod('stopScan');
    return ok;
  }

  /// Scan events yield maps like:
  /// - { 'event': 'started' }
  /// - { 'event': 'endpoint', 'data': {endpointId, endpointName, uid} }
  /// - { 'event': 'endpointLost', 'data': {endpointId} }
  /// - { 'event': 'finished' }
  Stream<dynamic> scanEvents() {
    return _scanStream ??= _scanEvents.receiveBroadcastStream().asBroadcastStream();
  }
  // endregion

  // region Connection lifecycle
  Future<bool> connect(String endpointId, {required String uid, required String name}) async {
    final bool ok = await _method.invokeMethod(
      'connect',
      {'endpointId': endpointId, 'uid': uid, 'name': name},
    );
    return ok;
  }

  Future<bool> accept(String endpointId) async {
    final bool ok = await _method.invokeMethod('accept', {'endpointId': endpointId});
    return ok;
  }

  Future<bool> reject(String endpointId) async {
    final bool ok = await _method.invokeMethod('reject', {'endpointId': endpointId});
    return ok;
  }

  Future<bool> disconnect() async {
    final bool ok = await _method.invokeMethod('disconnect');
    return ok;
  }

  /// Aborts a pending outgoing request (UI "İptal" on the connecting panel).
  Future<bool> cancelConnect() async {
    final bool ok = await _method.invokeMethod('cancelConnect');
    return ok;
  }

  Future<bool> isConnected() async {
    final bool ok = await _method.invokeMethod('isConnected');
    return ok;
  }
  // endregion

  // region I/O
  Future<bool> sendString(String text) async {
    final bool ok = await _method.invokeMethod('sendString', {'text': text});
    return ok;
  }

  Future<bool> sendBytes(Uint8List bytes) async {
    final bool ok = await _method.invokeMethod('sendBytes', {'bytes': bytes});
    return ok;
  }

  /// Socket events yield:
  /// - { 'event': 'initiated', 'data': {endpointId, endpointName, uid, incoming, authDigits} }
  /// - { 'event': 'connected', 'data': {endpointId, endpointName, uid} }
  /// - { 'event': 'rejected', 'data': {endpointId} }
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
