import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/secure_vault.dart';
import 'package:mydatastudio/services/vault_manager.dart';
import 'package:path/path.dart' as p;

/// Tests for the vault lifecycle + on-disk descriptor (AUDIT M2).
///
/// Verifies the state machine the login flow will drive: create-on-first-run,
/// unlock (right vs wrong password), password change without losing data, and
/// lock. Each test pins a behaviour the auth wiring depends on.
void main() {
  late Directory tmp;
  late String keysDir;
  late VaultManager vm;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vault_mgr_test');
    keysDir = p.join(tmp.path, 'keys');
    vm = VaultManager.forTesting();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('vaultExists is false before setup, true after', () async {
    expect(await vm.vaultExists(keysDir), isFalse);
    await vm.createAndUnlock(keysDir, 'pw');
    expect(await vm.vaultExists(keysDir), isTrue);
    expect(File(vm.vaultPath(keysDir)).existsSync(), isTrue);
  });

  test('createAndUnlock leaves the vault unlocked and usable', () async {
    expect(vm.isUnlocked, isFalse);
    await vm.createAndUnlock(keysDir, 'pw');
    expect(vm.isUnlocked, isTrue);
    expect(vm.unlocked.value, isTrue);
    expect(vm.dek, isNotNull);

    final blob = vm.vault!.encryptString('secret');
    expect(vm.vault!.decryptString(blob), 'secret');
  });

  test('descriptor on disk is valid JSON with no plaintext key', () async {
    await vm.createAndUnlock(keysDir, 'pw');
    final raw = File(vm.vaultPath(keysDir)).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(json['wrappedDek'], isA<String>());
    expect(raw.contains('pw'), isFalse);
  });

  test('unlock with the correct password re-opens across a fresh manager', () async {
    await vm.createAndUnlock(keysDir, 'pw');
    final blob = vm.vault!.encryptString('token');

    // Simulate a new app launch: fresh manager, only the on-disk descriptor.
    final vm2 = VaultManager.forTesting();
    await vm2.unlock(keysDir, 'pw');
    expect(vm2.vault!.decryptString(blob), 'token');
  });

  test('unlock with a wrong password throws and leaves it locked', () async {
    await vm.createAndUnlock(keysDir, 'pw');
    final vm2 = VaultManager.forTesting();
    await expectLater(
      vm2.unlock(keysDir, 'nope'),
      throwsA(isA<WrongPasswordException>()),
    );
    expect(vm2.isUnlocked, isFalse);
  });

  test('unlock without a descriptor throws StateError', () async {
    await expectLater(vm.unlock(keysDir, 'pw'), throwsA(isA<StateError>()));
  });

  test('changePassword keeps existing ciphertext and rejects the old password',
      () async {
    await vm.createAndUnlock(keysDir, 'old');
    final blob = vm.vault!.encryptString('long-lived');

    await vm.changePassword(keysDir, 'new');

    final reopened = VaultManager.forTesting();
    await reopened.unlock(keysDir, 'new');
    expect(reopened.vault!.decryptString(blob), 'long-lived');

    await expectLater(
      VaultManager.forTesting().unlock(keysDir, 'old'),
      throwsA(isA<WrongPasswordException>()),
    );
  });

  test('changePassword on a locked vault throws', () async {
    await expectLater(
      vm.changePassword(keysDir, 'new'),
      throwsA(isA<StateError>()),
    );
  });

  test('lock forgets the DEK', () async {
    await vm.createAndUnlock(keysDir, 'pw');
    vm.lock();
    expect(vm.isUnlocked, isFalse);
    expect(vm.dek, isNull);
    expect(vm.unlocked.value, isFalse);
  });
}
