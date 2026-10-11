import 'dart:typed_data';

import 'package:chatblue/core/services/bt_classic_service.dart';

/// Minimal in-memory [BtClassicService] for transport/binding tests: every
/// native call is a no-op and the interesting ones record their arguments.
class FakeBtService extends BtClassicService {
  @override
  Future<void> initialize({bool requestEnableIfDisabled = true}) async {}

  @override
  Future<Map> requestDiscoverable({int seconds = 120}) async =>
      {'allowed': true, 'durationSec': 0};

  @override
  Future<List<BtDeviceInfo>> getPairedDevices() async => [];

  int startScanCalls = 0;

  @override
  Future<void> startScan({Duration? autoStopAfter}) async {
    startScanCalls++;
  }

  /// Number of [stopScan] calls — the cross-transport scan exclusion tests
  /// assert that a scan start stops the OTHER transports' scan loops.
  int stopScanCalls = 0;

  @override
  Future<void> stopScan() async {
    stopScanCalls++;
  }

  @override
  Future<void> startServer(
      {String serviceName = 'ChatBlueSPP', String? uuid}) async {}

  @override
  Future<void> stopServer() async {}

  /// True once the native dial was invoked — lets tests assert that the
  /// address guard did (or did not) reach the service.
  bool connectCalled = false;

  /// Every address passed to [connect], in order — lets tests assert the
  /// session-reconnect sequence (fast stored dial, then the scan match).
  final List<String> connectAddresses = [];

  @override
  Future<void> connect(String address, {String? uuid}) async {
    connectCalled = true;
    connectAddresses.add(address);
  }

  /// Number of [disconnect] calls — lets tests assert teardown paths.
  int disconnectCalls = 0;

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  Future<bool> isConnected() async => false;

  /// Value returned by [getLiveRssi]; null simulates a platform without a
  /// live read.
  int? liveRssi;

  @override
  Future<int?> getLiveRssi(String address) async => liveRssi;

  /// Recorded [sendString] payloads — lets tests assert the wire order.
  final List<String> sendStringCalls = [];

  @override
  Future<void> sendString(String text) async {
    sendStringCalls.add(text);
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {}

  @override
  Future<void> dispose() async {}
}
