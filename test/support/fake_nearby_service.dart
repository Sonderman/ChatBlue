import 'dart:typed_data';

import 'package:chatblue/core/services/nearby_service.dart';

/// Minimal in-memory [NearbyService] for transport tests: every native
/// call is a no-op and the interesting ones record their arguments.
/// (Shared by the Nearby transport tests and the cross-transport scan
/// exclusion tests.)
class FakeNearbyService extends NearbyService {
  bool playServices = true;
  bool bluetoothEnabled = true;
  bool canAdvertise = true;
  bool locationPermission = true;
  bool locationEnabled = true;
  bool wifiEnabled = true;
  bool enableBluetoothResult = true;

  final List<String> startScanCalls = [];
  final List<String> connectCalls = [];
  final List<String> acceptCalls = [];
  final List<String> rejectCalls = [];
  final List<String> sendMessageCalls = [];
  final List<Uint8List> sendBytesCalls = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<NearbyStatus> getStatus() async => NearbyStatus(
        playServices: playServices,
        bluetoothEnabled: bluetoothEnabled,
        canAdvertise: canAdvertise,
        locationPermission: locationPermission,
        locationEnabled: locationEnabled,
        wifiEnabled: wifiEnabled,
      );

  @override
  Future<String> getDeviceName() async => '';

  int enableBluetoothCalls = 0;

  @override
  Future<bool> requestEnableBluetooth() async {
    enableBluetoothCalls++;
    return enableBluetoothResult;
  }

  int requestPermissionCalls = 0;

  @override
  Future<bool> requestNearbyPermissions() async {
    requestPermissionCalls++;
    return locationPermission;
  }

  int enableLocationCalls = 0;

  @override
  Future<bool> requestEnableLocation() async {
    enableLocationCalls++;
    return true;
  }

  int openAppSettingsCalls = 0;

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }

  @override
  Future<void> startScan({required String name, required String uid}) async {
    startScanCalls.add(uid);
  }

  /// Number of [stopScan] calls — the cross-transport scan exclusion tests
  /// assert that a scan start stops the OTHER transports' scan loops.
  int stopScanCalls = 0;

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
  }

  @override
  Future<void> connect(String endpointId,
      {required String uid, required String name}) async {
    connectCalls.add(endpointId);
  }

  @override
  Future<void> accept(String endpointId) async {
    acceptCalls.add(endpointId);
  }

  @override
  Future<void> reject(String endpointId) async {
    rejectCalls.add(endpointId);
  }

  int disconnectCalls = 0;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<void> cancelConnect() async {}

  @override
  Future<bool> isConnected() async => false;

  @override
  Future<void> sendString(String text) async {
    sendMessageCalls.add(text);
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sendBytesCalls.add(bytes);
  }

  @override
  Future<void> dispose() async {}
}
