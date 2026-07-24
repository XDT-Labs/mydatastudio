import 'package:flutter/foundation.dart';

import 'package:mydatastudio/services/secure_vault.dart';
import 'package:mydatastudio/services/vault_manager.dart';

/// Encrypt-on-write / decrypt-on-read boundary for the secrets stored in the DB
/// and on disk (AUDIT M2 phase 3/4).
///
/// The invariant this enforces: **in-memory model objects always hold plaintext;
/// only persisted bytes (DB columns, `private.pem`) hold `v1:` ciphertext.**
/// Every repository/write site runs its secret fields through [encrypt] on the
/// way to disk and [decrypt] on the way back.
///
/// It resolves its key differently depending on where it runs — the same two
/// contexts the read-site map identified:
///   - **Main isolate**: the unlocked vault from [VaultManager.instance].
///   - **Worker isolate**: a [SecureVault] rebuilt from the DEK handed in through
///     the isolate's spawn args (isolates don't share memory, so the singleton
///     vault is always locked there). Install it once at isolate entry with
///     [installIsolateVault].
///
/// **No plaintext fallback.** If a secret needs protecting or reading but no key
/// is available (vault locked, DEK never threaded in), the operation throws
/// rather than silently persisting or emitting plaintext/ciphertext. Callers on
/// security-critical paths let it propagate (fail the operation loudly); UI
/// display-load paths may catch it and show an empty field.
class CredentialCodec {
  CredentialCodec._();

  static SecureVault? _isolateVault;

  /// Install the DEK-backed vault for the current worker isolate. Call once at
  /// isolate entry with the DEK carried through the spawn args (or pushed over
  /// the control port, as the embedding isolate does). A null/empty DEK is
  /// ignored so a locked vault still fails loudly on first use.
  static void installIsolateVault(Uint8List? dek) {
    if (dek == null || dek.isEmpty) return;
    _isolateVault = SecureVault.fromDek(dek);
  }

  /// The vault to use in this isolate: the DEK-installed one if present,
  /// otherwise the main-isolate [VaultManager] vault. Null when nothing is
  /// unlocked here.
  static SecureVault? get _vault =>
      _isolateVault ?? VaultManager.instance.vault;

  /// Whether a key is available in the current isolate.
  static bool get isUnlocked => _vault != null;

  /// Encrypt a secret for storage. Null/empty values pass through unchanged —
  /// there is nothing to protect and callers store null/empty as-is. An
  /// already-encrypted value passes through so repeated writes stay idempotent.
  ///
  /// Throws [VaultLockedException] when there is a real secret to protect but no
  /// key is available.
  static String? encrypt(String? plaintext) {
    if (plaintext == null || plaintext.isEmpty) return plaintext;
    if (SecureVault.isEncrypted(plaintext)) return plaintext;
    final v = _vault;
    if (v == null) throw VaultLockedException('encrypt a credential');
    return v.encryptString(plaintext);
  }

  /// Decrypt a stored secret. Null/empty values pass through unchanged.
  ///
  /// A non-empty value that is not a `v1:` blob is treated as a defect rather
  /// than legacy plaintext: there is no migration and secrets are encrypted from
  /// their first write (AUDIT M2 phase 2c), so an unencrypted value means it was
  /// written while the vault was locked or by a path that bypassed this codec.
  /// Throws [CredentialFormatException] instead of leaking it.
  ///
  /// Throws [VaultLockedException] when a `v1:` blob is present but no key is
  /// available to read it.
  static String? decrypt(String? stored) {
    if (stored == null || stored.isEmpty) return stored;
    if (!SecureVault.isEncrypted(stored)) {
      throw const CredentialFormatException();
    }
    final v = _vault;
    if (v == null) throw VaultLockedException('decrypt a credential');
    return v.decryptString(stored);
  }

  /// Test hook: drop any isolate-installed vault so tests start from a known,
  /// main-isolate-backed state.
  @visibleForTesting
  static void resetForTesting() => _isolateVault = null;
}

/// Thrown when a credential must be encrypted or decrypted but the vault is
/// locked (or the DEK was never threaded into this isolate).
class VaultLockedException implements Exception {
  VaultLockedException(this.operation);

  /// What was being attempted, for the log/message.
  final String operation;

  @override
  String toString() =>
      'VaultLockedException: cannot $operation — the credential vault is locked';
}

/// Thrown when a stored value that should be a `v1:` vault blob is not — a bug
/// (a secret written outside the codec), never legacy plaintext.
class CredentialFormatException implements Exception {
  const CredentialFormatException();

  @override
  String toString() =>
      'CredentialFormatException: stored credential is not vault-encrypted';
}
