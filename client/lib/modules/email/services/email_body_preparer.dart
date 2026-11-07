import 'dart:convert';
import 'dart:io' as io;

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:path/path.dart' as p;

/// Maps the `cid:` tokens in an HTML body onto the attachments they name.
///
/// Split out from the widget because these matching rules are the whole reason
/// embedded images render at all, and they need to be exercised directly.
class CidResolver {
  /// Matches a `cid:` reference wherever it appears — `src="cid:x"`, a bare
  /// `src=cid:x`, or a CSS `url(cid:x)`.
  static final RegExp pattern = RegExp(
    'cid:([^"\'\\s>)]+)',
    caseSensitive: false,
  );

  /// Every distinct `cid:` token in [html].
  static Set<String> referencesIn(String html) =>
      pattern.allMatches(html).map((m) => m.group(1)!).toSet();

  /// Resolves one `cid:` token to the attachment it names, or null.
  ///
  /// The content id is the authoritative match. The filename fallbacks exist
  /// for archives imported before content ids were captured: Outlook writes
  /// ids of the form `image001.png@01CC3097.BF0BAC70`, whose local part is the
  /// attachment's filename, so those still resolve without a re-import.
  ///
  /// Matching is case-insensitive, like [pattern] above and
  /// [InlineAttachment.isInline] — senders are inconsistent about Content-ID
  /// casing. An exact match here would make a casing mismatch hide the
  /// attachment completely: the scanner flags it `isInline` (so it is kept out
  /// of the attachments strip) but the body then fails to resolve it.
  static model.File? match(String ref, List<model.File> attachments) {
    final normalizedRef = ref.toLowerCase();
    for (final file in attachments) {
      final contentId = file.contentId;
      if (contentId != null && contentId.toLowerCase() == normalizedRef) {
        return file;
      }
    }
    final localPart = normalizedRef.split('@').first;
    for (final file in attachments) {
      final name = file.name.toLowerCase();
      if (name == normalizedRef || name == localPart) return file;
    }
    return null;
  }
}

/// A message body ready to hand to any `EmailBodyView`.
class PreparedEmailBody {
  const PreparedEmailBody({
    required this.html,
    this.plainText,
    this.inlinedAttachmentIds = const {},
  });

  /// A complete, sanitised HTML document with the CSP in place and `cid:`
  /// references inlined. Plain-text mail gets one too, for the WebView.
  final String html;

  /// The raw text when the message has no HTML body, else null. Renderers that
  /// ignore `white-space: pre-wrap` use this so line breaks survive.
  final String? plainText;

  /// Attachments the HTML embeds, which the attachments strip leaves out.
  final Set<String> inlinedAttachmentIds;
}

/// Turns a stored message into a [PreparedEmailBody].
///
/// Shared in front of every renderer so sanitising, the CSP and `cid:`
/// inlining can't drift between platforms.
class EmailBodyPreparer {
  static final AppLogger _logger = AppLogger(null);

  static Future<PreparedEmailBody> prepare({
    required String? htmlBody,
    required String? plainBody,
    required List<model.File> attachments,
  }) async {
    if (htmlBody != null && htmlBody.trim().isNotEmpty) {
      final Set<String> inlined = {};
      final html = await _resolveCidReferences(
        _sanitizeHtml(htmlBody),
        attachments,
        inlined,
      );
      return PreparedEmailBody(html: html, inlinedAttachmentIds: inlined);
    }
    if (plainBody != null && plainBody.trim().isNotEmpty) {
      final escaped = _escapeHtml(plainBody);
      return PreparedEmailBody(
        html:
            '<html><head>$_csp</head><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">$escaped</body></html>',
        plainText: plainBody,
      );
    }
    return const PreparedEmailBody(
      html:
          '<html><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">(No content)</body></html>',
      plainText: '(No content)',
    );
  }

  static const _csp =
      '<meta http-equiv="Content-Security-Policy" '
      "content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:;\">";

