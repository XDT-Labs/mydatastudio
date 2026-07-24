import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:pointycastle/export.dart' as pc;

/// App-level credential vault (AUDIT M2).
///
/// Envelope encryption with two tiers so that changing the user's password does
/// **not** re-encrypt every secret:
///   - A random 32-byte **DEK** (Data Encryption Key) actually encrypts secrets
///     with AES-256-GCM. It is generated once and never changes.
///   - A **KEK** (Key Encryption Key) is derived from the user's password via
///     Argon2id and only *wraps* (encrypts) the DEK. A password change re-wraps
///     the DEK — a few hundred bytes — instead of touching any ciphertext.
///
/// The wrapped DEK + KDF parameters live in a small descriptor (persisted as
/// `<storage>/keys/vault.json` by the caller), which travels with the storage
/// folder — no OS keychain, so behaviour is identical on macOS/Windows/Linux and
/// the crypto (pure Dart) also runs inside background isolates. The DEK is held
/// in memory only, for the session, and is passed to worker isolates via their
/// spawn args (the same pattern as the aiserver bearer token).
///
/// This class is deliberately free of Flutter and dart:io imports so it is unit
/// testable and usable from any isolate. File persistence is the caller's job.
class SecureVault {
  SecureVault._(this._dek);

  /// Reconstruct a vault from a DEK handed to a worker isolate. The DEK is the
  /// unwrapped key — never persist it; it lives only in memory.
  factory SecureVault.fromDek(Uint8List dek) {
    if (dek.length != _dekLen) {
      throw ArgumentError('DEK must be $_dekLen bytes, got ${dek.length}');
    }
    return SecureVault._(Uint8List.fromList(dek));
  }

  final Uint8List _dek;

  // --- format / KDF constants ------------------------------------------------

  static const int _dekLen = 32; // AES-256
  static const int _saltLen = 16;
  static const int _ivLen = 12; // GCM standard nonce (encrypt uses a 128-bit tag)

  /// Prefix marking a value as vault-encrypted, so migration can tell an
  /// already-encrypted value apart from a legacy plaintext one.
  static const String blobPrefix = 'v1:';

  /// Current descriptor schema version.
  static const int descriptorVersion = 1;

  // Argon2id work factors. Stored in the descriptor, so these can be raised for
  // new vaults later without breaking the ability to unlock existing ones.
  static const int _kdfIterations = 3;
  static const int _kdfMemoryKib = 32768; // 32 MiB (above OWASP argon2id minimum)
  static const int _kdfLanes = 1; // single-threaded derivation

  static final Random _rng = Random.secure();

  // --- lifecycle -------------------------------------------------------------

  /// First-time setup: mint a fresh DEK and return the unlocked vault together
  /// with the descriptor to persist. The password never leaves this call.
  static ({SecureVault vault, Map<String, dynamic> descriptor}) create(
    String password,
  ) {
    final vault = SecureVault._(_randomBytes(_dekLen));
    return (vault: vault, descriptor: vault._wrap(password));
  }

  /// Unlock an existing descriptor with the password. Throws
  /// [WrongPasswordException] if the password (or descriptor) is wrong — the
  /// GCM tag on the wrapped DEK is itself the password check.
  static SecureVault unlock(String password, Map<String, dynamic> descriptor) {
    final kdf = (descriptor['kdf'] as Map).cast<String, dynamic>();
    final kek = _deriveKek(
      password,
      base64.decode(kdf['salt'] as String),
      iterations: kdf['iterations'] as int,
      memoryKib: kdf['memoryKib'] as int,
      lanes: kdf['lanes'] as int,
    );
    final wrapped = base64.decode(descriptor['wrappedDek'] as String);
    try {
      final dek = _gcmDecrypt(kek, wrapped);
      return SecureVault._(dek);
    } catch (_) {
      throw WrongPasswordException();
    }
  }

  /// Re-wrap the *same* DEK under a new password and return the new descriptor
  /// to persist. Requires the vault to already be unlocked (it is — this is an
  /// instance method), which is why changing the password needs the current one.
  Map<String, dynamic> rewrap(String newPassword) => _wrap(newPassword);

  /// The unwrapped DEK, for handing to a worker isolate via its spawn args.
  Uint8List get dek => Uint8List.fromList(_dek);

