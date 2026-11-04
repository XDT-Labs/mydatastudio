import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/credential_codec.dart';

/// A scanner isolate refreshing an Outlook token must change only the token
/// columns, and must store them encrypted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CollectionRepository.updateOAuthTokens', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late CollectionRepository repo;

    setUp(() async {
      CredentialCodec.installIsolateVault(Uint8List.fromList(
        List<int>.generate(32, (i) => i),
      ));
      tempDir = await io.Directory.systemTemp.createTemp('mds_oauthtokens_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);
      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      repo = CollectionRepository(databaseManager.database!);
      await repo.addCollection(
        Collection(
          id: 'c1',
          name: 'me@outlook.com',
          path: 'me@outlook.com',
          type: 'email',
          scanner: 'email.imap',
          scanStatus: 'scanning',
          needsReAuth: false,
          emailProviderId: 'outlook',
        ),
      );
    });

    tearDown(() async {
      CredentialCodec.clearIsolateVault();
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    // The Yandex activation window is measured from this timestamp.
    test('addCollection stamps date_created when none is given', () async {
      final c = (await repo.collectionById('c1'))!;
      expect(
        DateTime.now().difference(c.dateCreated!).inMinutes.abs(),
        lessThan(1),
      );
    });

    test('updates the three token columns and nothing else', () async {
      final expiry = DateTime.utc(2026, 5, 1, 13);
      await repo.updateOAuthTokens(
        'c1',
        accessToken: 'new-at',
        refreshToken: 'new-rt',
        expiration: expiry,
      );

      final c = (await repo.collectionById('c1'))!;
      expect(c.accessToken, 'new-at'); // decrypted on read
      expect(c.refreshToken, 'new-rt');
      expect(c.expiration!.toUtc(), expiry);
      expect(c.scanStatus, 'scanning');
      expect(c.emailProviderId, 'outlook');

      final raw = await databaseManager.database!.select(
        'SELECT access_token, refresh_token FROM collections WHERE id = ?',
        ['c1'],
      );
      expect(raw.first['access_token'], isNot('new-at'));
      expect(raw.first['refresh_token'], isNot('new-rt'));
    });
  });
}
