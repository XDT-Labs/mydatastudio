import 'dart:io';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/app_user.dart';

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

    String keyDir = '${user.localStoragePath}${Platform.pathSeparator}keys';
    String publicFilePath = '$keyDir/public.pem';
    String privateFilePath = '$keyDir/private.pem';
    if (!File(publicFilePath).existsSync() &&
        !File(privateFilePath).existsSync()) {
      throw Exception("Keys not found at $keyDir. Stopping application.");
    }

    user.publicKey = File(publicFilePath).readAsStringSync();
    user.privateKey = File(privateFilePath).readAsStringSync();
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
        File(privateFilePath).writeAsStringSync(user.privateKey!);
      }
    }

    if (db == null) {
      throw Exception("Database not initialized");
    }

    await db!.execute(
      "INSERT INTO app_users (id, name, email, password, local_storage_path) "
      "VALUES (?, ?, ?, ?, ?) "
      "ON CONFLICT(id) DO UPDATE SET "
      "name = excluded.name, "
      "email = excluded.email, "
      "password = excluded.password, "
      "local_storage_path = excluded.local_storage_path",
      [user.id, user.name, user.email, user.password, user.localStoragePath],
    );

    return user;
  }
}