  Map<String, dynamic> _wrap(String password) {
    final salt = _randomBytes(_saltLen);
    final kek = _deriveKek(
      password,
      salt,
      iterations: _kdfIterations,
      memoryKib: _kdfMemoryKib,
      lanes: _kdfLanes,
    );
    return {
      'version': descriptorVersion,
      'kdf': {
        'algo': 'argon2id',
        'salt': base64.encode(salt),
        'iterations': _kdfIterations,
        'memoryKib': _kdfMemoryKib,
        'lanes': _kdfLanes,
      },
      'wrappedDek': base64.encode(_gcmEncrypt(kek, _dek)),
    };
  }

  // --- value encryption ------------------------------------------------------

  /// Encrypt a UTF-8 string to a `v1:<base64>` blob suitable for a DB column.
  String encryptString(String plaintext) =>
      blobPrefix + base64.encode(encryptBytes(utf8.encode(plaintext)));

  /// Decrypt a `v1:<base64>` blob produced by [encryptString]. Throws
  /// [FormatException] if the value isn't vault-encrypted (caller can then treat
  /// it as legacy plaintext during migration).
  String decryptString(String blob) {
    if (!isEncrypted(blob)) {
      throw const FormatException('Not a vault-encrypted value');
    }
    return utf8.decode(decryptBytes(base64.decode(blob.substring(blobPrefix.length))));
  }

  /// AES-256-GCM encrypt with a fresh random nonce; output is `iv || ct+tag`.
  Uint8List encryptBytes(List<int> data) {
    final iv = _randomBytes(_ivLen);
    final ct = _gcmEncryptWithIv(_dek, iv, Uint8List.fromList(data));
    return Uint8List.fromList([...iv, ...ct]);
  }

  /// Inverse of [encryptBytes]. Throws if the ciphertext was tampered with (the
  /// GCM tag fails to verify).
  Uint8List decryptBytes(Uint8List blob) {
    if (blob.length < _ivLen) {
      throw const FormatException('Ciphertext too short');
    }
    return _gcmDecryptWithIv(
      _dek,
      Uint8List.sublistView(blob, 0, _ivLen),
      Uint8List.sublistView(blob, _ivLen),
    );
  }

  /// Whether [value] is a vault-encrypted blob (vs. legacy plaintext).
  static bool isEncrypted(String value) => value.startsWith(blobPrefix);

  // --- primitives ------------------------------------------------------------

  static Uint8List _randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

  static Uint8List _deriveKek(
    String password,
    List<int> salt, {
    required int iterations,
    required int memoryKib,
    required int lanes,
  }) {
    final params = pc.Argon2Parameters(
      pc.Argon2Parameters.ARGON2_id,
      Uint8List.fromList(salt),
      desiredKeyLength: _dekLen,
      iterations: iterations,
      memory: memoryKib,
      lanes: lanes,
    );
    final gen = pc.Argon2BytesGenerator()..init(params);
    final out = Uint8List(_dekLen);
    gen.deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
    return out;
  }

  /// Wrap helper: GCM-encrypt [plaintext] under [key] with a fresh nonce,
  /// returning `iv || ct+tag`.
  static Uint8List _gcmEncrypt(Uint8List key, Uint8List plaintext) {
    final iv = _randomBytes(_ivLen);
    return Uint8List.fromList([...iv, ..._gcmEncryptWithIv(key, iv, plaintext)]);
  }

  static Uint8List _gcmDecrypt(Uint8List key, Uint8List blob) =>
      _gcmDecryptWithIv(
        key,
        Uint8List.sublistView(blob, 0, _ivLen),
        Uint8List.sublistView(blob, _ivLen),
      );

  static Uint8List _gcmEncryptWithIv(Uint8List key, Uint8List iv, Uint8List plaintext) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    return Uint8List.fromList(encrypter.encryptBytes(plaintext, iv: enc.IV(iv)).bytes);
  }

  static Uint8List _gcmDecryptWithIv(Uint8List key, Uint8List iv, Uint8List ct) {
    final encrypter = enc.Encrypter(enc.AES(enc.Key(key), mode: enc.AESMode.gcm));
    return Uint8List.fromList(
      encrypter.decryptBytes(enc.Encrypted(Uint8List.fromList(ct)), iv: enc.IV(iv)),
    );
  }
}

/// Thrown by [SecureVault.unlock] when the password (or descriptor) is wrong.
class WrongPasswordException implements Exception {
  @override
  String toString() => 'WrongPasswordException: could not unlock the vault';
}
