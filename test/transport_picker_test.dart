import 'dart:async';

import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:chatblue/screens/chat_ui/connection_notice.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizer/sizer.dart';

import 'support/fake_chat_binding.dart';

/// The chat Connect button's transport picker: three labelled options, the
/// current transport delegating to the classic reconnect, another transport
/// dialing through ITS binding behind the cancellable connecting panel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChatBinding btBinding;
  late FakeChatBinding wfdBinding;
  AppDatabase? db;

  setUp(() {
    btBinding = FakeChatBinding();
    wfdBinding =
        FakeChatBinding(transport: ChatSessionModel.transportWifiDirect);
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    // Teardowns run OUTSIDE the testWidgets fake-async zone (real waits
    // complete here): cancel the notice timer, let any unawaited flush
    // land, then close the in-memory database.
    ConnectionNotice.dismiss();
    await pumpEventQueue();
    await db?.close();
    db = null;
  });

  ProviderContainer container() => ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db!),
          appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
          chatBindingProvider.overrideWith((ref, kind) => switch (kind) {
                ChatSessionModel.transportBluetooth => btBinding,
                ChatSessionModel.transportWifiDirect => wfdBinding,
                _ => throw ArgumentError('no fake for $kind'),
              }),
        ],
      );

  ChatSessionModel session({
    Map<String, String> deviceAddresses = const {},
  }) =>
      ChatSessionModel(
        id: 'sess-1',
        name: 'PeerOne',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        messages: const [],
        device: const {'name': 'PeerOne', 'address': 'AA:BB:CC:DD:EE:FF'},
        transport: ChatSessionModel.transportBluetooth,
        deviceAddresses: deviceAddresses,
      );

  Future<ChatController> pumpChat(
    WidgetTester tester,
    ProviderContainer c,
    ChatOpenArg arg,
  ) async {
    final sub = c.listen(chatControllerProvider(arg), (_, _) {});
    addTearDown(sub.close);
    final controller = c.read(chatControllerProvider(arg).notifier);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: Sizer(
          builder: (context, orientation, deviceType) => MaterialApp(
            navigatorKey: navigatorKey,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ChatInputBar(
                  state: ref.watch(chatControllerProvider(arg)),
                  controller: controller,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Flush the open microtasks (pumpEventQueue would hang: its zero-delay
    // timers never fire inside testWidgets' fake-async zone).
    await tester.pump();
    return controller;
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  testWidgets('the Connect button opens the method picker with three options',
      (tester) async {
    final c = container();
    addTearDown(c.dispose);
    final arg = ChatOpenArg(
      transport: ChatSessionModel.transportBluetooth,
      session: session(),
    );
    await pumpChat(tester, c, arg);

    await openPicker(tester);
    expect(find.text('Choose connection method'), findsOneWidget);
    expect(find.text('Bluetooth'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
    expect(find.text('Nearby'), findsOneWidget);
    // Each option carries its channel icon and one-line hint.
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
    expect(find.byIcon(Icons.wifi_tethering), findsOneWidget);
    expect(find.byIcon(Icons.sensors), findsOneWidget);
    expect(find.text('No Wi‑Fi needed · slower'), findsOneWidget);

    // Dismissing without a choice dials nothing.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(btBinding.connectCalls, isEmpty);
    expect(wfdBinding.connectCalls, isEmpty);
  });

  testWidgets('selecting the current transport runs the classic reconnect',
      (tester) async {
    final c = container();
    addTearDown(c.dispose);
    final arg = ChatOpenArg(
      transport: ChatSessionModel.transportBluetooth,
      session: session(),
    );
    await pumpChat(tester, c, arg);

    await openPicker(tester);
    await tester.tap(find.text('Bluetooth'));
    await tester.pumpAndSettle();

    expect(btBinding.connectCalls, [
      (address: 'AA:BB:CC:DD:EE:FF', name: 'PeerOne'),
    ]);
    expect(wfdBinding.connectCalls, isEmpty);

    // Cancel the notice's auto-dismiss timer inside the body: the pending
    // timer invariant runs before tearDown.
    ConnectionNotice.dismiss();
    await tester.pump();
  });

  testWidgets(
      'selecting another transport dials THAT transport; the panel stays '
      'until the dial settles', (tester) async {
    final c = container();
    addTearDown(c.dispose);
    final arg = ChatOpenArg(
      transport: ChatSessionModel.transportBluetooth,
      session: session(),
    );
    await pumpChat(tester, c, arg);

    wfdBinding.holdConnect = Completer<void>();
    await openPicker(tester);
    await tester.tap(find.text('Wi-Fi'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The connecting panel is up while the target transport's dial runs.
    expect(find.text('Connecting…'), findsOneWidget);

    wfdBinding.holdConnect!.complete();
    await tester.pumpAndSettle();

    // No Wi‑Fi Direct address was ever learned for this peer: the target
    // transport receives NO address and discovers the peer by name instead
    // (the old code handed over the single stored address — a value of the
    // OTHER transport's scheme, which a Bluetooth dial then rejected).
    expect(wfdBinding.connectCalls, [
      (address: null, name: 'PeerOne'),
    ]);
    expect(btBinding.connectCalls, isEmpty);
    // The fake reports no link and nothing pending: the failure notice.
    expect(find.text('Could not connect!'), findsOneWidget);

    // Cancel the notice's auto-dismiss timer inside the body: the pending
    // timer invariant runs before tearDown.
    ConnectionNotice.dismiss();
    await tester.pump();
  });

  testWidgets(
      'a known per-transport address is handed to the target transport',
      (tester) async {
    final c = container();
    addTearDown(c.dispose);
    final arg = ChatOpenArg(
      transport: ChatSessionModel.transportBluetooth,
      session: session(deviceAddresses: const {'wfd': '11:22:33:44:55:66'}),
    );
    await pumpChat(tester, c, arg);

    await openPicker(tester);
    await tester.tap(find.text('Wi-Fi'));
    await tester.pumpAndSettle();

    // The learned Wi‑Fi Direct address rides to the target transport — no
    // discovery needed for it.
    expect(wfdBinding.connectCalls, [
      (address: '11:22:33:44:55:66', name: 'PeerOne'),
    ]);

    // Cancel the notice's auto-dismiss timer inside the body.
    ConnectionNotice.dismiss();
    await tester.pump();
  });
}
