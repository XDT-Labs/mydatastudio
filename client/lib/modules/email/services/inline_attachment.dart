/// Decides whether a mail attachment is part of the message's own presentation
/// rather than something the sender attached.
///
/// The distinction matters well outside the reading pane. An HTML email drags
/// in every spacer, bullet, tracking pixel, corporate logo and ad banner as a
/// real attachment, and each one is a row in `files` with an image content
/// type — indistinguishable, until now, from a photo someone actually sent.
/// That is what fills the photos module with junk and what makes the embedding
/// isolate spend its time indexing signature logos.
///
/// Every scanner routes through here so the four of them can't drift apart:
/// the PST importer and the three IMAP-based ones (Gmail, Yahoo, Outlook) all
/// see slightly different metadata, and the rules for reconciling it belong in
/// one place.
class InlineAttachment {
  const InlineAttachment._();

  /// Strips the angle brackets a Content-ID header carries.
  ///
  /// `Content-ID: <image001.png@01CC3097>` is the wire form; the `cid:` URL in
  /// the body never has the brackets, so they have to come off before the two
  /// can be compared.
  static String? normalizeContentId(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    // `>= 2` so a bare `<>` unwraps to nothing and is reported absent, rather
    // than surviving as a literal id no body will ever reference.
    final unwrapped =
        trimmed.startsWith('<') && trimmed.endsWith('>') && trimmed.length >= 2
            ? trimmed.substring(1, trimmed.length - 1).trim()
            : trimmed;
    return unwrapped.isEmpty ? null : unwrapped;
  }

  /// True when this attachment is embedded in the message body.
  ///
  /// In order of confidence:
  ///
  ///   1. the HTML body references it as `cid:<content id>` — proof, and the
  ///      only signal available for every mail source;
  ///   2. the part is `Content-Disposition: inline` *and* carries a content
  ///      id — the sender marked it as body content. Disposition alone is not
  ///      enough: clients label genuine attachments `inline` when they want
  ///      them shown in the reading pane, and a PDF invoice is still an
  ///      attachment;
  ///   3. the HTML body references it by filename, which is how older mail
  ///      (and the archives imported before content ids were captured) writes
  ///      the same reference.
  ///
  /// A message with no HTML body has nothing to embed *into*, so rules 1 and 3
  /// can't fire and only an explicit disposition-plus-id counts.
  static bool isInline({
    String? contentId,
    String? fileName,
    String? htmlBody,
    bool dispositionInline = false,
  }) {
    final id = normalizeContentId(contentId);
    final body = htmlBody?.toLowerCase();

    if (id != null && body != null && _references(body, id)) return true;
    if (dispositionInline && id != null) return true;
    if (fileName != null &&
        fileName.isNotEmpty &&
        body != null &&
        _references(body, fileName)) {
      return true;
    }
    return false;
  }

  /// Whether [lowercaseBody] contains a `cid:` reference to [token].
  ///
  /// Plain substring matching rather than a regex: a content id or filename is
  /// arbitrary text and would otherwise have to be escaped, and there is
  /// nothing here a regex would catch that this misses.
  static bool _references(String lowercaseBody, String token) =>
      lowercaseBody.contains('cid:${token.toLowerCase()}');
}
