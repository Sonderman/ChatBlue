import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/nearby_transport_providers.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_bt_service.dart';
import 'support/fake_nearby_service.dart';
import 'support/fake_wd_service.dart';

/// Cross-transport scan exclusion: a scan start on ANY transport stops the
/// other transports' discovery/scan loops (one radio scanning at a time —
/// battery + interference), while idle transports are never touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeBtService bt;
  late FakeWdService wd;
  late FakeNearbyService nearby;

  ProviderContainer container() {
    bt = FakeBtService();
    wd = FakeWdService();
    nearby = FakeNearbyService();
    return ProviderContainer(
      overrides: [
        btTransportProvider.overrideWith(
          () => BtTransportNotifier(service: bt),
        ),
        wdTransportProvider.overrideWith(
          () => WdTransportNotifier(service: wd),
        ),
        nearbyTransportProvider.overrideWith(
          () => NearbyTransportNotifier(service: nearby),
        ),
        appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
      ],
    );
  }

  test('a Bluetooth scan stops an active Wi-Fi Direct discovery', () async {
    final c = container();
    addTearDown(c.dispose);
    await pumpEventQueue();

    await c.read(wdTransportProvider.notifier).startDiscovery();
    expect(c.read(wdTransportProvider).isScanning, isTrue);

    await c.read(btTransportProvider.notifier).startScan();
    expect(c.read(wdTransportProvider).isScanning, isFalse);
    expect(wd.stopDiscoveryCalls, 1,
        reason: 'the BT scan start must stop the WFD discovery');
    expect(bt.startScanCalls, 1, reason: 'the BT scan itself must still run');
  });

  test('a Bluetooth scan stops an active Nearby scan', () async {
    final c = container();
    addTearDown(c.dispose);
    await pumpEventQueue();

    await c.read(nearbyTransportProvider.notifier).startScan();
    expect(c.read(nearbyTransportProvider).isScanning, isTrue);

    await c.read(btTransportProvider.notifier).startScan();
    expect(c.read(nearbyTransportProvider).isScanning, isFalse);
    expect(nearby.stopScanCalls, 1,
        reason: 'the BT scan start must stop the Nearby scan');
  });

  test('a Wi-Fi Direct discovery stops an active Bluetooth scan session',
      () async {
    final c = container();
    addTearDown(c.dispose);
    await pumpEventQueue();

    final btNotifier = c.read(btTransportProvider.notifier);
    await btNotifier.startScan();
    bt.onScanStarted?.call(); // the native scan window opened → session live
    expect(c.read(btTransportProvider).isScanning, isTrue);

    await c.read(wdTransportProvider.notifier).startDiscovery();
    expect(c.read(btTransportProvider).isScanning, isFalse);
    expect(bt.stopScanCalls, 1,
        reason: 'the WFD discovery start must stop the BT scan session');
    expect(c.read(wdTransportProvider).isScanning, isTrue);
  });

  test('a Nearby scan stops an active Wi-Fi Direct discovery', () async {
    final c = container();
    addTearDown(c.dispose);
    await pumpEventQueue();

    await c.read(wdTransportProvider.notifier).startDiscovery();
    expect(c.read(wdTransportProvider).isScanning, isTrue);

    await c.read(nearbyTransportProvider.notifier).startScan();
    expect(c.read(wdTransportProvider).isScanning, isFalse);
    expect(wd.stopDiscoveryCalls, 1,
        reason: 'the Nearby scan start must stop the WFD discovery');
    expect(c.read(nearbyTransportProvider).isScanning, isTrue);
  });

  test('idle transports are never touched by a scan start', () async {
    final c = container();
    addTearDown(c.dispose);
    await pumpEventQueue();

    await c.read(btTransportProvider.notifier).startScan();
    expect(bt.startScanCalls, 1);
    expect(wd.stopDiscoveryCalls, 0,
        reason: 'an idle WFD transport must not be touched');
    expect(nearby.stopScanCalls, 0,
        reason: 'an idle Nearby transport must not be touched');
  });
}
