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
      final names =
          SyncFolderDetector(
            homeDir: home.path,
          ).detect().map((f) => f.displayName).toList();
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

    test('pCloud, Proton Drive and MEGA match case-insensitively', () {
      mk('Library/CloudStorage/pCloud Drive');
      mk('Library/CloudStorage/ProtonDrive-me@proton.me');
      mk('Library/CloudStorage/MEGA-me');
      final found = SyncFolderDetector(homeDir: home.path).detect();
      expect(found.map((f) => f.provider).toSet(), {
        SyncProvider.pCloud,
        SyncProvider.proton,
        SyncProvider.mega,
      });
      final proton = found.firstWhere((f) => f.provider == SyncProvider.proton);
      expect(proton.account, 'me@proton.me');
      expect(proton.note, contains('end-to-end encrypted'));
    });

    test('"Proton Drive" with a space is recognised', () {
      mk('Library/CloudStorage/Proton Drive');
      final found = SyncFolderDetector(homeDir: home.path).detect();
      expect(found.single.provider, SyncProvider.proton);
    });

    test('legacy ~/Dropbox, ~/MEGA and ~/Sync are reported if directories', () {
      mk('Dropbox');
      mk('MEGA');
      mk('Sync');
      final found = SyncFolderDetector(homeDir: home.path).detect();
      expect(found.map((f) => f.provider), [
        SyncProvider.dropbox,
        SyncProvider.mega,
        SyncProvider.syncCom,
      ]);
      expect(found.last.note, contains('Vault'));
    });

    test('a legacy name that is a plain file is ignored', () {
      File(p.join(home.path, 'Sync')).writeAsStringSync('x');
      expect(SyncFolderDetector(homeDir: home.path).detect(), isEmpty);
    });

    test('~/Dropbox symlinked to the CloudStorage root is reported once', () {
      mk('Library/CloudStorage/Dropbox');
      Link(
        p.join(home.path, 'Dropbox'),
      ).createSync(p.join(home.path, 'Library/CloudStorage/Dropbox'));
      final found = SyncFolderDetector(homeDir: home.path).detect();
      expect(
        found.where((f) => f.provider == SyncProvider.dropbox),
        hasLength(1),
      );
    });

    test('iCloud is one entry: iCloud Drive, without the app containers', () {
      // Listing every app's container buried the catalog under dozens of
      // iCloud rows, and rooting at Mobile Documents imported all of them.
      const md = 'Library/Mobile Documents';
      mk('$md/com~apple~CloudDocs');
      mk('$md/com~apple~Pages/Documents');
      mk('$md/iCloud~md~obsidian');

      final found = SyncFolderDetector(homeDir: home.path).detect();
      expect(found.map((f) => f.displayName), ['iCloud Drive']);
      expect(found.single.path, p.join(home.path, md, 'com~apple~CloudDocs'));
      expect(found.single.note, contains('Online-only'));
    });

    test('an unreadable Mobile Documents is skipped without throwing', () {
      mk('Library/Mobile Documents/com~apple~Pages/x');
      final dir = p.join(home.path, 'Library/Mobile Documents');
      Process.runSync('chmod', ['000', dir]);
      addTearDown(() => Process.runSync('chmod', ['755', dir]));
      var readable = true;
      try {
        Directory(dir).listSync();
      } on FileSystemException {
        readable = false;
      }
      if (readable) return; // running as root: nothing to assert
      expect(SyncFolderDetector(homeDir: home.path).detect(), isEmpty);
    });
  });

  group('iCloud placeholder mapping', () {
    test('isHiddenFileName spares placeholders only', () {
      expect(isHiddenFileName('.foo.pdf.icloud'), isFalse);
      expect(isHiddenFileName('.DS_Store'), isTrue);
      expect(isHiddenFileName('foo.pdf'), isFalse);
    });
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

    // The local scanner builds an FfiOnlineOnlyChecker on every platform;
    // off macOS the lstat symbols are missing, so it must not look them up.
    test('off macOS nothing is online-only and nothing throws', () {
      final ffi = FfiOnlineOnlyChecker(isMacOS: false);
      final proc = ProcessOnlineOnlyChecker(isMacOS: false);
      final placeholder = p.join(dir.path, '.x.pdf.icloud');
      expect(ffi.isOnlineOnly(placeholder), isFalse);
      expect(proc.isOnlineOnly(placeholder), isFalse);
    });

    test('flag bit constant is SF_DATALESS', () {
      expect(sfDataless, 0x40000000);
    });
  });
}
