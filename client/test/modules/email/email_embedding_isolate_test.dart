import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_embedding_isolate.dart';
import 'package:mydatastudio/modules/email/services/searchable_body.dart';

Email _email({String? plainBody, String? htmlBody, String? snippet}) {
  return Email(
    id: 'email-1',
    collectionId: 'col-1',
    date: DateTime(2026, 7, 27),
    from: 'alice@example.com',
    to: ['bob@example.com', 'charlie@example.com'],
    cc: ['dave@example.com'],
    subject: 'Project Update',
    plainBody: plainBody,
    htmlBody: htmlBody,
    snippet: snippet,
    isDeleted: false,
  );
}

void main() {
  group('EmailEmbeddingIsolate Tests', () {
    test('formatEmailForEmbedding formats email text correctly', () {
      final formatted = EmailEmbeddingIsolate.formatEmailForEmbedding(
        _email(plainBody: 'Here is the latest progress report.'),
      );

      const expected =
          'from: alice@example.com\n'
          'to: [bob@example.com, charlie@example.com]\n'
          'cc: [dave@example.com]\n'
          'subject: Project Update\n\n'
          'Here is the latest progress report.';

      expect(formatted, equals([expected]));
    });

    test('an HTML-only email embeds its text, not its markup', () {
      // Chunking turns raw HTML from a bad vector into a bad corpus: markup is
      // most of the bytes, so most chunks become `<td style=...>` and CSS —
      // each one separately retrievable and competing with real text. Measured
      // on the dev archive, the 380 HTML-only messages chunk to 8,825 pieces
      // raw against 587 stripped.
      final formattedHtml = EmailEmbeddingIsolate.formatEmailForEmbedding(
        _email(
          htmlBody:
              '<div class="header" style="color:#fff"><p>HTML content digest</p></div>',
        ),
      ).single;

      expect(formattedHtml, contains('from: alice@example.com'));
      expect(
        formattedHtml,
        contains('to: [bob@example.com, charlie@example.com]'),
      );
      expect(formattedHtml, contains('cc: [dave@example.com]'));
      expect(formattedHtml, contains('subject: Project Update'));
      expect(formattedHtml, contains('HTML content digest'));
      expect(formattedHtml, isNot(contains('<div')));
      expect(formattedHtml, isNot(contains('style=')));
    });

    test('the embedded body is the same text keyword search indexes', () {
      // Two indexes that disagree about what a message says produce results
      // nothing downstream can reconcile — a query matches in one and not the
      // other, and neither answer is wrong on its own terms.
      final email = _email(
        htmlBody: '<p>Quarterly numbers are <b>attached</b>.</p>',
      );
      final chunk = EmailEmbeddingIsolate.formatEmailForEmbedding(email).single;

      expect(chunk, endsWith(searchableBodyText(email)));
    });

    test('a snippet is used when there is no body of either kind', () {
      // 45 messages in the dev archive carry a snippet and nothing else. They
      // would otherwise embed their headers alone.
      final chunk = EmailEmbeddingIsolate.formatEmailForEmbedding(
        _email(snippet: 'Lunch on Thursday?'),
      ).single;

      expect(chunk, endsWith('Lunch on Thursday?'));
    });

    test('an email with no body still produces one vector', () {
      // Headers alone are worth embedding — `from:`/`subject:` carry real
      // signal. Returning nothing here would leave the email permanently
      // outside semantic search and, worse, permanently in the backfill queue.
      final chunks = EmailEmbeddingIsolate.formatEmailForEmbedding(_email());
      expect(chunks, hasLength(1));
      expect(chunks.single, endsWith('subject: Project Update\n\n'));
    });
  });

  group('EmailEmbeddingIsolate — chunking long bodies', () {
    test('a body at or under the chunk size stays a single chunk', () {
      // The measured corpus is half under 566 characters (search plan 16a), so
      // this is the path 84% of the archive takes. It must produce exactly what
      // the single-vector pipeline produced, or the migration re-embeds the
      // whole archive to arrive back where it started.
      final body = 'x' * EmailEmbeddingIsolate.chunkSize;
      expect(EmailEmbeddingIsolate.chunkBody(body), equals([body]));
    });

    test('one character over the limit splits into two overlapping chunks', () {
      final body = 'x' * (EmailEmbeddingIsolate.chunkSize + 1);
      final chunks = EmailEmbeddingIsolate.chunkBody(body);

      expect(chunks, hasLength(2));
      expect(chunks.first.length, EmailEmbeddingIsolate.chunkSize);
      expect(chunks.last, endsWith('x'));
    });

    test('chunks cover the whole body, in order, with nothing dropped', () {
      // The failure this guards against is silent: a body reassembled short by
      // even one character means some run of text exists in no chunk and is
      // unfindable, with nothing in the results to say so.
      final body = List.generate(9000, (i) => String.fromCharCode(97 + i % 26))
          .join();
      final chunks = EmailEmbeddingIsolate.chunkBody(body);

      final step =
          EmailEmbeddingIsolate.chunkSize - EmailEmbeddingIsolate.chunkOverlap;
      final buffer = StringBuffer(chunks.first);
      for (final chunk in chunks.skip(1)) {
        buffer.write(chunk.substring(EmailEmbeddingIsolate.chunkOverlap));
      }
      expect(buffer.toString(), equals(body));
      expect(chunks.length, (body.length / step).ceil());
    });

    test('any span shorter than the overlap survives intact in some chunk', () {
      // This is what the overlap is *for*. Without it a phrase straddling a
      // boundary appears in no chunk in one piece, and the query that quotes
      // that phrase matches nothing — the retrieval failure chunking was
      // adopted to remove, reintroduced at every boundary.
      final body = List.generate(9000, (i) => 'word$i ').join();
      final chunks = EmailEmbeddingIsolate.chunkBody(body);
      final step =
          EmailEmbeddingIsolate.chunkSize - EmailEmbeddingIsolate.chunkOverlap;

      for (var start = 0;
          start + EmailEmbeddingIsolate.chunkOverlap <= body.length;
          start += step ~/ 3) {
        final span = body.substring(
          start,
          start + EmailEmbeddingIsolate.chunkOverlap,
        );
        expect(
          chunks.any((chunk) => chunk.contains(span)),
          isTrue,
          reason: 'span at offset $start is split across every chunk',
        );
      }
    });

    test('every chunk carries the full headers, not just the first', () {
      // A chunk lifted from the middle of a quoted thread is anonymous text
      // without them: nothing ties it to its sender, recipients or subject,
      // which is most of what makes a mail vector about that message rather
      // than about the topic in general.
      final chunks = EmailEmbeddingIsolate.formatEmailForEmbedding(
        _email(plainBody: 'y' * 9000),
      );

      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk, startsWith('from: alice@example.com\n'));
        expect(chunk, contains('subject: Project Update\n\n'));
      }
    });
  });
}
