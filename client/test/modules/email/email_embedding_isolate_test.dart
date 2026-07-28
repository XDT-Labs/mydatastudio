import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_embedding_isolate.dart';

void main() {
  group('EmailEmbeddingIsolate Tests', () {
    test('formatEmailForEmbedding formats email text correctly', () {
      final email = Email(
        id: 'email-1',
        collectionId: 'col-1',
        date: DateTime(2026, 7, 27),
        from: 'alice@example.com',
        to: ['bob@example.com', 'charlie@example.com'],
        cc: ['dave@example.com'],
        subject: 'Project Update',
        plainBody: 'Here is the latest progress report.',
        isDeleted: false,
      );

      final formatted = EmailEmbeddingIsolate.formatEmailForEmbedding(email);

      const expected = 'from: alice@example.com\n'
          'to: [bob@example.com, charlie@example.com]\n'
          'cc: [dave@example.com]\n'
          'subject: Project Update\n\n'
          'Here is the latest progress report.';

      expect(formatted, equals(expected));
    });

    test('formatEmailForEmbedding falls back to snippet/htmlBody when plainBody is null', () {
      final emailHtml = Email(
        id: 'email-2',
        collectionId: 'col-1',
        date: DateTime(2026, 7, 27),
        from: 'newsletter@example.com',
        to: ['user@example.com'],
        cc: [],
        subject: 'Weekly Digest',
        htmlBody: '<p>HTML content digest</p>',
        isDeleted: false,
      );

      final formattedHtml = EmailEmbeddingIsolate.formatEmailForEmbedding(emailHtml);

      expect(formattedHtml, contains('from: newsletter@example.com'));
      expect(formattedHtml, contains('to: [user@example.com]'));
      expect(formattedHtml, contains('cc: []'));
      expect(formattedHtml, contains('subject: Weekly Digest'));
      expect(formattedHtml, contains('<p>HTML content digest</p>'));
    });
  });
}
