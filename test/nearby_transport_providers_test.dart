import 'dart:typed_data';

import 'package:chatblue/core/services/nearby_service.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Nearby transport notifier contract: service events drive UI state, our
/// own dial never surfaces as an incoming request banner, preconditions gate
/// the native calls, and the session-reconnect flow matches by uid then name.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Nearby', () {
    late FakeNearbyService service;

    setUp(() {
      service = FakeNearbyService();
      // Shrink the timers for tests (restored in tearDown).
      NearbyTransportNotifier.connectTimeout = const Duration(milliseconds: 100);
      NearbyTransportNotifier.sessionSearchTimeout = const Duration(milliseconds: 300);
      NearbyTransportNotifier.sessionSearchPollInterval = const Duration(milliseconds: 10);
    });

    tearDown(() {
      NearbyTransportNotifier.connectTimeout = const Duration(seconds: 10);
      NearbyTransportNotifier.sessionSearchTimeout = const Duration(seconds: 20);
      NearbyTransportNotifier.sessionSearchPollInterval = const Duration(milliseconds: 900);
    });

    ProviderContainer container() => ProviderContainer(
          overrides: [
            nearbyTransportProvider.overrideWith(
              () => NearbyTransportNotifier(service: service),
            ),
          ],
        );

    test('scan events populate the peers list; finished clears scanning', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      await notifier.startScan();
      expect(c.read(nearbyTransportProvider).isScanning, isTrue);

      service.onPeerFound?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      service.onPeerFound?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      service.onPeerFound?.call(
        NearbyPeerInfo(endpointId: 'ep-2', endpointName: 'POCO', uid: 'uid-2'),
      );
      expect(
        c.read(nearbyTransportProvider).peers.map((p) => p.endpointId).toList(),
        ['ep-1', 'ep-2'],
      );

      service.onEndpointLost?.call('ep-1');
      expect(
        c.read(nearbyTransportProvider).peers.map((p) => p.endpointId).toList(),
        ['ep-2'],
      );

      service.onScanFinished?.call();
      expect(c.read(nearbyTransportProvider).isScanning, isFalse);
    });

    test('preconditions: missing Play Services / Bluetooth never reaches native',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);

      service.playServices = false;
      await notifier.startScan();
      final state1 = c.read(nearbyTransportProvider);
      expect(state1.isScanning, isFalse);
      expect(state1.lastConnectError, 'playServicesRequired');
      expect(service.startScanCalls, isEmpty);

      service.playServices = true;
      service.bluetoothEnabled = false;
      await notifier.startScan();
      final state2 = c.read(nearbyTransportProvider);
      expect(state2.isScanning, isFalse);
      expect(state2.isBluetoothOn, isFalse);
      expect(service.startScanCalls, isEmpty);
    });

    test('capability: a device without BLE advertising surfaces '
        'canAdvertise=false through refreshStatus', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      service.canAdvertise = false;
      await notifier.refreshStatus();
      expect(c.read(nearbyTransportProvider).canAdvertise, isFalse);

      service.canAdvertise = true;
      await notifier.refreshStatus();
      expect(c.read(nearbyTransportProvider).canAdvertise, isTrue);
    });

    test('cancelPendingConnect: the wait resolves as cancelled and a late '
        'accept is disconnected instead of opening a chat', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final pending = notifier.connectToPeer('ep-7');
      await pumpEventQueue();
      expect(service.connectCalls, ['ep-7']);

      await notifier.cancelPendingConnect();
      expect(await pending, isFalse);
      expect(c.read(nearbyTransportProvider).isConnected, isFalse);

      // A late accept from the cancelled dial must not land a link.
      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-7', endpointName: 'Late'),
      );
      await pumpEventQueue();
      expect(service.disconnectCalls, greaterThanOrEqualTo(1));
      expect(c.read(nearbyTransportProvider).isConnected, isFalse);
    });

    test('outgoing connect: initiated(incoming=false) never shows a banner; '
        'connected resolves and keys the session on the uid', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('ep-1');
      await pumpEventQueue();

      service.onConnectionInitiated?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
        incoming: false,
        authDigits: '1234',
      );
      // A self-request must NOT surface as an incoming banner — headless,
      // a wrongly shown banner would immediately auto-decline and reject.
      expect(service.rejectCalls, isEmpty);

      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      expect(await connectFuture, isTrue);

      final state = c.read(nearbyTransportProvider);
      expect(state.isConnected, isTrue);
      expect(state.peers, isEmpty);
      expect(state.isScanning, isFalse);
      expect(notifier.connectedDeviceId, 'uid-1');
      expect(notifier.connectedDeviceKey, 'uid-1');
      expect(notifier.connectedDeviceName, 'Redmi');
      expect(notifier.transportType, 'nearby');
    });

    test('rejected resolves the dial false with the declined message', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('ep-1');
      await pumpEventQueue();

      service.onConnectionRejected?.call('ep-1');
      expect(await connectFuture, isFalse);
      expect(notifier.isAwaitingAcceptance, isFalse);
    });

    test('timeout while awaiting acceptance keeps the window; a late connect '
        'still lands', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('ep-1');
      await pumpEventQueue();

      // Both windows elapse with nothing happening (100ms each in tests).
      expect(await connectFuture, isFalse);
      expect(notifier.isAwaitingAcceptance, isTrue);

      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      expect(c.read(nearbyTransportProvider).isConnected, isTrue);
      expect(notifier.isAwaitingAcceptance, isFalse);
    });

    test('disconnect of a live link records lastDisconnectReason', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('ep-1');
      await pumpEventQueue();
      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      await connectFuture;
      expect(c.read(nearbyTransportProvider).isConnected, isTrue);

      service.onSocketDisconnected?.call('peer left');
      final state = c.read(nearbyTransportProvider);
      expect(state.isConnected, isFalse);
      expect(state.lastDisconnectReason, 'peer left');
    });

    test('disconnect while never connected does not record a reason', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      c.read(nearbyTransportProvider.notifier); // wire callbacks
      service.onSocketDisconnected?.call('disconnected');
      expect(c.read(nearbyTransportProvider).lastDisconnectReason, isNull);
    });

    test('connectToSessionPeer matches by uid first (then dials the endpoint)',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      final f = notifier.connectToSessionPeer(address: 'uid-2', name: 'POCO');
      await pumpEventQueue();

      service.onPeerFound?.call(
        NearbyPeerInfo(endpointId: 'ep-2', endpointName: 'POCO X7', uid: 'uid-2'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.connectCalls, contains('ep-2'));

      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-2', endpointName: 'POCO X7', uid: 'uid-2'),
      );
      expect(await f, isTrue);
    });

    test('connectToSessionPeer with no candidates reports noDevicesFound',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final ok = await c
          .read(nearbyTransportProvider.notifier)
          .connectToSessionPeer(address: 'uid-missing', name: 'Nobody');
      expect(ok, isFalse);
      expect(
        c.read(nearbyTransportProvider).lastConnectError,
        'nearbyNoDevicesFound',
      );
    });

    test('connectToSessionPeer with candidates but no match settles into the '
        'picker; a headless picker reports targetNotFound', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final f = c
          .read(nearbyTransportProvider.notifier)
          .connectToSessionPeer(address: 'uid-x', name: 'UnknownFace');
      await pumpEventQueue();
      service.onPeerFound?.call(
        NearbyPeerInfo(endpointId: 'ep-9', endpointName: 'Someone', uid: 'uid-9'),
      );

      final ok = await f;
      expect(ok, isFalse);
      expect(
        c.read(nearbyTransportProvider).lastConnectError,
        'nearbyTargetNotFound',
      );
    });

    test('empty uid normalizes to null (base layer falls back to a uuid key)',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi'),
      );
      await pumpEventQueue();

      expect(c.read(nearbyTransportProvider).isConnected, isTrue);
      expect(notifier.connectedDeviceId, isNull);
      expect(notifier.connectedDeviceKey, isNull);

      // fromMap normalization as well.
      expect(NearbyPeerInfo.fromMap({'endpointId': 'x', 'uid': ''}).uid, isNull);
      expect(
        NearbyPeerInfo.fromMap({'endpointId': 'x', 'uid': 'u1'}).uid,
        'u1',
      );
    });

    test('sends only while connected', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(nearbyTransportProvider.notifier);
      await notifier.sendMessage('hi');
      await notifier.sendBytes(Uint8List.fromList([1, 2, 3]));
      expect(service.sendMessageCalls, isEmpty);
      expect(service.sendBytesCalls, isEmpty);

      final connectFuture = notifier.connectToPeer('ep-1');
      await pumpEventQueue();
      service.onSocketConnected?.call(
        NearbyPeerInfo(endpointId: 'ep-1', endpointName: 'Redmi', uid: 'uid-1'),
      );
      await connectFuture;

      await notifier.sendMessage('hi');
      await notifier.sendBytes(Uint8List.fromList([1, 2, 3]));
      expect(service.sendMessageCalls, ['hi']);
      expect(service.sendBytesCalls, hasLength(1));
    });
  });
}

class FakeNearbyService extends NearbyService {
  bool playServices = true;
  bool bluetoothEnabled = true;
  bool canAdvertise = true;
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
      );

  @override
  Future<String> getDeviceName() async => '';

  @override
  Future<bool> requestEnableBluetooth() async => enableBluetoothResult;

  @override
  Future<void> startScan({required String name, required String uid}) async {
    startScanCalls.add(uid);
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String endpointId, {required String uid, required String name}) async {
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
