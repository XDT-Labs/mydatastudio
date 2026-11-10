import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/email/pages/new_email_page.dart';

void main() {
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: NewEmailPage()));
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('source-$id')));
    await tester.pump();
  }

  testWidgets('Gmail opens the app password form, with no Google sign-in', (
    tester,
  ) async {
    await pumpPage(tester);
    await open(tester, 'gmail');

    expect(find.byKey(const Key('password-field')), findsOneWidget);
    expect(find.text('App Password'), findsOneWidget);
    expect(find.textContaining('Sign in with Google'), findsNothing);
  });

  testWidgets('"All sources" goes back to the cards', (tester) async {
    await pumpPage(tester);
    await open(tester, 'yahoo');
    expect(find.byKey(const ValueKey('source-gmail')), findsNothing);

    await tester.tap(find.text('All sources'));
    await tester.pump();
    expect(find.byKey(const ValueKey('source-gmail')), findsOneWidget);
  });

  testWidgets('the PST card opens the file import form, not an account form', (
    tester,
  ) async {
    await pumpPage(tester);
    await open(tester, 'pst');

    expect(find.byKey(const Key('email-field')), findsNothing);
    expect(find.text('Import PST File'), findsOneWidget);
  });
}
