import 'dart:io';

/// Returns a downloaded file in a cloud sync folder to online-only, so the
/// provider's copy stays the only full copy and the user's disk usage is
/// unchanged. Kept as an interface so callers can be tested with a fake.
abstract class FileEvictor {
  /// True when the file is online-only again.
  Future<bool> evict(String path);
}

/// Evicts through `NSFileManager.evictUbiquitousItem(at:)`, which covers
/// iCloud Drive and every File Provider sync app (Dropbox, OneDrive, Google
/// Drive, Box). It is called through `osascript`'s ObjC bridge so it works
/// from any isolate without a platform channel; a call takes about 0.2s.
///
/// macOS only: elsewhere nothing is online-only, so there is nothing to evict.
class OsascriptFileEvictor implements FileEvictor {
  OsascriptFileEvictor({bool? isMacOS})
    : _enabled = isMacOS ?? Platform.isMacOS;

  final bool _enabled;

  // Passing a null error pointer: reading an NSError back through the bridge
  // crashes osascript.
  static const _script =
      'function run(a){ObjC.import("Foundation");'
      'return \$.NSFileManager.defaultManager.evictUbiquitousItemAtURLError('
      '\$.NSURL.fileURLWithPath(a[0]), null) ? "ok" : "fail"}';

  @override
  Future<bool> evict(String path) async {
    if (!_enabled) return false;
    try {
      final r = await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        _script,
        path,
      ]);
      return r.exitCode == 0 && r.stdout.toString().trim() == 'ok';
    } on ProcessException {
      return false;
    }
  }
}