  /// Inline images are small by nature; anything this large is a real
  /// attachment mislabelled, and base64 in the page would cost more than the
  /// broken icon it replaces.
  static const int _maxInlineBytes = 8 * 1024 * 1024;

  /// Rewrites every resolvable `cid:` reference in [html] to a `data:` URI.
  ///
  /// The body arrives referencing its embedded images by content id, but the
  /// extracted attachments live on disk and the WebView is fed a bare HTML
  /// string with no base URL — so nothing resolves and every embedded image
  /// renders as a broken link. Base64 is what makes them displayable without
  /// granting the WebView filesystem access; the CSP above already allows
  /// `data:` images and nothing else.
  ///
  /// Ids of the attachments actually inlined are added to [inlined] so the
  /// caller can keep them out of the attachments strip, the way a mail client
  /// does — otherwise a twelve-image signature shows up twice.
  static Future<String> _resolveCidReferences(
    String html,
    List<model.File> attachments,
    Set<String> inlined,
  ) async {
    if (attachments.isEmpty) return html;

    final refs = CidResolver.referencesIn(html);
    if (refs.isEmpty) return html;

    var result = html;
    for (final ref in refs) {
      final match = CidResolver.match(ref, attachments);
      if (match == null) continue;

      final uri = await _readAsDataUri(match);
      if (uri == null) continue;

      result = result.replaceAll(
        RegExp('cid:${RegExp.escape(ref)}', caseSensitive: false),
        uri,
      );
      inlined.add(match.id);
    }
    return result;
  }

  static Future<String?> _readAsDataUri(model.File file) async {
    try {
      final ioFile = io.File(file.path);
      if (!await ioFile.exists()) return null;
      if (await ioFile.length() > _maxInlineBytes) return null;
      final bytes = await ioFile.readAsBytes();
      return 'data:${_imageMimeType(file.name)};base64,${base64Encode(bytes)}';
    } catch (e) {
      _logger.w(
        "EmailBodyPreparer: could not inline attachment ${file.name}: $e",
      );
      return null;
    }
  }

  /// MIME type for a `data:` URI, from the filename.
  ///
  /// The stored `content_type` can't be used: it holds the app's own coarse
  /// category (`image`, `pdf`, ...), not a real MIME type.
  static String _imageMimeType(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.bmp':
        return 'image/bmp';
      case '.webp':
        return 'image/webp';
      case '.svg':
        return 'image/svg+xml';
      case '.tif':
      case '.tiff':
        return 'image/tiff';
      case '.ico':
        return 'image/x-icon';
      default:
        return 'application/octet-stream';
    }
  }

  static String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _sanitizeHtml(String html) {
    var s = html;
    s = s.replaceAll(
      RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
      '',
    );
    s = s.replaceAll(
      RegExp(r"""\s+on\w+\s*=\s*["'][^"']*["']""", caseSensitive: false),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+on\w+\s*=\s*\S+', caseSensitive: false), '');
    s = s.replaceAll(
      RegExp(
        r'<(iframe|object|embed|form|applet|base)[\s\S]*?(/?>|</\1>)',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(
      RegExp(r'javascript\s*:', caseSensitive: false),
      'blocked:',
    );
    s = s.replaceAll(RegExp(r'<meta[^>]*>', caseSensitive: false), '');

    if (s.contains(RegExp(r'<head', caseSensitive: false))) {
      s = s.replaceFirst(
        RegExp(r'<head([^>]*)>', caseSensitive: false),
        '<head\$1>$_csp',
      );
    } else if (s.contains(RegExp(r'<html', caseSensitive: false))) {
      s = s.replaceFirst(
        RegExp(r'<html([^>]*)>', caseSensitive: false),
        '<html\$1><head>$_csp</head>',
      );
    } else {
      s = '<html><head>$_csp</head><body>$s</body></html>';
    }
    return s;
  }
}
