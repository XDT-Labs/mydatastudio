import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/services/secure_vault.dart';
import 'package:mydatastudio/services/vault_manager.dart';

/// Tests for the encrypt-on-write / decrypt-on-read boundary (AUDIT M2 phase
/// 3/4). Each test pins a rule the repositories and isolate workers rely on:
/// round-trip fidelity, null/empty pass-through, idempotent writes, and — the
/// security-critical one — no plaintext fallback when the vault is locked.
void main() {
  // Give the codec a deterministic DEK-backed vault (the worker-isolate path),
  // so tests never depend on the process-wide VaultManager singleton.
  setUp(() {
    final created = SecureVault.create('pw');
    CredentialCodec.installIsolateVault(created.vault.dek);
  });

  tearDown(() {
    CredentialCodec.resetForTesting();
    VaultManager.instance.lock();
  });

  test('round-trips a secret through encrypt/decrypt', () {
    const secret = 'ya29.super-secret-access-token';
    final blob = CredentialCodec.encrypt(secret);
    expect(blob, isNotNull);
    expect(SecureVault.isEncrypted(blob!), isTrue,
        reason: 'stored form must be a v1: blob, never plaintext');
    expect(blob, isNot(contains(secret)));
    expect(CredentialCodec.decrypt(blob), secret);
  });

  test('null and empty pass through unchanged (nothing to protect)', () {
    expect(CredentialCodec.encrypt(null), isNull);
    expect(CredentialCodec.encrypt(''), '');
    expect(CredentialCodec.decrypt(null), isNull);
    expect(CredentialCodec.decrypt(''), '');
  });

  test('encrypt is idempotent — an already-encrypted value is not re-wrapped',
      () {
    final once = CredentialCodec.encrypt('secret')!;
    final twice = CredentialCodec.encrypt(once)!;
    expect(twice, once, reason: 're-encrypting a v1: blob must be a no-op');
    expect(CredentialCodec.decrypt(twice), 'secret');
  });

  test('each encryption uses a fresh nonce (ciphertexts differ)', () {
    final a = CredentialCodec.encrypt('secret')!;
    final b = CredentialCodec.encrypt('secret')!;
    expect(a, isNot(b));
    expect(CredentialCodec.decrypt(a), 'secret');
    expect(CredentialCodec.decrypt(b), 'secret');
  });

  test('no plaintext fallback: decrypting a non-v1 value throws', () {
    // A value that bypassed the codec must never be emitted as-is.
    expect(() => CredentialCodec.decrypt('plaintext-token'),
        throwsA(isA<CredentialFormatException>()));
  });

  test('locked vault fails loudly on encrypt of a real secret', () {
    CredentialCodec.resetForTesting();
    VaultManager.instance.lock();
    expect(CredentialCodec.isUnlocked, isFalse);
    expect(() => CredentialCodec.encrypt('secret'),
        throwsA(isA<VaultLockedException>()));
    // ...but null/empty still pass through without a key (nothing to protect).
    expect(CredentialCodec.encrypt(null), isNull);
    expect(CredentialCodec.encrypt(''), '');
  });

  test('locked vault fails loudly on decrypt of a v1 blob', () {
    final blob = CredentialCodec.encrypt('secret')!;
    CredentialCodec.resetForTesting();
    VaultManager.instance.lock();
    expect(() => CredentialCodec.decrypt(blob),
        throwsA(isA<VaultLockedException>()));
  });

  test('a value encrypted under one DEK cannot be read under another', () {
    final blob = CredentialCodec.encrypt('secret')!;
    // Swap in an unrelated DEK — decryption must fail (GCM tag mismatch),
    // never silently return garbage.
    CredentialCodec.installIsolateVault(SecureVault.create('other').vault.dek);
    expect(() => CredentialCodec.decrypt(blob), throwsA(anything));
  });
}
