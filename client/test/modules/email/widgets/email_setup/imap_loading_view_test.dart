import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_loading_view.dart';

void main() {
  group('ImapLoadingView', () {
    testWidgets('shows progress indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ImapLoadingView())),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows verifying text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ImapLoadingView())),
      );

      expect(find.textContaining('erifying'), findsOneWidget);
    });
  });
}
