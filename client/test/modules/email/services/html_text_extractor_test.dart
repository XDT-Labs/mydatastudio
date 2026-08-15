import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/html_text_extractor.dart';

void main() {
  group('HtmlTextExtractor.toPlainText', () {
    test('drops <script> element content, not just the tags', () {
      const html =
          '<p>Hello</p><script type="text/javascript">'
          'function trackOpenPixelUniqueIdent() { fetch("/x"); }'
          '</script><p>World</p>';
      final result = HtmlTextExtractor.toPlainText(html);
      expect(result, isNot(contains('trackOpenPixelUniqueIdent')));
      expect(result, 'Hello World');
    });

    test('drops <style> element content, not just the tags', () {
      const html =
          '<style>.uniqueHeaderBannerClass { color: red; }</style>'
          '<p>Visible text</p>';
      final result = HtmlTextExtractor.toPlainText(html);
      expect(result, isNot(contains('uniqueHeaderBannerClass')));
      expect(result, 'Visible text');
    });

    test('drops plain HTML comments', () {
      const html = 'A<!-- internal note, not content -->B';
      // Comments are not block boundaries, so surrounding text still fuses
      // — only their content must vanish.
      final result = HtmlTextExtractor.toPlainText(html);
      expect(result, isNot(contains('internal note')));
    });

    test('drops Outlook conditional comments', () {
      const html = 'Start<!--[if mso]><table><tr><td><![endif]-->End';
      final result = HtmlTextExtractor.toPlainText(html);
      expect(result, isNot(contains('mso')));
      expect(result, isNot(contains('<table>')));
    });

    test('adjacent block elements do not fuse into a fake token', () {
      // Naive tag-stripping of <p>a</p><p>b</p> yields "ab", inventing a
      // token that never appeared in the source and would pollute search.
      final result = HtmlTextExtractor.toPlainText('<p>a</p><p>b</p>');
      expect(result, 'a b');
    });

    test('<br> separates the words around it', () {
      final result = HtmlTextExtractor.toPlainText('word1<br>word2');
      expect(result, 'word1 word2');
    });

    test('table cells separate their content', () {
      const html = '<table><tr><td>Name</td><td>Value</td></tr></table>';
      final result = HtmlTextExtractor.toPlainText(html);
      expect(result, 'Name Value');
    });

    test('decodes named entities', () {
      final result = HtmlTextExtractor.toPlainText(
        'Tom &amp; Jerry are pals &lt;3&gt;',
      );
      expect(result, 'Tom & Jerry are pals <3>');
    });

    test('decodes decimal numeric entities', () {
      final result = HtmlTextExtractor.toPlainText('It&#39;s here');
      expect(result, "It's here");
    });

    test('decodes hex numeric entities', () {
      final result = HtmlTextExtractor.toPlainText('It&#x27;s here');
      expect(result, "It's here");
    });

    test('&nbsp; becomes a normal space', () {
      final result = HtmlTextExtractor.toPlainText('a&nbsp;b');
      expect(result, 'a b');
    });

    test('unknown entity survives rather than vanishing', () {
      final result = HtmlTextExtractor.toPlainText('weird &zzz; entity');
      expect(result, 'weird &zzz; entity');
    });

    test('a numeric entity beyond Unicode does not take the mail with it', () {
      // `#\d+` puts no ceiling on the digits it matches, and Dart's
      // String.fromCharCode throws RangeError outside 0..0x10FFFF. This text
      // reaches the FTS backfill, the insert path, the embedding isolate and
      // the result summarizer, so one malformed entity in one 1998 message
      // could abort indexing for the whole archive — and the backfill logs
      // its failure rather than crashing, which is how it would have gone
      // unnoticed.
      final result = HtmlTextExtractor.toPlainText(
        'before &#1111111111111111; after',
      );
      expect(result, 'before &#1111111111111111; after');
    });

    test('a hex entity beyond Unicode is left as written too', () {
      final result = HtmlTextExtractor.toPlainText('x &#xFFFFFFFF; y');
      expect(result, 'x &#xFFFFFFFF; y');
    });

    test('hex entities decode in either case', () {
      // The decoder always branched on '#X', but the pattern only admitted
      // '#x', so the uppercase form could never reach it. HTML permits both,
      // and a word left as `&#X41;` is a word the index cannot match.
      expect(HtmlTextExtractor.toPlainText('&#x41;&#X42;'), 'AB');
    });

    test('the range guard covers the uppercase form as well', () {
      expect(HtmlTextExtractor.toPlainText('x &#XFFFFFFFF; y'),
          'x &#XFFFFFFFF; y');
    });

    test('the last legal code point still decodes', () {
      // The guard must reject what is out of range without moving the range.
      final result = HtmlTextExtractor.toPlainText('edge &#1114111; case');
      expect(result, 'edge ${String.fromCharCode(0x10FFFF)} case');
    });

    test(
      'entity-encoded markup stays literal text, is not re-parsed as a tag',
      () {
        // Decoding must happen after tag-stripping. If it happened before,
        // this would vanish like a real <script> block instead of
        // surviving as visible text.
        final result = HtmlTextExtractor.toPlainText(
          '&lt;script&gt;alert(1)&lt;/script&gt;',
        );
        expect(result, '<script>alert(1)</script>');
      },
    );

    test('collapses runs of whitespace and trims the result', () {
      final result = HtmlTextExtractor.toPlainText(
        '  Hello   \n\n  World  \t ',
      );
      expect(result, 'Hello World');
    });

    test('null input returns empty string', () {
      expect(HtmlTextExtractor.toPlainText(null), '');
    });

    test('empty string returns empty string', () {
      expect(HtmlTextExtractor.toPlainText(''), '');
    });

    test('whitespace-only input returns empty string', () {
      expect(HtmlTextExtractor.toPlainText('   \n\t  '), '');
    });

    test('unclosed tags do not throw and recover the trailing text', () {
      expect(
        () => HtmlTextExtractor.toPlainText('<div><p>unclosed'),
        returnsNormally,
      );
      expect(HtmlTextExtractor.toPlainText('<div><p>unclosed'), 'unclosed');
    });

    test('a lone unmatched "<" does not throw', () {
      expect(() => HtmlTextExtractor.toPlainText('a < b'), returnsNormally);
    });

    test('a truncated tag does not throw', () {
      const html = '<a href="http://example.com';
      expect(() => HtmlTextExtractor.toPlainText(html), returnsNormally);
    });

    test(
      'realistic marketing email fragment yields only human-readable words',
      () {
        const html = '''
<!DOCTYPE html>
<html>
<head>
<style>
.header-banner { color: #ff0000; font-family: Arial; }
</style>
<script type="text/javascript">
function trackOpen() { fetch('/pixel'); }
</script>
</head>
<body>
<!--[if mso]>
<table><tr><td>
<![endif]-->
<table width="600" cellpadding="0" cellspacing="0">
  <tr>
    <td style="padding: 20px; background-color: #fff;">
      <h1>Summer Sale</h1>
      <p>Save up to <strong>50%</strong> on select items.</p>
      <table>
        <tr>
          <td><a href="https://example.com/shop">Shop Now</a></td>
          <td>Limited time offer</td>
        </tr>
      </table>
      <img src="https://track.example.com/open.gif" width="1" height="1" alt="">
    </td>
  </tr>
</table>
<!--[if mso]>
</td></tr></table>
<![endif]-->
</body>
</html>
''';
        final result = HtmlTextExtractor.toPlainText(html);

        expect(result, contains('Summer Sale'));
        expect(result, contains('Save up to 50% on select items.'));
        expect(result, contains('Shop Now'));
        expect(result, contains('Limited time offer'));

        // Markup, CSS, JS, and tracking-pixel noise must not leak through.
        expect(result, isNot(contains('<')));
        expect(result, isNot(contains('>')));
        expect(result, isNot(contains('header-banner')));
        expect(result, isNot(contains('background-color')));
        expect(result, isNot(contains('trackOpen')));
        expect(result, isNot(contains('fetch')));
        expect(result, isNot(contains('cellpadding')));
        expect(result, isNot(contains('mso')));
      },
    );
  });
}
