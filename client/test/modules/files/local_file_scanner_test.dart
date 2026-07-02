import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/scanners/scanner_path_helper.dart';

/// Unit tests for [ScannerPathHelper].
///
/// These tests pin down the relative-path logic used by [LocalFileIsolateWorker]
/// so regressions like the ones fixed during the relative-path refactor are
/// caught immediately:
///
/// Bug 1 – "rootPath set to scan directory instead of collection root"
///   When the scanner is asked to scan a subfolder (e.g. while the user
///   browses into it), rootPath must remain the collection root. If it was set
///   to the current scan dir, every file would get parent='' and appear at the
///   collection root in the UI.
///
/// Bug 2 – "files from subfolder appear at root when breadcrumb navigated back"
///   A consequence of Bug 1 — the parent column was '' for all files, so the
///   query `WHERE parent = ''` returned everything at root level.
void main() {
  // ═══════════════════════════════════════════════════════════════════════════
  // normalisePath
  // ═══════════════════════════════════════════════════════════════════════════

  group('ScannerPathHelper.normalisePath', () {
    test('strips trailing slash from normal path', () {
      expect(
        ScannerPathHelper.normalisePath('/Users/mike/Photos/'),
        '/Users/mike/Photos',
      );
    });

    test('leaves path without trailing slash unchanged', () {
      expect(
        ScannerPathHelper.normalisePath('/Users/mike/Photos'),
        '/Users/mike/Photos',
      );
    });

    test('leaves bare "/" unchanged (filesystem root)', () {
      expect(ScannerPathHelper.normalisePath('/'), '/');
    });

    test('leaves empty string unchanged', () {
      expect(ScannerPathHelper.normalisePath(''), '');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // relativePath — files
  // ═══════════════════════════════════════════════════════════════════════════

  group('ScannerPathHelper.relativePath (file)', () {
    const root = '/Users/mike/2026 copy';

    // ── Root-level files ──────────────────────────────────────────────────

    test('file at collection root returns its basename', () {
      // When a file sits directly in the collection root, p.relative returns '.'
      // which the helper converts to the basename.
      final result = ScannerPathHelper.relativePath('$root/photo.jpg', root);
      expect(result, 'photo.jpg');
    });

    // ── Regression: Bug 1 & 2 ─────────────────────────────────────────────

    test('[BUG REGRESSION] file in subfolder produces correct relPath '
        'when rootPath is the COLLECTION ROOT (not the scan dir)', () {
      // rootPath = collection root → relative path includes the subfolder
      final result = ScannerPathHelper.relativePath(
        '$root/2026-01-01/DSC_3502.NEF',
        root,
      );
      expect(result, '2026-01-01/DSC_3502.NEF');
    });

    test('[BUG REGRESSION] file in subfolder produces WRONG relPath '
        'when rootPath is incorrectly the scan subdirectory', () {
      // rootPath = scan subdirectory (the old bug) → relative path loses the
      // subfolder prefix; the file appears to be at root level.
      final wrongRoot = '$root/2026-01-01'; // ← was set to path arg, not root
      final result = ScannerPathHelper.relativePath(
        '$root/2026-01-01/DSC_3502.NEF',
        wrongRoot,
      );
      // This is the WRONG result that caused the bug:
      expect(
        result,
        'DSC_3502.NEF',
      ); // no '2026-01-01/' prefix → stored at root
    });

    test('file in deeply nested folder returns full relative path', () {
      final result = ScannerPathHelper.relativePath(
        '$root/a/b/c/img.jpg',
        root,
      );
      expect(result, 'a/b/c/img.jpg');
    });

    test('handles spaces in collection root and subfolder names', () {
      const spaceRoot = '/Users/mike/My Photos 2026';
      final result = ScannerPathHelper.relativePath(
        '$spaceRoot/New Year Party/img.jpg',
        spaceRoot,
      );
      expect(result, 'New Year Party/img.jpg');
    });

    test('trailing slash on rootPath is normalised before computing', () {
      final result = ScannerPathHelper.relativePath(
        '$root/2026-01-01/shot.nef',
        '$root/',
      );
      expect(result, '2026-01-01/shot.nef');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // relativePath — folders (isFolder: true)
  // ═══════════════════════════════════════════════════════════════════════════

  group('ScannerPathHelper.relativePath (folder)', () {
    const root = '/Users/mike/2026 copy';

    test('immediate subfolder returns just its name', () {
      final result = ScannerPathHelper.relativePath(
        '$root/2026-01-01',
        root,
        isFolder: true,
      );
      expect(result, '2026-01-01');
    });

    test('nested subfolder returns full relative path', () {
      final result = ScannerPathHelper.relativePath(
        '$root/events/birthday',
        root,
        isFolder: true,
      );
      expect(result, 'events/birthday');
    });

    test('folder equal to root returns empty string (sentinel for root)', () {
      // p.relative returns '.' → helper converts to '' for folders
      final result = ScannerPathHelper.relativePath(root, root, isFolder: true);
      expect(result, '');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // relativeParent
  // ═══════════════════════════════════════════════════════════════════════════

  group('ScannerPathHelper.relativeParent', () {
    const root = '/Users/mike/2026 copy';

    // ── Root-level items have parent = '' ────────────────────────────────

    test('root-level file has parent = empty string', () {
      final result = ScannerPathHelper.relativeParent('$root/photo.jpg', root);
      expect(result, '');
    });

    test('root-level subfolder has parent = empty string', () {
      final result = ScannerPathHelper.relativeParent('$root/2026-01-01', root);
      expect(result, '');
    });

    // ── Regression: the core parent bug ───────────────────────────────────

    test('[BUG REGRESSION] file in subfolder has parent = subfolder name '
        'when rootPath is the COLLECTION ROOT', () {
      final result = ScannerPathHelper.relativeParent(
        '$root/2026-01-01/DSC_3502.NEF',
        root,
      );
      expect(
        result,
        '2026-01-01',
      ); // ← correct; query `parent='2026-01-01'` finds the file
    });

    test('[BUG REGRESSION] file in subfolder has parent = "" (WRONG) '
        'when rootPath is the scan subdirectory', () {
      // When scanner was started with path=subdirectory AND rootPath=path,
      // the parent computation returned '' — files appeared at root level.
      final wrongRoot = '$root/2026-01-01';
      final result = ScannerPathHelper.relativeParent(
        '$root/2026-01-01/DSC_3502.NEF',
        wrongRoot,
      );
      expect(result, ''); // this was the wrong value that caused the bug
    });

    test('deeply nested file has correct parent', () {
      final result = ScannerPathHelper.relativeParent(
        '$root/a/b/c/img.jpg',
        root,
      );
      expect(result, 'a/b/c');
    });

    test('file two levels deep has correct parent', () {
      final result = ScannerPathHelper.relativeParent(
        '$root/2026-01-01/raw/shot.nef',
        root,
      );
      expect(result, '2026-01-01/raw');
    });

    test('trailing slash on rootPath is normalised before computing', () {
      final result = ScannerPathHelper.relativeParent(
        '$root/2026-01-01/DSC_3502.NEF',
        '$root/',
      );
      expect(result, '2026-01-01');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // buildId
  // ═══════════════════════════════════════════════════════════════════════════

  group('ScannerPathHelper.buildId', () {
    test('combines collectionId and relPath with colon separator', () {
      expect(
        ScannerPathHelper.buildId('col-123', '2026-01-01/photo.jpg'),
        'col-123:2026-01-01/photo.jpg',
      );
    });

    test('root-level item produces collectionId: (empty relPath)', () {
      expect(ScannerPathHelper.buildId('col-123', ''), 'col-123:');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════════
  // Full round-trip simulation (mimics the scanner loop)
  // ═══════════════════════════════════════════════════════════════════════════

  group('Full scanner round-trip simulation', () {
    // Simulate what happens when the scanner is started at the collection root
    // (correct) vs. at a subdirectory (the old bug).

    const collectionRoot = '/Users/mike/2026 copy';
    const subDir = '$collectionRoot/2026-01-01';
    const fileAbs = '$subDir/DSC_3502.NEF';

    test('scanning root: file in subfolder gets correct path and parent', () {
      // rootPath = collectionRoot  ← this is what LocalFileIsolate now does
      final relPath = ScannerPathHelper.relativePath(fileAbs, collectionRoot);
      final relParent = ScannerPathHelper.relativeParent(
        fileAbs,
        collectionRoot,
      );

      expect(relPath, '2026-01-01/DSC_3502.NEF');
      expect(
        relParent,
        '2026-01-01',
      ); // query `WHERE parent='2026-01-01'` finds it
    });

    test(
      'OLD BUG: scanning subfolder with rootPath=subDir gives wrong parent',
      () {
        // rootPath = scan directory (this was the bug)
        final relPath = ScannerPathHelper.relativePath(fileAbs, subDir);
        final relParent = ScannerPathHelper.relativeParent(fileAbs, subDir);

        expect(
          relPath,
          'DSC_3502.NEF',
        ); // strip subfolder prefix → file looks like root item
        expect(
          relParent,
          '',
        ); // parent='' → query `WHERE parent=''` finds it at root!
      },
    );

    test(
      'scanning specific subdir with rootPath=collectionRoot gives correct result',
      () {
        // After the fix: even if the user browses into 2026-01-01 and the scanner
        // is started at subDir, rootPath is still collectionRoot.
        final relPath = ScannerPathHelper.relativePath(fileAbs, collectionRoot);
        final relParent = ScannerPathHelper.relativeParent(
          fileAbs,
          collectionRoot,
        );

        expect(relPath, '2026-01-01/DSC_3502.NEF');
        expect(relParent, '2026-01-01');
      },
    );
  });
}
