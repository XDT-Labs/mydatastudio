import 'dart:io';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:mydatastudio/services/credential_codec.dart';

class UserRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase? db;

  UserRepository(this.db);

  Future<List<AppUser>> users() async {
    if (db == null) return [];
    final rows = await db!.select("SELECT * FROM app_users");
    return rows.map((row) => AppUser.fromDbMap(row)).toList();
  }

  Future<AppUser?> userExists() async {
    if (db == null) return null;
    final rows = await db!.select("SELECT * FROM app_users LIMIT 1");
    if (rows.isEmpty) return null;
    return AppUser.fromDbMap(rows.first);
  }

  /// Search for user by password that has been hashed with a PBKDF2 algorithm
  Future<AppUser?> user(String password) async {
    if (db == null) return null;
    final rows = await db!.select(
      "SELECT * FROM app_users WHERE password = ? LIMIT 1",
      [password],
    );
    if (rows.isEmpty) return null;

    final user = AppUser.fromDbMap(rows.first);

    // The storage location is not stored per-user: config.json (via
    // MainApp.appDataDirectory) is the single source of truth, so a moved
    // storage location is always picked up here, restart or not.
    final currentStoragePath = MainApp.appDataDirectory.valueOrNull;
    if (currentStoragePath == null || currentStoragePath.isEmpty) {
      throw Exception("No app data directory is configured.");
    }
    String keyDir = '$currentStoragePath${Platform.pathSeparator}keys';
    String publicFilePath = '$keyDir/public.pem';
    String privateFilePath = '$keyDir/private.pem';
    if (!File(publicFilePath).existsSync() &&
        !File(privateFilePath).existsSync()) {
      throw Exception("Keys not found at $keyDir. Stopping application.");
    }

    user.publicKey = File(publicFilePath).readAsStringSync();
    // The private key is stored encrypted at rest (AUDIT M2 phase 4). The login
    // flow unlocks the vault before this read; a locked/wrong vault fails loudly
    // rather than handing back ciphertext. Public key stays cleartext.
    user.privateKey =
        CredentialCodec.decrypt(File(privateFilePath).readAsStringSync());
    return user;
  }

  /// Save user to database
  /// Save public/private keys to /key folder
  Future<AppUser?> saveUser(AppUser user) async {
    String keyDir = '${user.localStoragePath}${Platform.pathSeparator}keys';
    String publicFilePath = '$keyDir/public.pem';
    String privateFilePath = '$keyDir/private.pem';
    if (!File(publicFilePath).existsSync() &&
        !File(privateFilePath).existsSync()) {
      if (!Directory(keyDir).existsSync()) {
        Directory(keyDir).createSync(recursive: true);
      }
      if (user.publicKey != null) {
        File(publicFilePath).writeAsStringSync(user.publicKey!);
      }
      if (user.privateKey != null) {
        // Encrypt the private key at rest with the vault DEK (AUDIT M2 phase 4).
        // At setup the vault is created just before saveUser; a locked vault
        // fails loudly instead of writing the key in cleartext.
        File(privateFilePath)
            .writeAsStringSync(CredentialCodec.encrypt(user.privateKey!)!);
      }
    }

    if (db == null) {
      throw Exception("Database not initialized");
    }

    await db!.execute(
      "INSERT INTO app_users (id, name, email, password) "
      "VALUES (?, ?, ?, ?) "
      "ON CONFLICT(id) DO UPDATE SET "
      "name = excluded.name, "
      "email = excluded.email, "
      "password = excluded.password",
      [user.id, user.name, user.email, user.password],
    );

    return user;
  }
}
