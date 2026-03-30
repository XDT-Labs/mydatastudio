import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('JWT parsing logic (as used in LoginProviderExtension)', () {
    test('correctly decodes a mock Azure AD id_token payload', () {
      // Mock payload with base64url encoding (no padding)
      final claims = {
        'email': 'user@outlook.com',
        'oid': 'user-oid-123',
        'sub': 'subject-123',
        'preferred_username': 'user@outlook.com'
      };
      
      final payloadString = jsonEncode(claims);
      final encodedPayload = base64Url.encode(utf8.encode(payloadString)).replaceAll('=', ''); // remove padding to test normalization

      // Logic from handleOutlookMail:
      final payload = encodedPayload; // already just the payload part
      final normalizedPayload = base64Url.normalize(payload);
      final decodedPayload = utf8.decode(base64Url.decode(normalizedPayload));
      final parsedClaims = jsonDecode(decodedPayload) as Map<String, dynamic>;

      expect(parsedClaims['email'], 'user@outlook.com');
      expect(parsedClaims['oid'], 'user-oid-123');
    });

    test('correctly extracts email from preferred_username if email is missing', () {
      final claims = {
        'preferred_username': 'user-alias@outlook.com',
        'sub': 'subject-123',
      };
      
      final payloadString = jsonEncode(claims);
      final encodedPayload = base64Url.encode(utf8.encode(payloadString));

      final decodedPayload = utf8.decode(base64Url.decode(base64Url.normalize(encodedPayload)));
      final parsedClaims = jsonDecode(decodedPayload) as Map<String, dynamic>;

      final email = parsedClaims['email'] ?? parsedClaims['preferred_username'] ?? parsedClaims['upn'] as String?;
      expect(email, 'user-alias@outlook.com');
    });

    test('prefers @outlook.com preferred_username over gmail email claim', () {
      final claims = {
        'email': 'mikenimer@gmail.com',
        'preferred_username': 'mikenimer@outlook.com',
        'sub': 'subject-123',
      };
      
      final payloadString = jsonEncode(claims);
      final encodedPayload = base64Url.encode(utf8.encode(payloadString));

      final decodedPayload = utf8.decode(base64Url.decode(base64Url.normalize(encodedPayload)));
      final parsedClaims = jsonDecode(decodedPayload) as Map<String, dynamic>;

      // Logic from handleOutlookMail:
      final preferred = parsedClaims['preferred_username'] as String?;
      final mail = parsedClaims['email'] as String?;
      final upn = parsedClaims['upn'] as String?;

      var selectedEmail = preferred ?? mail ?? upn;

      if (selectedEmail != null && (selectedEmail.endsWith('@gmail.com') || selectedEmail.endsWith('@yahoo.com'))) {
        if (preferred != null && !preferred.endsWith('@gmail.com') && !preferred.endsWith('@yahoo.com')) {
          selectedEmail = preferred;
        } else if (upn != null && !upn.endsWith('@gmail.com') && !upn.endsWith('@yahoo.com')) {
          selectedEmail = upn;
        }
      }

      expect(selectedEmail, 'mikenimer@outlook.com');
    });
  });
}
