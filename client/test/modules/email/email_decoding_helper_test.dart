import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/email_decoding_helper.dart';

void main() {
  group('EmailDecodingHelper.decodeQuotedPrintable', () {
    test('decodes standard quoted printable sequences', () {
      const qp = 'Hello=20World=21=3DTest';
      final decoded = EmailDecodingHelper.decodeQuotedPrintable(qp.codeUnits);
      expect(decoded, equals('Hello World!=Test'));
    });

    test('handles soft line breaks (=\\r\\n and =\\n)', () {
      const qp = 'Line 1=\r\nLine 2=\nLine 3';
      final decoded = EmailDecodingHelper.decodeQuotedPrintable(qp.codeUnits);
      expect(decoded, equals('Line 1Line 2Line 3'));
    });

    test('handles malformed quoted printable sequences without throwing', () {
      const malformed = 'Price: =G1 or =3 or = at end =';
      final decoded = EmailDecodingHelper.decodeQuotedPrintable(malformed.codeUnits);
      expect(decoded, equals('Price: =G1 or =3 or = at end ='));
    });

    test('handles lowercase hex digits', () {
      const qp = 'Hello=20world=3dtest';
      final decoded = EmailDecodingHelper.decodeQuotedPrintable(qp.codeUnits);
      expect(decoded, equals('Hello world=test'));
    });
  });

  group('EmailDecodingHelper.safeBase64Decode', () {
    test('decodes standard base64url data', () {
      final encoded = base64Url.encode(utf8.encode('Hello World'));
      final decodedBytes = EmailDecodingHelper.safeBase64Decode(encoded);
      expect(decodedBytes, isNotNull);
      expect(utf8.decode(decodedBytes!), equals('Hello World'));
    });

    test('decodes unpadded base64url data', () {
      final unpadded = base64Url.encode(utf8.encode('Hello World')).replaceAll('=', '');
      final decodedBytes = EmailDecodingHelper.safeBase64Decode(unpadded);
      expect(decodedBytes, isNotNull);
      expect(utf8.decode(decodedBytes!), equals('Hello World'));
    });

    test('returns null on invalid base64 input', () {
      final decoded = EmailDecodingHelper.safeBase64Decode('!!!NotBase64!!!');
      expect(decoded, isNull);
    });
  });
}
