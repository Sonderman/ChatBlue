import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizer/sizer.dart';

/// Delivery-tick contract of the message bubble: one icon per outgoing
/// delivery state, nothing on incoming bubbles, localized semantics.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MessageModel msg(String? delivery, {bool mine = true}) => MessageModel(
        id: 'm1',
        text: 'hello',
        isSentByMe: mine,
        timestamp: DateTime(2026, 10, 10, 17, 30),
        delivery: delivery,
      );

  Future<void> pumpBubble(WidgetTester tester, MessageModel message) async {
    await tester.pumpWidget(
      Sizer(
        builder: (context, orientation, deviceType) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatMessageBubble(message: message)),
        ),
      ),
    );
  }

  testWidgets('outgoing bubbles render one tick per delivery state',
      (tester) async {
    await pumpBubble(tester, msg(MessageModel.deliveryPending));
    expect(find.byIcon(Icons.schedule), findsOneWidget);

    await pumpBubble(tester, msg(MessageModel.deliverySent));
    expect(find.byIcon(Icons.done), findsOneWidget);

    await pumpBubble(tester, msg(MessageModel.deliveryDelivered));
    expect(find.byIcon(Icons.done_all), findsOneWidget);

    await pumpBubble(tester, msg(MessageModel.deliveryFailed));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);

    // Legacy rows (persisted before the feature) fall back to a single tick.
    await pumpBubble(tester, msg(null));
    expect(find.byIcon(Icons.done), findsOneWidget);
  });

  testWidgets('incoming bubbles show no tick', (tester) async {
    await pumpBubble(tester, msg(MessageModel.deliveryDelivered, mine: false));
    expect(find.byIcon(Icons.done_all), findsNothing);
    expect(find.byIcon(Icons.done), findsNothing);
    expect(find.byIcon(Icons.schedule), findsNothing);
  });

  testWidgets('the delivered tick carries a localized semantics label',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpBubble(tester, msg(MessageModel.deliveryDelivered));
    expect(
      tester.getSemantics(find.byIcon(Icons.done_all)).label,
      contains('Delivered'),
    );
    handle.dispose();
  });

  testWidgets('a size-less deferred media row renders the bare download hint',
      (tester) async {
    // The dead-path repair sentinel: unknown size (0) must not read "0 B".
    await pumpBubble(
      tester,
      MessageModel(
        id: 'a1',
        text: '0:18',
        isSentByMe: false,
        timestamp: DateTime(2026, 10, 10, 22, 54),
        remoteMediaSize: 0,
        transferKind: 'audio',
      ),
    );
    expect(find.text(AppLocalizationsEn().downloadMediaHint), findsOneWidget);
    expect(find.textContaining('0 B'), findsNothing);

    // A known size keeps the sized caption.
    await pumpBubble(
      tester,
      MessageModel(
        id: 'a2',
        text: '0:18',
        isSentByMe: false,
        timestamp: DateTime(2026, 10, 10, 22, 54),
        remoteMediaSize: 297,
        transferKind: 'audio',
      ),
    );
    expect(find.textContaining('297 B •'), findsOneWidget);
  });
}
