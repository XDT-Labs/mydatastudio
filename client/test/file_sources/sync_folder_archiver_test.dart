import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/file_sources/sync_folder/file_evictor.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_archiver.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

class _FakeOnlineOnly implements OnlineOnlyChecker {
  final Set<String> paths;
  _FakeOnlineOnly(this.paths);

  @override
  bool isOnlineOnly(String path) => paths.contains(path);
}

class _FakeEvictor implements FileEvictor {
  final List<String> evicted = [];

  @override
  Future<bool> evict(String path) async {
    evicted.add(path);
    return true;
  }
}

/// A sync folder is not a backup on its own: the provider can evict, delete
/// or lose files. The archiver keeps a copy of each file the collection's
/// policy covers, without leaving online-only files downloaded on the
/// user's disk.
void main() {
  late io.Directory tmp;
  late String root;
  late String archive;
  late Map<String, String> recorded;
  late _FakeEvictor evictor;

  setUp(() {
    tmp = io.Directory.systemTemp.createTempSync('mds_archiver_');
    root = '${tmp.path}/Dropbox';
    archive = '${tmp.path}/archive';
    io.Directory('$root/docs').createSync(recursive: true);
    recorded = {};
    evictor = _FakeEvictor();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  final modified = DateTime(2026, 3, 4, 5, 6, 7);

  File write(String rel, {String content = 'hello'}) {
    final f = io.File('$root/$rel')..writeAsStringSync(content);
    f.setLastModifiedSync(modified);
    return File(
      id: 'c:$rel',
      name: rel.split('/').last,
      path: rel,
      parent: '',
      dateCreated: modified,
      dateLastModified: modified,
      collectionId: 'c',
      contentType: '',
      size: content.length,
      isDeleted: false,
    );
  }

  SyncFolderArchiver archiver({
    ContentPolicy? policy,
    Set<String> onlineOnly = const {},
  }) => SyncFolderArchiver(
    archiveDir: archive,
    policy: policy ?? ContentPolicy.everything,
    recordCopy: (id, path) async => recorded[id] = path,
    onlineOnly: _FakeOnlineOnly(onlineOnly),
    evictor: evictor,
  );

  test('copies each file into the archive and records where', () async {
    final f = write('docs/report.pdf');
    final copied = await archiver().archiveAll(root, [f]);

    expect(copied, 1);
    expect(io.File('$archive/docs/report.pdf').readAsStringSync(), 'hello');
    expect(recorded[f.id], '$archive/docs/report.pdf');
    expect(evictor.evicted, isEmpty, reason: 'it was already on disk');
  });

  test(
    'an online-only file is archived, then made online-only again',
    () async {
      final f = write('docs/report.pdf');
      await archiver(
        onlineOnly: {'$root/docs/report.pdf'},
      ).archiveAll(root, [f]);

      expect(io.File('$archive/docs/report.pdf').existsSync(), isTrue);
      expect(evictor.evicted, ['$root/docs/report.pdf']);
    },
  );

  test('an unchanged file is not read again', () async {
    // Re-reading would download an online-only file on every scan.
    final f = write('docs/report.pdf');
    await archiver().archiveAll(root, [f]);
    final copied = await archiver(
      onlineOnly: {'$root/docs/report.pdf'},
    ).archiveAll(root, [f..localPath = '$archive/docs/report.pdf']);

    expect(copied, 0);
    expect(evictor.evicted, isEmpty);
  });

  test('a file changed since its copy is copied again', () async {
    final f = write('docs/report.pdf');
    await archiver().archiveAll(root, [f]);

    final changed = write('docs/report.pdf', content: 'edited');
    changed.dateLastModified = modified.add(const Duration(hours: 1));
    io.File(
      '$root/docs/report.pdf',
    ).setLastModifiedSync(changed.dateLastModified);
    final copied = await archiver().archiveAll(root, [changed]);

    expect(copied, 1);
    expect(io.File('$archive/docs/report.pdf').readAsStringSync(), 'edited');
  });

  test('files the policy leaves out are not copied', () async {
    final photo = write('photo.jpg');
    final doc = write('notes.txt');
    final policy = ContentPolicy(downloadCategories: {ContentCategory.images});
    await archiver(policy: policy).archiveAll(root, [photo, doc]);

    expect(io.File('$archive/photo.jpg').existsSync(), isTrue);
    expect(io.File('$archive/notes.txt').existsSync(), isFalse);
  });

  test('one unreadable file does not stop the rest', () async {
    final missing = write('gone.txt');
    io.File('$root/gone.txt').deleteSync();
    final ok = write('kept.txt');
    final copied = await archiver().archiveAll(root, [missing, ok]);

    expect(copied, 1);
    expect(io.File('$archive/kept.txt').existsSync(), isTrue);
    expect(io.File('$archive/gone.txt.part').existsSync(), isFalse);
  });
}
