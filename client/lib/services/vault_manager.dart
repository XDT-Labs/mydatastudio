import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:mydatastudio/services/secure_vault.dart';

/// Owns the process-wide unlocked [SecureVault] and its on-disk descriptor at
/// `<storage>/keys/vault.json` (AUDIT M2).
///
/// The vault is unlocked once, from the password the user enters at login, and
/// the DEK is then held in memory for the session. Worker isolates receive the
/// DEK via their spawn args (`vaultDek`) rather than reading disk — the same
/// pattern as the aiserver bearer token. There is deliberately no auto-unlock
/// from a stored password (see the M2 plan): if the vault is locked, callers
/// fall back to prompting.
class VaultManager {
  VaultManager._();

  /// Process-wide instance used by the app. Tests can construct their own via
  /// [VaultManager.forTesting].
  static final VaultManager instance = VaultManager._();

  @visibleForTesting
  VaultManager.forTesting();

  static const String vaultFileName = 'vault.json';

  SecureVault? _vault;

  /// The unlocked vault, or null while locked.
  SecureVault? get vault => _vault;

  bool get isUnlocked => _vault != null;

  /// The in-memory DEK to hand to worker isolates, or null while locked.
  Uint8List? get dek => _vault?.dek;

  /// Flips as the vault locks/unlocks so the UI can react (e.g. prompt to unlock).
  final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);

  String vaultPath(String keysDir) => p.join(keysDir, vaultFileName);

  Future<bool> vaultExists(String keysDir) => File(vaultPath(keysDir)).exists();

  /// First-time setup: mint a new vault and persist its descriptor. Overwrites
  /// any existing descriptor, so guard with [vaultExists] before calling.
  Future<void> createAndUnlock(String keysDir, String password) async {
    final created = SecureVault.create(password);
    await _writeDescriptor(keysDir, created.descriptor);
    _setVault(created.vault);
  }

  /// Unlock the existing vault with [password]. Throws [WrongPasswordException]
  /// on a bad password and [StateError] when no descriptor exists.
  Future<void> unlock(String keysDir, String password) async {
    final file = File(vaultPath(keysDir));
    if (!await file.exists()) {
      throw StateError('No vault descriptor at ${file.path}');
    }
    final descriptor =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _setVault(SecureVault.unlock(password, descriptor));
  }

  /// Re-wrap the current DEK under [newPassword] and persist the new descriptor.
  /// Requires an unlocked vault (you need the current password to have unlocked
  /// it first). No credential ciphertext is touched.
  Future<void> changePassword(String keysDir, String newPassword) async {
    final v = _vault;
    if (v == null) throw StateError('Vault is locked');
    await _writeDescriptor(keysDir, v.rewrap(newPassword));
  }

  /// Forget the in-memory DEK (e.g. on logout). The descriptor stays on disk.
  void lock() => _setVault(null);

  void _setVault(SecureVault? v) {
    _vault = v;
    unlocked.value = v != null;
  }

  Future<void> _writeDescriptor(
    String keysDir,
    Map<String, dynamic> descriptor,
  ) async {
    final dir = Directory(keysDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(vaultPath(keysDir));
    await file.writeAsString(jsonEncode(descriptor), flush: true);
    // Best-effort: restrict to owner-only on POSIX. No-op on Windows, where the
    // password-wrap is the primary control and ACLs are defense-in-depth.
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
    }
  }
}
