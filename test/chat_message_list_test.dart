// The paged message list + day separators: a chat opens with the newest 20
// messages and scrolling close to the oldest loaded one (the 15th message
// of the initial window) pulls the next older page (+5) from the store; day
// groups older than today carry date separator pills and a pinned chip
// mirrors the day currently at the top of the viewport.
import 'package:chatblue/controllers/chat_transport_binding.dart';
import 'package:chatblue/core/models/chatsession_model.dart';
import 'package:chatblue/core/models/message_model.dart';
import 'package:chatblue/data/db/app_database.dart';
import 'package:chatblue/data/session_repository.dart';
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/l10n/app_localizations_en.dart';
import 'package:chatblue/providers/app_providers.dart';
import 'package:chatblue/providers/chat_controller.dart';
import 'package:chatblue/screens/chat_ui/chat_ui.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sizer/sizer.dart';

import 'support/fake_chat_binding.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeChatBinding binding;
  AppDatabase? db;

  setUp(() {
    binding = FakeChatBinding();
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    // Teardowns run outside the testWidgets fake-async zone: let any
    // unawaited flush land, then close the in-memory database.
    await pumpEventQueue();
    await db?.close();
    db = null;
  });

  MessageModel message(String text, DateTime timestamp) => MessageModel(
        id: text,
        text: text,
        isSentByMe: false,
        timestamp: timestamp,
      );

  ChatSessionModel session(List<MessageModel> messages) => ChatSessionModel(
        id: 'sess-1',
        name: 'PeerOne',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        messages: messages,
        device: const {'name': 'PeerOne', 'address': 'AA:BB:CC:DD:EE:FF'},
        transport: ChatSessionModel.transportBluetooth,
      );

  /// Pumps the message list for a seeded session; returns the container and
  /// the open arg for state reads.
  Future<({ProviderContainer container, ChatOpenArg arg})> pumpList(
    WidgetTester tester,
    ChatSessionModel seeded,
  ) async {
    final c = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db!),
        appLocalizationsProvider.overrideWithValue(AppLocalizationsEn()),
        chatBindingProvider.overrideWith((ref, kind) => binding),
      ],
    );
    addTearDown(c.dispose);
    final arg = ChatOpenArg(
      transport: ChatSessionModel.transportBluetooth,
      session: seeded,
    );
    final sub = c.listen(chatControllerProvider(arg), (_, _) {});
    addTearDown(sub.close);
    final controller = c.read(chatControllerProvider(arg).notifier);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: Sizer(
          builder: (context, orientation, deviceType) => MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => ChatMessageList(
                  state: ref.watch(chatControllerProvider(arg)),
                  controller: controller,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // First frame + the post-frame sticky refresh settling.
    await tester.pump();
    await tester.pump();
    return (container: c, arg: arg);
  }

  ChatState stateOf(ProviderContainer c, ChatOpenArg arg) =>
      c.read(chatControllerProvider(arg));

  testWidgets(
      'scrolling to the oldest loaded messages pulls the next older page',
      (tester) async {
    final base = DateTime(2026, 10, 6, 12);
    final seeded = session([
      for (var i = 29; i >= 0; i--)
        message('msg $i', base.add(Duration(minutes: i))),
    ]);
    await SessionRepository(db!).saveChatSession(seeded);

    final (:container, :arg) = await pumpList(tester, seeded);
    ChatState state() => stateOf(container, arg);

    // The open shows the newest 20; the visible viewport sits at the bottom
    // (the 15th message is far off screen) — nothing may load yet.
    expect(state().messages, hasLength(20));
    expect(state().hasMoreOlder, isTrue);

    // Scroll toward the oldest loaded message: the list is reversed, so the
    // reveal gesture drags the content downward and the build window runs up
    // into the prefetch threshold (the 15th of 20).
    await tester.drag(find.byType(ListView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    final after = state();
    expect(after.messages.length, greaterThan(20),
        reason: 'reaching the 15th message must pull older pages');
    expect(after.messages.length, greaterThanOrEqualTo(25));
    expect(after.messages.length, lessThanOrEqualTo(30));
    // The window grew UPWARD: the newest stays first, older pages append in
    // order, and `hasMoreOlder` only stays true while history is left.
    expect(after.messages.first.text, 'msg 29');
    expect(after.messages.map((m) => m.text).toList(),
        [for (var i = 29; i >= 30 - after.messages.length; i--) 'msg $i']);
    expect(after.messages.last.text, 'msg ${30 - after.messages.length}');
    expect(after.hasMoreOlder, after.messages.length < 30);
  });

  testWidgets('day separators label yesterday and older days, not today',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    final olderDay = DateTime(now.year, now.month, now.day - 5, 12);
    // Newest first.
    final seeded = session([
      message('t-new', today.add(const Duration(minutes: 2))),
      message('t-old', today.add(const Duration(minutes: 1))),
      message('y-new', yesterday.add(const Duration(minutes: 2))),
      message('y-old', yesterday.add(const Duration(minutes: 1))),
      message('o-new', olderDay.add(const Duration(minutes: 2))),
      message('o-old', olderDay.add(const Duration(minutes: 1))),
    ]);
    await pumpList(tester, seeded);

    final olderLabel = DateFormat.yMMMMd('en').format(olderDay);
    // Yesterday's group and the older day each carry their own pill…
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text(olderLabel), findsOneWidget);
    // …while today's group deliberately carries none.
    expect(find.text(DateFormat.yMMMMd('en').format(today)), findsNothing);

    // A day's pill sits at the TOP EDGE of that day's block: above that
    // day's messages (and above the newer days below them).
    final chipY = tester.getTopLeft(find.text('Yesterday')).dy;
    expect(chipY, lessThan(tester.getTopLeft(find.text('y-old')).dy));
    expect(chipY, lessThan(tester.getTopLeft(find.text('t-new')).dy));
  });

  testWidgets(
      'the pinned day chip appears once the viewport top reaches an older day',
      (tester) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final yesterday = DateTime(now.year, now.month, now.day - 1, 12);
    // 20 messages (the initial window): 12 today, 8 yesterday.
    final seeded = session([
      for (var i = 11; i >= 0; i--)
        message('t$i', today.add(Duration(minutes: i))),
      for (var i = 7; i >= 0; i--)
        message('y$i', yesterday.add(Duration(minutes: i))),
    ]);
    await pumpList(tester, seeded);

    // The viewport top is still inside today's block — no pinned chip.
    expect(find.byKey(ChatMessageList.stickyDateChipKey), findsNothing);

    // Scroll into the yesterday block: the viewport top is now a yesterday
    // message, so the pinned chip surfaces with the day label.
    await tester.drag(find.byType(ListView), const Offset(0, 500));
    await tester.pumpAndSettle();
    expect(find.byKey(ChatMessageList.stickyDateChipKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(ChatMessageList.stickyDateChipKey),
        matching: find.text('Yesterday'),
      ),
      findsOneWidget,
    );
    // The pin hugs the top of the list — a fixed small gap, not a 64 px
    // float (the scaffold already keeps the list below the app bar).
    final chipTop =
        tester.getTopLeft(find.byKey(ChatMessageList.stickyDateChipKey)).dy;
    expect(chipTop, lessThan(20),
        reason: 'the pinned chip must sit just below the list top');
  });
}
