import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/modules/email/widgets/email_details.dart';

/// An HTML mail body points at its embedded images with `cid:` tokens. Nothing
/// resolves those on its own — the attachments were extracted to disk and the
/// WebView gets a bare HTML string — so every one that fails to match here is a
/// broken image in the reading pane.
void main() {
  model.File buildAttachment({
    required String id,
    required String name,
    String? contentId,
  }) {
    return model.File(
      id: id,
      name: name,
      path: '/tmp/$name',
      parent: '/tmp',
      dateCreated: DateTime(2024, 1, 1),
      dateLastModified: DateTime(2024, 1, 1),
      collectionId: 'collection-1',
      contentType: 'image',
      size: 1024,
      isDeleted: false,
      contentId: contentId,
    );
  }

  group('CidResolver.referencesIn', () {
    test('finds refs in quoted, unquoted and CSS forms', () {
      const html = '''
        <img src="cid:one@host">
        <img src='cid:two@host'/>
        <img src=cid:three@host >
        <div style="background: url(cid:four@host)"></div>
      ''';

      expect(CidResolver.referencesIn(html), {
        'one@host',
        'two@host',
        'three@host',
        'four@host',
      });
    });

    test('does not drag the closing quote or bracket into the token', () {
      expect(CidResolver.referencesIn('<img src="cid:a@b">'), {'a@b'});
      expect(CidResolver.referencesIn('url(cid:a@b)'), {'a@b'});
    });

    test('returns nothing for a body with no embedded images', () {
      expect(
        CidResolver.referencesIn('<p>Hello <a href="https://x/">link</a></p>'),
        isEmpty,
      );
    });
  });

  group('CidResolver.match', () {
    test('matches on content id first', () {
      final byId = buildAttachment(
        id: 'a',
        name: 'logo.png',
        contentId: 'image001.png@01CC3097.BF0BAC70',
      );
      // Same filename, no content id — the authoritative match must win.
      final decoy = buildAttachment(id: 'b', name: 'image001.png');

      expect(
        CidResolver.match('image001.png@01CC3097.BF0BAC70', [decoy, byId]),
        same(byId),
      );
    });

    test('falls back to the filename in the cid for archives imported before '
        'content ids were captured', () {
      // No contentId at all: exactly what a PST imported by the older client
      // left in the database, and it must still render rather than requiring
      // a full re-import.
      final legacy = buildAttachment(id: 'a', name: 'image001.png');

      expect(
        CidResolver.match('image001.png@01CC3097.BF0BAC70', [legacy]),
        same(legacy),
      );
    });

    test('matches a cid that is a bare filename', () {
      final file = buildAttachment(id: 'a', name: 'chart.gif');
      expect(CidResolver.match('chart.gif', [file]), same(file));
    });

    test('matches a content id whose casing differs from the cid ref', () {
      // Senders are inconsistent about Content-ID casing — InlineAttachment
      // already matches case-insensitively when deciding isInline. If this
      // resolver did not, the scanner would flag the part inline (keeping it
      // out of the attachments strip) while the body failed to resolve it, and
      // the attachment would be reachable from nowhere at all.
      final file = buildAttachment(
        id: 'a',
        name: 'logo.png',
        contentId: 'Image001.PNG@01CC3097.BF0BAC70',
      );

      expect(
        CidResolver.match('image001.png@01cc3097.bf0bac70', [file]),
        same(file),
      );
    });

    test('filename fallback is case-insensitive too', () {
      final file = buildAttachment(id: 'a', name: 'Chart.GIF');
      expect(CidResolver.match('chart.gif@host', [file]), same(file));
    });

    test('returns null when nothing matches, leaving the ref untouched', () {
      final file = buildAttachment(
        id: 'a',
        name: 'invoice.pdf',
        contentId: 'other@host',
      );
      expect(CidResolver.match('missing@host', [file]), isNull);
    });

    test('a plain attachment with no content id is not matched by accident', () {
      // A regular attachment must stay in the attachments strip; matching it
      // against an unrelated cid would both break the image and hide the file.
      final file = buildAttachment(id: 'a', name: 'report.docx');
      expect(CidResolver.match('image001.png@host', [file]), isNull);
    });
  });
}
