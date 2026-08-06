import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/html_text_extractor.dart';

/// The body text stored in `emails.body_text` and indexed for keyword search.
///
/// Prefers `plain_body` — it is what the sender actually wrote, and extracting
/// from HTML can only ever approximate it. But a third of the mail in a real
/// archive arrives HTML-only, and indexing `plain_body` alone left every word
/// of those messages unsearchable, so the HTML body is the fallback rather
/// than nothing.
///
/// The markup is stripped rather than indexed raw: FTS5 would tokenise
/// `<div class="header">` into `div`, `class` and `header`, making those words
/// match a third of the archive.
String searchableBodyText(Email email) {
  return bodyTextFrom(email.plainBody, email.htmlBody);
}

/// [searchableBodyText] over raw column values, for the backfill — which reads
/// rows directly rather than building [Email] models it would immediately
/// discard.
String bodyTextFrom(String? plainBody, String? htmlBody) {
  final plain = plainBody?.trim() ?? '';
  if (plain.isNotEmpty) return plain;
  return HtmlTextExtractor.toPlainText(htmlBody);
}
