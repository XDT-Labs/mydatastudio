import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/secure_vault.dart';

/// Tests for the credential vault (AUDIT M2).
///
/// The point of the vault is: secrets are unreadable without the password, a
/// wrong password is rejected, tampering is detected, and — critically — a
/// password change must NOT invalidate already-encrypted data (the DEK is
/// preserved, only its wrapping changes). Each test encodes one of those
/// guarantees so it fails if the crypto contract regresses.
void main() {
  group('SecureVault value encryption', () {
    late SecureVault vault;

    setUp(() {
      vault = SecureVault.create('correct horse battery staple').vault;
    });

    test('round-trips a string', () {
      final blob = vault.encryptString('ya29.a-secret-refresh-token');
      expect(SecureVault.isEncrypted(blob), isTrue);
      expect(blob, isNot(contains('secret'))); // ciphertext, not plaintext
      expect(vault.decryptString(blob), 'ya29.a-secret-refresh-token');
    });

    test('round-trips raw bytes', () {
      final data = Uint8List.fromList(List<int>.generate(500, (i) => i % 256));
      expect(vault.decryptBytes(vault.encryptBytes(data)), data);
    });

    test('uses a fresh nonce each time (same plaintext -> different ciphertext)', () {
      final a = vault.encryptString('same');
      final b = vault.encryptString('same');
      expect(a, isNot(equals(b)));
      expect(vault.decryptString(a), 'same');
      expect(vault.decryptString(b), 'same');
    });

    test('rejects a tampered ciphertext (GCM auth)', () {
      final blob = vault.encryptBytes(utf8.encode('important'));
      blob[blob.length - 1] ^= 0x01; // flip a bit in the tag/ciphertext
      expect(() => vault.decryptBytes(blob), throwsA(anything));
    });

    test('decryptString rejects a non-vault (legacy plaintext) value', () {
      expect(() => vault.decryptString('plain-text-token'),
          throwsA(isA<FormatException>()));
      expect(SecureVault.isEncrypted('plain-text-token'), isFalse);
    });
  });

  group('SecureVault lock/unlock', () {
    test('unlock with the correct password recovers the same DEK', () {
      final created = SecureVault.create('pw-123');
      final blob = created.vault.encryptString('token-abc');

      final reopened = SecureVault.unlock('pw-123', created.descriptor);
      // A different vault instance can only decrypt this if it holds the same DEK.
      expect(reopened.decryptString(blob), 'token-abc');
    });

    test('unlock with a wrong password throws WrongPasswordException', () {
      final created = SecureVault.create('right-pw');
      expect(() => SecureVault.unlock('wrong-pw', created.descriptor),
          throwsA(isA<WrongPasswordException>()));
    });

    test('descriptor persists as JSON and reloads', () {
      final created = SecureVault.create('pw');
      final blob = created.vault.encryptString('v');
      final json = jsonDecode(jsonEncode(created.descriptor)) as Map<String, dynamic>;
      expect(SecureVault.unlock('pw', json).decryptString(blob), 'v');
    });

    test('descriptor contains no plaintext key material', () {
      final created = SecureVault.create('pw');
      final dekB64 = base64.encode(created.vault.dek);
      final serialized = jsonEncode(created.descriptor);
      expect(serialized.contains(dekB64), isFalse);
      expect(serialized.contains('pw'), isFalse);
    });
  });

  group('SecureVault password change (rewrap)', () {
    test('re-wrapping keeps existing ciphertext decryptable under the new password', () {
      final created = SecureVault.create('old-pw');
      final blob = created.vault.encryptString('long-lived-token');

      // Change password: re-wrap the SAME dek — no data is re-encrypted.
      final newDescriptor = created.vault.rewrap('new-pw');

      final reopened = SecureVault.unlock('new-pw', newDescriptor);
      expect(reopened.decryptString(blob), 'long-lived-token');
    });

    test('the old password no longer unlocks the re-wrapped descriptor', () {
      final created = SecureVault.create('old-pw');
      final newDescriptor = created.vault.rewrap('new-pw');
      expect(() => SecureVault.unlock('old-pw', newDescriptor),
          throwsA(isA<WrongPasswordException>()));
    });
  });

  group('SecureVault.fromDek (isolate hand-off)', () {
    test('a vault built from the exported DEK decrypts the origin vault values', () {
      final created = SecureVault.create('pw');
      final blob = created.vault.encryptString('isolate-secret');

      // Simulate passing vault.dek into a worker isolate via spawn args.
      final inIsolate = SecureVault.fromDek(created.vault.dek);
      expect(inIsolate.decryptString(blob), 'isolate-secret');
    });

    test('rejects a DEK of the wrong length', () {
      expect(() => SecureVault.fromDek(Uint8List(16)), throwsArgumentError);
    });
  });
}
