/// One parsed mailbox, e.g. `Google Payments <payments-noreply@google.com>`.
class ParsedAddress {
  /// Lowercased, angle-brackets stripped, trimmed. This is the identity key:
  /// production data already has case-variant duplicates of the same
  /// mailbox (`Bob@X.COM` / `bob@x.com`), so the contacts index must key on
  /// this, not the raw header text.
  final String address;

  /// Display name with original casing, or null when the header had none.
  final String? displayName;

  /// Substring of [address] before the first '@'. Used for prefix-ranked
  /// autocomplete, so it is derived once here rather than re-split by every
  /// caller.
  final String localPart;

  const ParsedAddress({
    required this.address,
    required this.displayName,
    required this.localPart,
  });

  @override
  bool operator ==(Object other) =>
      other is ParsedAddress && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() =>
      displayName == null ? address : '$displayName <$address>';
}

/// Parses RFC 5322 address headers as they actually appear in the emails
/// table: `from` is a single address (often with a display name), while
/// `to`/`cc` are comma-joined lists that are frequently bare addresses.
class AddressParser {
  /// Parses a single address field (e.g. emails."from").
  /// Returns null when no usable address is present rather than throwing,
  /// since header text from the wild is never guaranteed well-formed.
  static ParsedAddress? parseOne(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    String? displayName;
    String addressPart;

    final ltIndex = trimmed.indexOf('<');
    if (ltIndex != -1) {
      final namePart = trimmed.substring(0, ltIndex).trim();
      final gtIndex = trimmed.indexOf('>', ltIndex);
      // An unterminated '<' still has a real address after it in practice
      // (a client that forgot the closing bracket) - take the rest of the
      // string rather than giving up.
      addressPart =
          gtIndex != -1
              ? trimmed.substring(ltIndex + 1, gtIndex)
              : trimmed.substring(ltIndex + 1);
      addressPart = addressPart.trim();

      if (namePart.isNotEmpty) {
        displayName = _stripQuotes(namePart);
      }
    } else {
      addressPart = trimmed;
    }

    // No '@' means there's no mailbox to key a contact on, regardless of
    // what else is present.
    if (!addressPart.contains('@')) return null;

    final normalized = addressPart.toLowerCase();
    final localPart = normalized.substring(0, normalized.indexOf('@'));

    return ParsedAddress(
      address: normalized,
      displayName: displayName,
      localPart: localPart,
    );
  }

  /// Parses a comma-joined address list (e.g. emails."to" / emails."cc").
  /// Skips unparseable entries rather than throwing, and deduplicates by
  /// normalized address - real "to" lists mix case variants of the same
  /// mailbox across messages, and a naive dedupe-free index would fragment
  /// one contact into several.
  static List<ParsedAddress> parseList(String? raw) {
    if (raw == null) return [];
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return [];

    // Keeps insertion order and first-seen display name while deduping,
    // which a Set<ParsedAddress> plus a separate list would need two passes
    // to get right.
    final byAddress = <String, ParsedAddress>{};
    for (final segment in _splitAddressList(trimmed)) {
      final parsed = parseOne(segment);
      if (parsed == null) continue;
      byAddress.putIfAbsent(parsed.address, () => parsed);
    }
    return byAddress.values.toList();
  }

  /// Splits on commas that are outside both a quoted display name and an
  /// angle-bracket address, e.g. `"Nimer, Mike" <mike@x.com>,bob@y.com`
  /// must split into two entries, not four. A regex can't track nesting
  /// depth across the whole string, so this walks it character by
  /// character instead. An unterminated quote or bracket simply never
  /// closes, so everything after it stays in one segment - degraded, but
  /// never a throw.
  static List<String> _splitAddressList(String raw) {
    final segments = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var angleDepth = 0;

    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == '"') {
        inQuotes = !inQuotes;
        current.write(c);
      } else if (c == '<' && !inQuotes) {
        angleDepth++;
        current.write(c);
      } else if (c == '>' && !inQuotes) {
        if (angleDepth > 0) angleDepth--;
        current.write(c);
      } else if (c == ',' && !inQuotes && angleDepth == 0) {
        segments.add(current.toString());
        current.clear();
      } else {
        current.write(c);
      }
    }
    segments.add(current.toString());

    return segments.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  }

  static String _stripQuotes(String name) {
    if (name.length >= 2 && name.startsWith('"') && name.endsWith('"')) {
      return name.substring(1, name.length - 1);
    }
    return name;
  }
}
