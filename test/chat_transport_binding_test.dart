import 'dart:typed_data';

import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/services/bt_classic_service.dart';
import 'package:chatblue/providers/transport_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/fake_bt_service.dart';
import 'support/fake_wd_service.dart';

/// Binding contract: live state reads, change-only signal semantics (GetX
/// Rx parity — same-value writes never fire), delegation to the transport
/// notifier, and the WFD peer-name hook fan-out.
class _RecordingListener implements ChatTransportListener {
  final connections = <bool>[];
  final reasons = <String>[];
  final names = <String>[];

  @override
  void onTransportConnectionChanged(bool connected) =>
      connections.add(connected);

  @override
  void onTransportDisconnectReason(String reason) => reasons.add(reason);

  @override
  void onTransportPeerName(String name) => names.add(name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatTransportBinding (bt)', () {
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

    Future<void> connect() async {
      service.onSocketConnected?.call(
        BtDeviceInfo(address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
      );
      service.onSocketData!(Uint8List(0), '@@CHATBLUE_CONNECT@@', kind: 'text');
      await pumpEventQueue();
    }

    test('getters read live transport state', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider); // trigger build (wires service callbacks)
      final binding = c.read(chatBindingProvider('bt'));

      expect(binding.isConnected, isFalse);
      await connect();

      expect(binding.isConnected, isTrue);
      expect(binding.connectedDeviceKey, 'AA:BB:CC:DD:EE:FF');
      expect(binding.transportType, 'bt');
    });

    test('connection signal fires on transition only', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider);
      final binding = c.read(chatBindingProvider('bt'));
      final listener = _RecordingListener();
      binding.addListener(listener);

      await connect();
      expect(listener.connections, [true]);

      // A state change that does not touch the connection: no extra signal.
      service.onScanStarted?.call();
      await pumpEventQueue();
      expect(listener.connections, [true]);
    });

    test('disconnect reason signal carries the reason; same value never refires',
        () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider);
      final binding = c.read(chatBindingProvider('bt'));
      final listener = _RecordingListener();
      binding.addListener(listener);

      await connect();
      service.onSocketDisconnected?.call('manual');
      await pumpEventQueue();
      expect(listener.reasons, ['manual']);

      // Same reason already recorded: an unrelated state change must not
      // re-emit it (GetX `_value == val` parity).
      service.onScanStarted?.call();
      await pumpEventQueue();
      expect(listener.reasons, ['manual']);
    });

    test('method delegation reaches the transport notifier', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider);
      final binding = c.read(chatBindingProvider('bt'));

      // sendMessage is guarded on the live connection state — connect first.
      await connect();
      await binding.sendMessage('x');
      expect(service.sendStringCalls, ['x']);

      await binding.disconnectFromDevice();
      expect(service.disconnectCalls, greaterThan(0));
    });

    test('removeListener stops delivery', () async {
      final c = container();
      addTearDown(c.dispose);
      c.read(btTransportProvider);
      final binding = c.read(chatBindingProvider('bt'));
      final listener = _RecordingListener();
      binding.addListener(listener);
      binding.removeListener(listener);

      await connect();
      expect(listener.connections, isEmpty);
    });
  });

  group('ChatTransportBinding (wfd)', () {
    late FakeWdService service;

    setUp(() {
      service = FakeWdService();
    });

    test('peer name hook is installed and fans out', () async {
      final c = ProviderContainer(
        overrides: [
          wdTransportProvider.overrideWith(
            () => WdTransportNotifier(service: service),
          ),
        ],
      );
      addTearDown(c.dispose);

      final binding = c.read(chatBindingProvider('wfd'));
      final listener = _RecordingListener();
      binding.addListener(listener);

      final notifier = c.read(wdTransportProvider.notifier);
      expect(notifier.onPeerNameForChat, isNotNull);
      notifier.onPeerNameForChat!('Redmi');
      expect(listener.names, ['Redmi']);
    });
  });
}
