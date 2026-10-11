import 'dart:async';
import 'dart:typed_data';

import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/core/services/wd_service.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/settings_repository.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_bt_service.dart';
import 'support/fake_nearby_service.dart';
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

    ProviderContainer container({
      Duration? sessionScanWindow,
      Duration? sessionScanPoll,
    }) =>
        ProviderContainer(
          overrides: [
            btTransportProvider.overrideWith(
              () => BtTransportNotifier(
                service: service,
                sessionScanWindow: sessionScanWindow,
                sessionScanPoll: sessionScanPoll,
              ),
            ),
            // Sibling transports exist so the cross-transport scan exclusion
            // has something to read (idle fakes → the stop paths no-op);
            // without them the exclusion would construct the REAL
            // platform-channel-backed notifiers inside tests.
            wdTransportProvider.overrideWith(
              () => WdTransportNotifier(service: FakeWdService()),
            ),
            nearbyTransportProvider.overrideWith(
              () => NearbyTransportNotifier(service: FakeNearbyService()),
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

    test('scan results skip devices that never broadcast a name', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider);
      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC', name: 'PeerOne'),
      );
      service.onDeviceFound?.call(BtDeviceInfo(address: '11:22:33'));
      service.onDeviceFound?.call(
        BtDeviceInfo(address: '22:33:44', name: '   '),
      );
      expect(
        c.read(btTransportProvider).scanResults.map((d) => d.address).toList(),
        ['AA:BB:CC'],
        reason: 'nameless neighbors (audio gear / TVs that never broadcast '
            'a name) are noise on the device picker',
      );
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

    test(
        'self-cancel while awaiting acceptance stays silent — the disconnect '
        'it triggers must not read as a peer decline', () async {
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

      // The DIALER cancels its own pending request: the native disconnect
      // that follows emits the usual 'manual' event — OUR teardown, not the
      // peer's answer.
      await notifier.cancelPendingConnect();
      expect(service.disconnectCalls, 1);
      service.onSocketDisconnected?.call('manual');
      await pumpEventQueue();

      expect(notifier.isAwaitingAcceptance, isFalse);
      expect(c.read(btTransportProvider).lastConnectError, isNull,
          reason: 'the self-cancel masqueraded as a peer decline — the '
              'cancelling device would show the "peer declined" notice');
    });

    test(
        'a dropped link clears the bound device: the next dial binds ITS '
        'peer, never the previous one (device-reported: Redmi→J7 opened the '
        'POCO chat)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      // First connection: Peer A (the POCO).
      final connectA = notifier.connectToPeer('AA:AA:AA:AA:AA:AA');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:AA:AA:AA:AA:AA', name: 'PeerA'),
      );
      await connectA;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      expect(c.read(btTransportProvider).connectedDevice?.address,
          'AA:AA:AA:AA:AA:AA');

      // Peer A drops: the binding must not survive its link — a stale
      // binding would let the NEXT READY reopen A's session.
      service.onSocketDisconnected?.call('remote closed');
      expect(c.read(btTransportProvider).connectedDevice, isNull,
          reason: 'the dead link left its device bound');

      // Second dial: Peer B (the J7). Its READY must bind B, not A.
      final connectB = notifier.connectToPeer('BB:BB:BB:BB:BB:BB');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'BB:BB:BB:BB:BB:BB', name: 'PeerB'),
      );
      await connectB;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      final state = c.read(btTransportProvider);
      expect(state.isConnected, isTrue);
      expect(state.connectedDevice?.address, 'BB:BB:BB:BB:BB:BB');
      expect(state.connectedDevice?.name, 'PeerB',
          reason: 'the previous peer leaked into this binding — its chat '
              'would open with the wrong session and sync the wrong history');
    });

    test(
        'a READY arriving after a silent socket replacement binds the fresh '
        'peer (no disconnect event needed)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      // Bind Peer A.
      final connectA = notifier.connectToPeer('AA:AA:AA:AA:AA:AA');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:AA:AA:AA:AA:AA', name: 'PeerA'),
      );
      await connectA;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      expect(c.read(btTransportProvider).connectedDevice?.address,
          'AA:AA:AA:AA:AA:AA');

      // The native layer replaces the socket with Peer B WITHOUT a
      // disconnect event (single-socket replacement). The next dial's
      // READY must prefer the CURRENT socket's remote over the leftover
      // binding — the old `?? _pendingRemote` order kept A and reopened
      // A's session (the defensive half of the device-reported bug).
      final connectB = notifier.connectToPeer('BB:BB:BB:BB:BB:BB');
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'BB:BB:BB:BB:BB:BB', name: 'PeerB'),
      );
      await connectB;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      final state = c.read(btTransportProvider);
      expect(state.isConnected, isTrue);
      expect(state.connectedDevice?.address, 'BB:BB:BB:BB:BB:BB');
      expect(state.connectedDevice?.name, 'PeerB');
    });

    test(
        'a fresh dial drops the previous failure reason (stale reason never '
        'masquerades as this dial result)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();
      final notifier = c.read(btTransportProvider.notifier);

      // A previous attempt left a failure reason behind (invalid stored
      // address — the poisoned-uid class).
      expect(
        await notifier.connectToPeer('65eab5b0-4d42-493f-acfa-74c315e46cc6'),
        isFalse,
      );
      expect(
        c.read(btTransportProvider).lastConnectError,
        AppLocalizationsEn().invalidBtAddressMessage,
      );

      // The next dial must WIPE it up front: a stale reason would otherwise
      // leak into this attempt (the WFD session search bails early on a
      // non-null reason, and the screens' declined-equality guards can
      // suppress the next failure's notice when the stale text is the
      // declined message).
      final connectFuture = notifier.connectToPeer('AA:BB:CC:DD:EE:FF');
      expect(c.read(btTransportProvider).lastConnectError, isNull);
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      expect(await connectFuture, isTrue);
    });

    test('a dial keeps its scan RSSI for the quality panel until the link '
        'drops', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();
      final notifier = c.read(btTransportProvider.notifier);

      // Panel data needs the LINK up (READY), not just the socket.
      final connectFuture = notifier.connectToPeer(
        'AA:BB:CC:DD:EE:FF',
        rssi: -58,
      );
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      await connectFuture;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();

      expect(c.read(btTransportProvider).isConnected, isTrue);
      expect(notifier.connectedDeviceRssi, -58,
          reason: 'the dial-time scan RSSI feeds the chat quality panel '
              '(Bluetooth Classic has no live link RSSI API)');

      service.onSocketDisconnected?.call('remote');
      await pumpEventQueue();
      expect(notifier.connectedDeviceRssi, isNull);
    });

    test(
        'a scanned reading is reused by a later dial without scan context '
        '(chat reconnect) and persisted for later runs', () async {
      final db = AppDatabase(NativeDatabase.memory());
      SettingsRepository.instance = SettingsRepository(db);
      await SettingsRepository.instance!.load();
      addTearDown(() async {
        SettingsRepository.instance = null;
        await db.close();
      });

      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();
      final notifier = c.read(btTransportProvider.notifier);

      // A scan session saw the peer — the dialer's only reading source
      // (Bluetooth Classic exposes no live link RSSI).
      await notifier.startScan();
      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne', rssi: -61),
      );
      await notifier.stopScan();
      await pumpEventQueue();
      expect(
        SettingsRepository.instance!.getString('btRssi:AA:BB:CC:DD:EE:FF'),
        startsWith('-61|'),
        reason: 'a scan reading must survive the run (chat reconnects and '
            'restarts have no scan context of their own)',
      );

      // The chat's Connect button / transport picker dials the stored MAC
      // with no scan context: the last reading must ride along.
      final connectFuture = notifier.connectToSessionPeer(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'PeerOne',
      );
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      await connectFuture;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();

      expect(notifier.connectedDeviceRssi, -61,
          reason: 'without this the BT panel shows NO signal at all on a '
              'chat reconnect (device-reported)');
    });

    test('a dial-time reading persists and serves a fresh session reconnect',
        () async {
      final db = AppDatabase(NativeDatabase.memory());
      SettingsRepository.instance = SettingsRepository(db);
      await SettingsRepository.instance!.load();
      addTearDown(() async {
        SettingsRepository.instance = null;
        await db.close();
      });

      final c1 = container();
      addTearDown(c1.dispose);
      await pumpEventQueue();
      final n1 = c1.read(btTransportProvider.notifier);
      final dial = n1.connectToPeer('AA:BB:CC:DD:EE:FF', rssi: -67);
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      await dial;
      await pumpEventQueue();
      expect(
        SettingsRepository.instance!.getString('btRssi:AA:BB:CC:DD:EE:FF'),
        startsWith('-67|'),
      );

      // Fresh container + service = a later app run (restart): the chat's
      // reconnect has no scan context anywhere — the persisted reading is
      // the only source that exists.
      final service2 = FakeBtService();
      final c2 = ProviderContainer(
        overrides: [
          btTransportProvider.overrideWith(
            () => BtTransportNotifier(service: service2),
          ),
          // Siblings for the cross-transport scan exclusion (see the group's
          // container note).
          wdTransportProvider.overrideWith(
            () => WdTransportNotifier(service: FakeWdService()),
          ),
          nearbyTransportProvider.overrideWith(
            () => NearbyTransportNotifier(service: FakeNearbyService()),
          ),
          appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
        ],
      );
      addTearDown(c2.dispose);
      await pumpEventQueue();
      final n2 = c2.read(btTransportProvider.notifier);
      final dial2 = n2.connectToSessionPeer(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'PeerOne',
      );
      service2.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      await dial2;
      service2.onSocketData!(
        Uint8List(0),
        '@@CHATBLUE_CONNECT@@',
        kind: 'text',
      );
      await pumpEventQueue();
      expect(n2.connectedDeviceRssi, -67,
          reason: 'the last known scan reading must survive a restart');
    });

    test('getLiveRssi polls the native reading while connected', () async {
      final c = container();
      addTearDown(c.dispose);
      final notifier = c.read(btTransportProvider.notifier);
      expect(await notifier.getLiveRssi(), isNull,
          reason: 'no connected device yet');

      final connectFuture = notifier.connectToPeer(
        'AA:BB:CC:DD:EE:FF',
        rssi: -58,
      );
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      await connectFuture;
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();

      service.liveRssi = -54;
      expect(await notifier.getLiveRssi(), -54,
          reason: 'the quality panel polls the platform live value');

      service.liveRssi = null; // platform without a live read
      expect(await notifier.getLiveRssi(), isNull);
    });

    test(
        'session reconnect heals a dead stored address via the scan match '
        '(the per-transport map\'s bootstrap)', () async {
      final c = container(
        sessionScanWindow: const Duration(seconds: 3),
        sessionScanPoll: const Duration(milliseconds: 50),
      );
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      // The stored value is a Wi‑Fi Direct p2p MAC (learned over the other
      // transport): it has a MAC's shape but native rejects it — the fast
      // dial dies instantly and the flow falls back to a scan + match.
      final future = notifier.connectToSessionPeer(
        address: '36:8a:7b:b4:5b:9e',
        name: 'Galaxy J7 Prime',
      );
      await pumpEventQueue();
      expect(service.connectAddresses, ['36:8a:7b:b4:5b:9e']);
      service.onSocketError?.call(
        'Invalid Bluetooth address: 36:8a:7b:b4:5b:9e',
      );
      await pumpEventQueue();

      // The fallback scan runs; the peer surfaces with its REAL MAC.
      service.onScanStarted?.call();
      service.onDeviceFound?.call(
        BtDeviceInfo(address: '34:8A:7B:B4:5B:9D', name: 'Galaxy J7 Prime'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(service.connectAddresses,
          ['36:8a:7b:b4:5b:9e', '34:8A:7B:B4:5B:9D'],
          reason: 'the scan match must dial the LIVE address, not the '
              'rejected stored one');

      service.onSocketConnected?.call(
        BtDeviceInfo(address: '34:8A:7B:B4:5B:9D', name: 'Galaxy J7 Prime'),
      );
      expect(await future, isTrue);
    });

    test('session reconnect scans by name when no stored address is known',
        () async {
      final c = container(
        sessionScanWindow: const Duration(seconds: 3),
        sessionScanPoll: const Duration(milliseconds: 50),
      );
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      final future = notifier.connectToSessionPeer(
        address: null,
        name: 'Galaxy J7 Prime',
      );
      await pumpEventQueue();
      expect(service.connectAddresses, isEmpty,
          reason: 'nothing dialable was known — no blind dial');

      service.onScanStarted?.call();
      // Noise first: only the normalized name match may win.
      service.onDeviceFound?.call(
        BtDeviceInfo(address: '11:11:11:11:11:11', name: 'TV'),
      );
      service.onDeviceFound?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'galaxy j7 prime'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(service.connectAddresses, ['AA:BB:CC:DD:EE:FF']);

      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'galaxy j7 prime'),
      );
      expect(await future, isTrue);
    });

    test('the session scan is bounded: no match reports the generic failure',
        () async {
      final c = container(
        sessionScanWindow: const Duration(milliseconds: 350),
        sessionScanPoll: const Duration(milliseconds: 50),
      );
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(btTransportProvider.notifier);
      final ok = await notifier.connectToSessionPeer(
        address: null,
        name: 'Ghost',
      );
      expect(ok, isFalse);
      expect(
        c.read(btTransportProvider).lastConnectError,
        AppLocalizationsEn().couldNotConnectMessage,
      );
      expect(c.read(btTransportProvider).isScanning, isFalse,
          reason: 'the fallback scan must stop itself');
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
            // Siblings for the cross-transport scan exclusion (see the
            // Bluetooth group's container note).
            btTransportProvider.overrideWith(
              () => BtTransportNotifier(service: FakeBtService()),
            ),
            nearbyTransportProvider.overrideWith(
              () => NearbyTransportNotifier(service: FakeNearbyService()),
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

    test(
        'self-cancel while awaiting acceptance stays silent — the disconnect '
        'it triggers must not read as a peer decline', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = true;
      final connectFuture = notifier.connectToPeer('p2p-1');
      service.onSocketConnected?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'Redmi'),
      );
      expect(await connectFuture, isTrue);
      expect(notifier.isAwaitingAcceptance, isTrue);

      // The DIALER cancels its own pending request: the native disconnect
      // that follows emits the usual 'manual' event — OUR teardown, not the
      // peer's answer.
      await notifier.cancelPendingConnect();
      expect(service.disconnectCalls, 1);
      service.onSocketDisconnected?.call('manual');
      await pumpEventQueue();

      expect(notifier.isAwaitingAcceptance, isFalse);
      expect(c.read(wdTransportProvider).lastConnectError, isNull,
          reason: 'the self-cancel masqueraded as a peer decline — the '
              'cancelling device would show the "peer declined" notice');
    });

    test(
        'a dropped link clears the bound peer: the next dial binds ITS peer '
        '(the previous name must not leak into the binding)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();

      final notifier = c.read(wdTransportProvider.notifier);
      service.wifiEnabled = true;

      // First connection: Peer A.
      final connectA = notifier.connectToPeer('p2p-1');
      service.onSocketConnected?.call(
        WdPeerInfo(deviceAddress: 'p2p-1', deviceName: 'PeerA'),
      );
      expect(await connectA, isTrue);
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      expect(c.read(wdTransportProvider).connectedDevice?.deviceName, 'PeerA');

      // Peer A drops: the binding must not survive its link.
      service.onSocketDisconnected?.call('remote closed');
      expect(c.read(wdTransportProvider).connectedDevice, isNull,
          reason: 'the dead link left its peer bound');

      // Second dial: its READY must bind the NEW peer.
      final connectB = notifier.connectToPeer('p2p-2');
      service.onSocketConnected?.call(
        WdPeerInfo(deviceAddress: 'p2p-2', deviceName: 'PeerB'),
      );
      expect(await connectB, isTrue);
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
      final state = c.read(wdTransportProvider);
      expect(state.isConnected, isTrue);
      expect(state.connectedDevice?.deviceName, 'PeerB',
          reason: 'the previous peer name leaked into this binding — the '
              'session-merge fallback could reopen the wrong chat');
    });

    test(
        'READY keeps the identity uid the peer frame bound before the '
        'handshake (the socket map carries none)', () async {
      final c = container();
      addTearDown(c.dispose);
      await pumpEventQueue();
      final notifier = c.read(wdTransportProvider.notifier);

      final connectFuture = notifier.connectToPeer('p2p-1');
      // The socket map carries no identity (client side: no name/address).
      service.onSocketConnected?.call(WdPeerInfo(deviceAddress: 'p2p-1'));
      expect(await connectFuture, isTrue);

      // The peer's identity frame lands before the user accepts (READY):
      // uid + self-reported P2P MAC + display name.
      service.onSocketData!(
        Uint8List(0),
        '@@CHATBLUE_ID@@uid-1|be:57:7a:fe:d5:a0|Peer One',
        kind: 'text',
      );

      // READY must bind the CURRENT socket without dropping the uid: the
      // chat session keys on it — without it the session keys on the
      // rotating P2P MAC and the two devices can end up on different rows
      // for one peer (device-reported: BT-era chat on one side, WFD-era
      // chat on the other after a BT → Wi‑Fi Direct connect).
      service.onSocketData!(
        Uint8List(0),
        '@@CHATBLUE_CONNECT@@',
        kind: 'text',
      );
      await pumpEventQueue();

      final state = c.read(wdTransportProvider);
      expect(state.isConnected, isTrue);
      expect(state.connectedDevice?.peerId, 'uid-1',
          reason: 'the READY branch dropped the identity uid — the session '
              'would key on the rotating P2P MAC instead of the stable id');
      expect(state.connectedDevice?.deviceName, 'Peer One',
          reason: 'the identity name was dropped by the nameless socket map');
      expect(state.connectedDevice?.deviceAddress, 'p2p-1',
          reason: 'the dialed address must win over the socket map');
    });
  });
}
