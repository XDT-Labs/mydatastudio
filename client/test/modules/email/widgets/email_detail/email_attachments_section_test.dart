import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_detail/email_attachments_section.dart';
import '../../../../helpers/file_fixture.dart';

void main() {
  group('EmailAttachmentsSection', () {
    testWidgets('shows attachment count', (tester) async {
      final attachments = [
        makeTestFile(name: 'a.pdf', contentType: 'application/pdf'),
        makeTestFile(name: 'b.pdf', contentType: 'application/pdf'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailAttachmentsSection(attachments: attachments),
          ),
        ),
      );

      expect(find.text('2 Attachments'), findsOneWidget);
    });

    testWidgets('shows one attachment', (tester) async {
      final attachments = [
        makeTestFile(name: 'file.txt', contentType: 'text/plain'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailAttachmentsSection(attachments: attachments),
          ),
        ),
      );

      expect(find.text('1 Attachments'), findsOneWidget);
      expect(find.text('file.txt'), findsOneWidget);
    });
  });
}
