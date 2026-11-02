import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SyncFolderDetector', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('home'));
    tearDown(() => home.deleteSync(recursive: true));

    void mk(String rel) =>
        Directory(p.join(home.path, rel)).createSync(recursive: true);

    test('finds providers, parses account, returns Google sub-roots', () {
      final cs = 'Library/CloudStorage';
      mk('$cs/GoogleDrive-user@gmail.com/My Drive');
      mk('$cs/GoogleDrive-user@gmail.com/Shared drives');
      mk('$cs/Dropbox');
      mk('$cs/OneDrive-Personal');
      mk('$cs/Box-Box');
      mk('$cs/.hidden');
      mk('Library/Mobile Documents/com~apple~CloudDocs');

      final found = SyncFolderDetector(homeDir: home.path).detect();

      expect(found.map((f) => f.provider), [
        SyncProvider.box,
        SyncProvider.dropbox,
        SyncProvider.googleDrive,
        SyncProvider.googleDrive,
        SyncProvider.oneDrive,
        SyncProvider.iCloudDrive,
      ]);
      final g = found.where((f) => f.provider == SyncProvider.googleDrive);
      expect(g.every((f) => f.account == 'user@gmail.com'), isTrue);
      expect(g.first.path, endsWith('GoogleDrive-user@gmail.com/My Drive'));
      expect(found.any((f) => f.path.contains('.hidden')), isFalse);
    });

    test('two Google accounts get distinct display names', () {
      mk('Library/CloudStorage/GoogleDrive-a@x.com/My Drive');
      mk('Library/CloudStorage/GoogleDrive-b@x.com/My Drive');
      final names = SyncFolderDetector(homeDir: home.path)
          .detect()
          .map((f) => f.displayName)
          .toList();
      expect(names.toSet().length, 2);
      expect(names.first, contains('a@x.com'));
    });

    test('missing directories yield an empty list', () {
      expect(SyncFolderDetector(homeDir: home.path).detect(), isEmpty);
    });

    test('Google folder without My Drive is skipped', () {
      mk('Library/CloudStorage/GoogleDrive-a@b.com');
      expect(SyncFolderDetector(homeDir: home.path).detect(), isEmpty);
    });
  });

  group('iCloud placeholder mapping', () {
    test('maps .foo.pdf.icloud to foo.pdf', () {
      expect(iCloudPlaceholderRealName('.foo.pdf.icloud'), 'foo.pdf');
      expect(iCloudPlaceholderRealPath('/a/b/.foo.pdf.icloud'), '/a/b/foo.pdf');
    });
    test('ignores normal files', () {
      expect(iCloudPlaceholderRealName('foo.icloud'), isNull);
      expect(iCloudPlaceholderRealName('.hidden'), isNull);
      expect(iCloudPlaceholderRealName('.icloud'), isNull);
    });
  });

  group('FfiOnlineOnlyChecker', () {
    final skip = Platform.isMacOS ? null : 'macOS only';
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('oo'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('regular file is not online-only', () {
      final f = File(p.join(dir.path, 'a.txt'))..writeAsStringSync('hi');
      expect(FfiOnlineOnlyChecker().isOnlineOnly(f.path), isFalse);
      expect(ProcessOnlineOnlyChecker().isOnlineOnly(f.path), isFalse);
    }, skip: skip);

    test('missing file is false; placeholder name is true', () {
      final c = FfiOnlineOnlyChecker();
      expect(c.isOnlineOnly(p.join(dir.path, 'nope')), isFalse);
      expect(c.isOnlineOnly(p.join(dir.path, '.x.pdf.icloud')), isTrue);
    }, skip: skip);

    test('flag bit constant is SF_DATALESS', () {
      expect(sfDataless, 0x40000000);
    });
  });
}
