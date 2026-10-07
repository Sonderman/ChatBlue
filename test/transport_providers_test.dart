import 'dart:typed_data';

import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Transport notifier contract: service events drive UI state, the READY
/// handshake flips the link to connected (never leaking as a message), and
/// the session-reconnect flow captures the native failure reason.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Bluetooth', () {
    late FakeBtService service;

    setUp(() {
      service = FakeBtService();
    });

    ProviderContainer container() => ProviderContainer(
          overrides: [
            btTransportProvider.overrideWith(
              () => BtTransportNotifier(service: service),
            ),
          ],
        );

    test('scan events populate scanResults', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider); // trigger build (wires service callbacks)

      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      service.onDeviceFound?.call(
        BtDeviceInfo(address: '11:22:33', name: 'PeerTwo'),
      );

      final state = c.read(btTransportProvider);
      expect(state.isScanning, isTrue);
      expect(state.scanResults.map((d) => d.address).toList(),
          ['AA:BB:CC', '11:22:33']);

      service.onScanFinished?.call();
      expect(c.read(btTransportProvider).isScanning, isFalse);
    });

    test('connectToPeer resolves true on socket up; READY frame connects',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final connectFuture = c
          .read(btTransportProvider.notifier)
          .connectToPeer('AA:BB:CC');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      expect(await connectFuture, isTrue);

      // Socket up ≠ connected: only the READY frame binds the session.
      expect(c.read(btTransportProvider).isConnected, isFalse);

      service.onSocketData!(
        Uint8List(0),
        '@@CHATBLUE_CONNECT@@',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(c.read(btTransportProvider).isConnected, isTrue);
      // The handshake frame must never surface as a chat message.
      expect(c.read(btTransportProvider.notifier).isAwaitingAcceptance,
          isFalse);
    });

    test('disconnect of a live link records lastDisconnectReason', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      c.read(btTransportProvider.notifier).onChatOpened();
      final connectFuture = c
          .read(btTransportProvider.notifier)
          .connectToPeer('AA:BB:CC');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      await connectFuture;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      expect(c.read(btTransportProvider).isConnected, isTrue);

      service.onSocketDisconnected?.call('remote closed');
      final state = c.read(btTransportProvider);
      expect(state.isConnected, isFalse);
      expect(state.lastDisconnectReason, 'remote closed');
    });

    test(
        'mid-dial disconnect keeps the initiation window: the late socket '
        'still reads as OUR dial (no self-request banner)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('AA:BB:CC');
      // The native layer used to emit a spurious disconnect (cancelling the
      // previous, dead socket) as the new dial started; it completed the
      // attempt as a failure AND wiped the initiation window.
      service.onSocketDisconnected?.call('manual');
      expect(await connectFuture, isFalse);

      // The real socket lands moments later — it is OUR dial's result, so
      // the notifier must wait for acceptance, never show a request banner.
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      expect(notifier.isAwaitingAcceptance, isTrue);
    });
  });

  group('Wi-Fi Direct', () {
    late FakeWdService service;

    setUp(() {
      service = FakeWdService();
    });

    ProviderContainer container() => ProviderContainer(
          overrides: [
            wdTransportProvider.overrideWith(
              () => WdTransportNotifier(service: service),
            ),
          ],
        );

    test('peer discovery populates the peers list', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = true;
      await notifier.startDiscovery();

      service.onPeerFound?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      expect(c.read(wdTransportProvider).peers.map((p) => p.deviceAddress),
          ['p2p-1']);
    });

    test('connectToSessionPeer with Wi‑Fi off surfaces the wifiOff reason',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = false;
      service.enableWifiResult = false;

      final ok = await notifier.connectToSessionPeer(
        address: 'AA:BB:CC',
        name: 'Peer',
      );
      expect(ok, isFalse);
      expect(
        c.read(wdTransportProvider).lastConnectError,
        'wifiOffTitle',
      );
    });

    test('READY frame connects and clears the peer list (post-session)',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = true;
      service.onPeerFound?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      expect(c.read(wdTransportProvider).peers, hasLength(1));

      final connectFuture = notifier.connectToPeer('p2p-1');
      service.onSocketConnected?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      expect(await connectFuture, isTrue);

      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      final state = c.read(wdTransportProvider);
      expect(state.isConnected, isTrue);
      // The scan list is cleared once a session begins.
      expect(state.peers, isEmpty);
      expect(state.connectedDevice?.deviceAddress, 'p2p-1');
    });

    test(
        'mid-dial disconnect keeps the initiation window: the late socket '
        'still reads as OUR dial (no self-request banner)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = true;
      service.onPeerFound?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      final connectFuture = notifier.connectToPeer('p2p-1');
      service.onSocketDisconnected?.call('manual');
      expect(await connectFuture, isFalse);

      // Our dial's socket lands late: wait for acceptance, no banner.
      service.onSocketConnected?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      expect(notifier.isAwaitingAcceptance, isTrue);
    });
  });
}

class FakeBtService extends BtClassicService {
  @override
  Future<void> initialize({bool requestEnableIfDisabled = true}) async {}

  @override
  Future<Map> requestDiscoverable({int seconds = 120}) async =>
      {'allowed': true, 'durationSec': 0};

  @override
  Future<List<BtDeviceInfo>> getPairedDevices() async => [];

  @override
  Future<void> startScan({Duration? autoStopAfter}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> startServer({String serviceName = 'ChatBlueSPP', String? uuid}) async {}

  @override
  Future<void> stopServer() async {}

  @override
  Future<void> connect(String address, {String? uuid}) async {}

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

class FakeWdService extends WifiDirectService {
  bool wifiEnabled = true;
  bool enableWifiResult = true;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isWifiEnabled() async => wifiEnabled;

  @override
  Future<bool> requestEnableWifi() async => enableWifiResult;

  @override
  Future<String?> getThisDeviceAddress() async => null;

  @override
  Future<void> startDiscovery({Duration? autoStopAfter}) async {}

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