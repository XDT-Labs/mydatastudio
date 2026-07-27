import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/inline_attachment.dart';

/// Every case here decides whether an image ends up in the photos module and
/// the embedding index. Getting it wrong in one direction fills both with
/// spacer GIFs and ad banners; in the other, it silently hides a photo someone
/// was actually sent.
void main() {
  group('normalizeContentId', () {
    test('strips the angle brackets a Content-ID header carries', () {
      // The header is `<id>`, the body writes `cid:id` — they never compare
      // equal until the brackets come off.
      expect(
        InlineAttachment.normalizeContentId('<image001.png@01CC3097>'),
        'image001.png@01CC3097',
      );
    });

    test('leaves an already-bare id alone', () {
      expect(
        InlineAttachment.normalizeContentId('image001.png@01CC3097'),
        'image001.png@01CC3097',
      );
    });

    test('treats missing, empty and bracket-only ids as absent', () {
      expect(InlineAttachment.normalizeContentId(null), isNull);
      expect(InlineAttachment.normalizeContentId(''), isNull);
      expect(InlineAttachment.normalizeContentId('   '), isNull);
      expect(InlineAttachment.normalizeContentId('<>'), isNull);
    });

    test('trims surrounding whitespace', () {
      expect(InlineAttachment.normalizeContentId('  <a@b>  '), 'a@b');
    });
  });

  group('isInline', () {
    const body = '<html><body>'
        '<img src="cid:image001.png@01CC3097">'
        '</body></html>';

    test('a body referencing the content id is embedded', () {
      expect(
        InlineAttachment.isInline(
          contentId: '<image001.png@01CC3097>',
          fileName: 'image001.png',
          htmlBody: body,
        ),
        isTrue,
      );
    });

    test('matching ignores case, since senders are inconsistent', () {
      expect(
        InlineAttachment.isInline(
          contentId: 'IMAGE001.PNG@01CC3097',
          htmlBody: body,
        ),
        isTrue,
      );
    });

    test('an unreferenced attachment is a real attachment', () {
      // The photo case: sent alongside the message, not part of it.
      expect(
        InlineAttachment.isInline(
          contentId: null,
          fileName: 'Sunset.jpg',
          htmlBody: body,
        ),
        isFalse,
      );
    });

    test('disposition inline plus a content id counts as embedded', () {
      // Covers a body that references nothing because the HTML was stripped,
      // or a sender that only sets the header.
      expect(
        InlineAttachment.isInline(
          contentId: '<logo@corp>',
          fileName: 'logo.png',
          htmlBody: '<html><body>Hi</body></html>',
          dispositionInline: true,
        ),
        isTrue,
      );
    });

    test('disposition inline without a content id is not enough', () {
      // Clients mark genuine attachments `inline` to have them shown in the
      // reading pane. A PDF invoice displayed inline is still an attachment,
      // and a photo sent this way must not vanish from the photos module.
      expect(
        InlineAttachment.isInline(
          contentId: null,
          fileName: 'invoice.pdf',
          htmlBody: '<html><body>See attached</body></html>',
          dispositionInline: true,
        ),
        isFalse,
      );
    });

    test('falls back to the filename for mail with no content id', () {
      // How older mail — and archives imported before content ids were
      // captured — writes the same reference.
      expect(
        InlineAttachment.isInline(
          contentId: null,
          fileName: 'image001.png',
          htmlBody: '<img src="cid:image001.png">',
        ),
        isTrue,
      );
    });

    test('a plain-text message has nothing to embed into', () {
      expect(
        InlineAttachment.isInline(
          contentId: '<logo@corp>',
          fileName: 'logo.png',
          htmlBody: null,
        ),
        isFalse,
      );
    });

    test('an empty body embeds nothing', () {
      expect(
        InlineAttachment.isInline(
          contentId: '<logo@corp>',
          fileName: 'logo.png',
          htmlBody: '',
        ),
        isFalse,
      );
    });

    test('a bare filename mentioned outside a cid: ref is not a reference', () {
      // "see Sunset.jpg attached" must not hide the photo.
      expect(
        InlineAttachment.isInline(
          contentId: null,
          fileName: 'Sunset.jpg',
          htmlBody: '<p>I have attached Sunset.jpg for you</p>',
        ),
        isFalse,
      );
    });

    test('no signals at all means a real attachment', () {
      expect(InlineAttachment.isInline(fileName: 'notes.txt'), isFalse);
    });
  });
}
