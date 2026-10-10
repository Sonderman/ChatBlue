// Regression tests for the nickname dialog flow (home list long-press →
// Set nickname). Device-reported failure this file pins down:
// 'A TextEditingController was used after being disposed' thrown inside the
// layout phase right as the dialog popped with the keyboard closing — the
// frame aborted and the framework cascaded into `_dependents.isEmpty`
// ('debugNeedsLayout' and duplicate-global-key reports followed).
//
// Root cause: the old flow disposed its controller right after
// `showDialog` returned; the future completes at POP time (not when the
// exit animation ends), so any rebuild of the field during the exit — the
// app-wide rebuild that the keyboard-close viewport-metrics resend
// triggers — re-attached to the disposed controller. The dialog now owns
// its controller (`showNicknameDialog` in home_screen.dart); these tests
// exercise the real function under the real root structure (Sizer's
// LayoutBuilder) with the keyboard metrics storm.
import 'package:chatblue/l10n/app_localizations.dart';
import 'package:chatblue/screens/homescreen/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sizer/sizer.dart';

void main() {
  Future<String?>? result;

  setUp(() => result = null);

  /// Host mirrors the real flow: a row whose long-press opens the action
  /// sheet, whose "Set nickname" entry pops the sheet and opens the real
  /// nickname dialog from the item's context — all under the real root
  /// structure (Sizer + MaterialApp, as in main.dart).
  Widget buildHost() => Sizer(
        builder: (context, orientation, deviceType) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (hostContext) => ListView(
                children: [
                  ListTile(
                    title: const Text('PeerOne'),
                    subtitle: const Text('last message  •  2026-10-10 22:54'),
                    onLongPress: () => showModalBottomSheet<void>(
                      context: hostContext,
                      showDragHandle: true,
                      builder: (sheetContext) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.badge_outlined),
                              title: const Text('Set nickname'),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                result = showNicknameDialog(
                                  hostContext,
                                  initial: '',
                                  hint: 'PeerOne',
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> openNicknameDialog(WidgetTester tester) async {
    await tester.pumpWidget(buildHost());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('PeerOne'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set nickname'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  }

  testWidgets(
      'save during the keyboard-open/close rebuild storm settles cleanly',
      (tester) async {
    addTearDown(tester.view.resetViewInsets);
    await openNicknameDialog(tester);

    // The IME opens: viewport metrics change while the field is focused.
    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Kanka');
    await tester.pumpAndSettle();

    // Save → the dialog pops; the keyboard closes right after (metrics
    // resend) — the exit animation still rebuilds the field. The disposed
    // controller used to trip the framework asserts here.
    await tester.tap(find.text('Save'));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(await result, 'Kanka');
  });

  testWidgets('cancel during the keyboard-open state returns null',
      (tester) async {
    addTearDown(tester.view.resetViewInsets);
    await openNicknameDialog(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 800);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(await result, isNull);
  });
}
