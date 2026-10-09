import 'dart:typed_data';

import 'package:chatblue/core/services/wd_service.dart';

/// Minimal in-memory [WifiDirectService] for transport/binding tests.
class FakeWdService extends WifiDirectService {
  bool wifiEnabled = true;
  bool enableWifiResult = true;
  bool locationEnabled = true;
  bool enableLocationResult = true;
  int startDiscoveryCalls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isWifiEnabled() async => wifiEnabled;

  @override
  Future<bool> requestEnableWifi() async => enableWifiResult;

  @override
  Future<bool> isLocationEnabled() async => locationEnabled;

  @override
  Future<bool> requestEnableLocation() async => enableLocationResult;

  @override
  Future<String?> getThisDeviceAddress() async => null;

  @override
  Future<void> startDiscovery({Duration? autoStopAfter}) async {
    startDiscoveryCalls++;
  }

  @override
  Future<void> stopDiscovery() async {}

  @override
  Future<void> requestPeers() async {}

  @override
  Future<List<WdPeerInfo>> getDiscoveredPeers() async => [];

  @override
  Future<void> startServer() async {}

  @override
  Future<void> stopServer() async {}

  @override
  Future<void> connect(String deviceAddress) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> isConnected() async => false;

  @override
  Future<void> sendString(String text) async {}

  @override
  Future<void> sendBytes(Uint8List bytes) async {}

  @override
  Future<void> dispose() async {}
}
