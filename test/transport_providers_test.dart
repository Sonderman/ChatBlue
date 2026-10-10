import 'dart:async';
import 'dart:typed_data';

import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_bt_service.dart';
import 'support/fake_wd_service.dart';

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
            appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
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
      // Live-view semantics: leaving scan mode empties the nearby list.
      expect(c.read(btTransportProvider).scanResults, isEmpty);
    });

    test('stopScan empties the nearby list (live-view semantics)', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider); // trigger build (wires service callbacks)

      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      expect(c.read(btTransportProvider).scanResults, isNotEmpty);

      await c.read(btTransportProvider.notifier).stopScan();
      final state = c.read(btTransportProvider);
      expect(state.isScanning, isFalse);
      expect(state.scanResults, isEmpty);
    });

    test('scan session re-arms windows and keeps the live list', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(btTransportProvider.notifier);

      await notifier.startScan(); // starts the 1-minute session
      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      expect(c.read(btTransportProvider).scanResults, isNotEmpty);

      // Window end mid-session: the scan stays on, the live list keeps its
      // results, and the next discovery window is re-armed.
      service.onScanFinished?.call();
      expect(c.read(btTransportProvider).isScanning, isTrue);
      expect(c.read(btTransportProvider).scanResults, isNotEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(service.startScanCalls, 2); // initial + one re-arm

      await notifier.stopScan();
      final state = c.read(btTransportProvider);
      expect(state.isScanning, isFalse);
      expect(state.scanResults, isEmpty);
    });

    test('connectToPeer resolves true on socket up; READY frame connects',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final connectFuture = c
          .read(btTransportProvider.notifier)
          .connectToPeer('AA:BB:CC:DD:EE:FF');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      expect(await connectFuture, isTrue);
      // A valid MAC passes the address guard through to the native dial.
      expect(service.connectCalled, isTrue);

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
          .connectToPeer('AA:BB:CC:DD:EE:FF');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
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
      final connectFuture = notifier.connectToPeer('AA:BB:CC:DD:EE:FF');
      // The native layer used to emit a spurious disconnect (cancelling the
      // previous, dead socket) as the new dial started; it completed the
      // attempt as a failure AND wiped the initiation window.
      service.onSocketDisconnected?.call('manual');
      expect(await connectFuture, isFalse);

      // The real socket lands moments later — it is OUR dial's result, so
      // the notifier must wait for acceptance, never show a request banner.
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      expect(notifier.isAwaitingAcceptance, isTrue);
    });

    test(
        'connectToPeer rejects a non-MAC (uuid) stored address without '
        'dialing native', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      // The poisoned session address that produced the native "is not a
      // valid Bluetooth address" IllegalArgumentException: the peer's
      // Nearby-era uid left behind by a cross-transport session merge.
      final ok = await c
          .read(btTransportProvider.notifier)
          .connectToPeer('65eab5b0-4d42-493f-acfa-74c315e46cc6');

      expect(ok, isFalse);
      expect(service.connectCalled, isFalse);
      expect(
        c.read(btTransportProvider).lastConnectError,
        AppLocalizationsEn().invalidBtAddressMessage,
      );
    });

    test(
        'decline while awaiting acceptance records the declined reason',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      final connectFuture = notifier.connectToPeer('AA:BB:CC:DD:EE:FF');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      expect(await connectFuture, isTrue);
      expect(notifier.isAwaitingAcceptance, isTrue);

      // The peer declines: the socket drops while acceptance is pending.
      // The dialer-side notice card is a no-op headless; the STATE must
      // carry the declined reason so the screens/chat can skip their own
      // snackbar instead of stacking on top of the notice.
      service.onSocketDisconnected?.call('remote closed');
      expect(notifier.isAwaitingAcceptance, isFalse);
      expect(
        c.read(btTransportProvider).lastConnectError,
        AppLocalizationsEn().connectionDeclinedMessage,
      );
      expect(c.read(btTransportProvider).isConnected, isFalse);
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
            appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
          ],
        );

    test('startDiscovery is blocked while location is off', () async {
      service.locationEnabled = false;
      final c = container();
      addTearDown(c.dispose);
      // Build the notifier first, THEN pump: `_init`'s state refresh is
      // unawaited from build() and must land before the expectation.
      final notifier = c.read(wdTransportProvider.notifier);
      await pumpEventQueue();

      expect(c.read(wdTransportProvider).isLocationOn, isFalse);

      await notifier.startDiscovery();
      expect(c.read(wdTransportProvider).isScanning, isFalse);
      expect(service.startDiscoveryCalls, 0);
    });

    test('refreshLocationState tracks the system toggle', () async {
      service.locationEnabled = false;
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(wdTransportProvider.notifier);
      await pumpEventQueue();

      expect(c.read(wdTransportProvider).isLocationOn, isFalse);

      service.locationEnabled = true;
      await notifier.refreshLocationState();
      expect(c.read(wdTransportProvider).isLocationOn, isTrue);
    });

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

    test('connectToSessionPeer with location off surfaces the location reason',
        () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.locationEnabled = false;
      service.enableLocationResult = false;

      final ok = await notifier.connectToSessionPeer(
        address: 'AA:BB:CC',
        name: 'Peer',
      );
      expect(ok, isFalse);
      expect(c.read(wdTransportProvider).lastConnectError,
          AppLocalizationsEn().locationOffTitle);
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
        AppLocalizationsEn().wifiOffTitle,
      );
    });

    test('onAppResumed releases a pending enableWifi flow so the button is '
        'not stuck after returning from the system panel', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = false;
      await notifier.onAppResumed(); // sync the radio state
      expect(c.read(wdTransportProvider).isWifiOn, isFalse);

      // The user taps "turn on Wi‑Fi": the flow starts and the button flips
      // to its disabled (in-flight) state while the 15 s poll window opens.
      unawaited(notifier.enableWifi());
      await pumpEventQueue();
      expect(c.read(wdTransportProvider).isWifiEnableInFlight, isTrue);

      // Back from the system panel WITHOUT touching anything: the resume
      // must release the flow immediately — not 15 s later.
      await notifier.onAppResumed();
      final state = c.read(wdTransportProvider);
      expect(state.isWifiEnableInFlight, isFalse);
      expect(state.isWifiOn, isFalse);
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
