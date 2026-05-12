import 'dart:io';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/app_user.dart';

class UserRepository {
  AppLogger logger = AppLogger(null);
  AppDatabase? db;

  UserRepository(this.db);

  Future<List<AppUser>> users() async {
    return await db?.select(db!.appUsers).get() ?? [];
  }

  Future<AppUser?> userExists() async {
    AppUser? user = await db?.select(db!.appUsers).getSingleOrNull();
    return user;
  }

  /// Search for user by password that has been hashed with a PBKDF2 algorithm
  Future<AppUser?> user(String password) async {
    AppUser? user =
        await (db?.select(db!.appUsers)
          ?..where((e) => e.password.equals(password)))?.getSingleOrNull();

    if (user != null) {
      String keyDir = '${user.localStoragePath}${Platform.pathSeparator}keys';
      String publicFilePath = '$keyDir/public.pem';
      String privateFilePath = '$keyDir/private.pem';
      if (!File(publicFilePath).existsSync() &&
          !File(privateFilePath).existsSync()) {
        throw Exception("Keys not found at $keyDir. Stopping application.");
      }
      // TODO: read/write from app /keys folder
      user.publicKey = File(publicFilePath).readAsStringSync();
      user.privateKey = File(privateFilePath).readAsStringSync();
      return user;
    } else {
      return null;
    }
  }

  /// Save user to database
  /// Save public/private keys to /key folder
  Future<AppUser?> saveUser(AppUser user) async {
    //AppDatabase? db = DatabaseManager.instance.database;
    //Save key into secure storage
    //save keys
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

    //FlutterSecureStorage storage = const FlutterSecureStorage();
    //await storage.write(key: AppConstants.securePassword, value: user.password);

    if (db == null) {
      throw Exception("Database not initialized");
    }

    await db!.into(db!.appUsers).insertOnConflictUpdate(user);

    // TODO: register user, send only the Public Key to server

    return Future(() => user);
  }
}
