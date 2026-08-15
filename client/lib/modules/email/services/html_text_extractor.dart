/// Extracts a plain-text token stream from HTML email bodies for full-text
/// search indexing.
///
/// The destination is an FTS5 column, not a rendered view: stripping markup
/// matters far more than preserving layout, so this trades faithfulness for
/// a clean stream of words. Block-level boundaries exist only to stop
/// adjacent elements from fusing into a false token — `<p>a</p><p>b</p>`
/// must read as "a b", not the single token "ab".
class HtmlTextExtractor {
  // `\1` ties the closing tag to whichever of script/style opened it, so a
  // mismatched `<script>...</style>` (real emails have this) doesn't eat
  // everything up to the next `</style>`.
  static final RegExp _scriptOrStyle = RegExp(
    r'<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>',
    caseSensitive: false,
  );

  static final RegExp _comments = RegExp(r'<!--[\s\S]*?-->');

  // Elements whose start/end also marks a text boundary. Over-producing
  // spaces here is fine — _whitespace collapses them below.
  static final RegExp _blockTags = RegExp(
    r'<\s*/?\s*(p|div|br|tr|td|th|li|h[1-6]|table|section|article|header|footer|blockquote|pre)\b[^>]*>',
    caseSensitive: false,
  );

  static final RegExp _anyTag = RegExp(r'<[^>]*>');

  // `[xX]` because HTML allows either, and the decoder below has always
  // branched on both — but the pattern only ever admitted the lowercase form,
  // so `&#X41;` never reached it and survived as literal text.
  static final RegExp _entity = RegExp(r'&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z]+);');

  static final RegExp _whitespace = RegExp(r'\s+');

  /// Plain text extracted from [html], suitable for a full-text index.
  /// Returns an empty string for null/empty/whitespace-only input.
  static String toPlainText(String? html) {
    if (html == null || html.trim().isEmpty) return '';

    var text = html;
    text = text.replaceAll(_scriptOrStyle, ' ');
    text = text.replaceAll(_comments, ' ');
    text = text.replaceAll(_blockTags, ' ');
    text = text.replaceAll(_anyTag, '');
    // Entities decode only after every tag is gone, so an entity-encoded
    // "<script>" in the original text can never be reinterpreted as markup.
    text = _decodeEntities(text);
    return text.replaceAll(_whitespace, ' ').trim();
  }

  /// The character [code] denotes, or null if it denotes none.
  ///
  /// `String.fromCharCode` throws a `RangeError` outside 0..0x10FFFF, and
  /// [_entity] puts no ceiling on the digits it matches — `&#1111111111111111;`
  /// parses to a perfectly good `int` and then throws. That would not be a
  /// mangled character; it would take down whatever was indexing the mail,
  /// and this text reaches the search backfill, the insert path, the embedding
  /// isolate and the result summarizer alike.
  static String? _charFor(int? code) {
    if (code == null || code < 0 || code > 0x10FFFF) return null;
    return String.fromCharCode(code);
  }

  static String _decodeEntities(String text) {
    return text.replaceAllMapped(_entity, (match) {
      final body = match.group(1)!;
      if (body.startsWith('#x') || body.startsWith('#X')) {
        final code = int.tryParse(body.substring(2), radix: 16);
        return _charFor(code) ?? match.group(0)!;
      }
      if (body.startsWith('#')) {
        final code = int.tryParse(body.substring(1));
        return _charFor(code) ?? match.group(0)!;
      }
      switch (body.toLowerCase()) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        case 'nbsp':
          return ' ';
        default:
          // Unknown entity: leave it exactly as written rather than
          // silently dropping text that might be search-relevant.
          return match.group(0)!;
      }
    });
  }
}
