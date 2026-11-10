import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/email_body_preparer.dart';

import '../../../helpers/file_fixture.dart';

/// Every platform's renderer trusts this output, and on Linux the CSP isn't
/// even read, so what gets stripped here is the real line of defence.
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('email_preparer_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<PreparedEmailBody> prepare({
    String? html,
    String? plain,
    files = const <Never>[],
  }) => EmailBodyPreparer.prepare(
    htmlBody: html,
    plainBody: plain,
    attachments: List.from(files),
  );

  test('HTML mail loses active content and gains the CSP', () async {
    final body = await prepare(
      html:
          '<html><head><meta http-equiv="refresh" content="0;url=https://evil">'
          '</head><body onload="steal()"><script>steal()</script>'
          '<a href="javascript:steal()">x</a><iframe src="https://evil"></iframe>'
          '<p>Hello</p></body></html>',
    );

    expect(body.plainText, isNull);
    expect(body.html, contains('<p>Hello</p>'));
    expect(body.html, contains("default-src 'none'"));
    for (final active in [
      '<script',
      'onload',
      'javascript:',
      '<iframe',
      'refresh',
    ]) {
      expect(body.html, isNot(contains(active)));
    }
  });

  test('embedded images become data URIs and leave the strip', () async {
    final png = File('${dir.path}/logo.png')..writeAsBytesSync([1, 2, 3]);
    final attachment = makeTestFile(
      id: 'a1',
      name: 'logo.png',
      path: png.path,
      contentId: 'logo@host',
    );

    final body = await prepare(
      html: '<img src="cid:logo@host"><img src="cid:gone@host">',
      files: [attachment],
    );

    expect(
      body.html,
      contains('data:image/png;base64,${base64Encode([1, 2, 3])}'),
    );
    expect(body.inlinedAttachmentIds, {'a1'});
    // An unresolved reference stays visible as broken rather than vanishing.
    expect(body.html, contains('cid:gone@host'));
  });

  test('an attachment over the inline limit stays in the strip', () async {
    final big = File('${dir.path}/big.png');
    final handle = big.openSync(mode: FileMode.write);
    handle.truncateSync(8 * 1024 * 1024 + 1);
    handle.closeSync();

    final body = await prepare(
      html: '<img src="cid:big@host">',
      files: [
        makeTestFile(
          id: 'b',
          name: 'big.png',
          path: big.path,
          contentId: 'big@host',
        ),
      ],
    );

    expect(body.inlinedAttachmentIds, isEmpty);
    expect(body.html, contains('cid:big@host'));
  });

  test('plain mail keeps its raw text and is escaped in the HTML', () async {
    const raw = 'line one\n<b>not bold</b>';
    final body = await prepare(plain: raw);

    expect(body.plainText, raw);
    expect(body.html, contains('&lt;b&gt;not bold&lt;/b&gt;'));
    expect(body.html, contains("default-src 'none'"));
  });

  test('a whitespace-only HTML part falls back to the plain text', () async {
    final body = await prepare(html: '  \n ', plain: 'real text');
    expect(body.plainText, 'real text');
  });

  test('a message with no body says so', () async {
    final body = await prepare();
    expect(body.plainText, '(No content)');
    expect(body.html, contains('(No content)'));
  });
}
