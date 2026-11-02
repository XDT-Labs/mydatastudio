import 'dart:ffi';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// macOS `SF_DATALESS` bit of `st_flags`: the file's content is evicted
/// (File Provider "online-only") and reading it triggers a download.
const int sfDataless = 0x40000000;

/// Decides whether a file in a cloud sync folder is an online-only placeholder.
/// Kept as an interface so scanners can be tested with a fake.
abstract class OnlineOnlyChecker {
  bool isOnlineOnly(String path);
}

/// Maps a legacy iCloud placeholder (`.foo.pdf.icloud`) to its real file name
/// (`foo.pdf`). Returns null when [fileName] is not a placeholder.
String? iCloudPlaceholderRealName(String fileName) {
  if (fileName.length > '..icloud'.length &&
      fileName.startsWith('.') &&
      fileName.endsWith('.icloud')) {
    return fileName.substring(1, fileName.length - '.icloud'.length);
  }
  return null;
}

/// Full path of the real file a placeholder path stands for, or null.
String? iCloudPlaceholderRealPath(String path) {
  final real = iCloudPlaceholderRealName(p.basename(path));
  return real == null ? null : p.join(p.dirname(path), real);
}

/// Whether a scanner should skip [fileName] as a hidden file. Legacy iCloud
/// placeholders are dot-files by construction but stand for real, visible
/// files, so they are not hidden.
bool isHiddenFileName(String fileName) =>
    fileName.startsWith('.') && iCloudPlaceholderRealName(fileName) == null;

typedef _LstatC = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _LstatDart = int Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _MallocC = Pointer<Uint8> Function(IntPtr);
typedef _MallocDart = Pointer<Uint8> Function(int);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

/// Byte offset of `st_flags` in macOS's 64-bit-inode `struct stat`
/// (identical on arm64 and x86_64); the struct is 144 bytes.
const int _stFlagsOffset = 116;
const int _statSize = 144;

/// Fast per-file check using `lstat` through dart:ffi (no process spawn).
/// `lstat` on a dataless file does not trigger a download.
///
/// macOS only: elsewhere the `lstat` symbols don't exist and nothing is
/// online-only, so every file is reported as local.
class FfiOnlineOnlyChecker implements OnlineOnlyChecker {
  FfiOnlineOnlyChecker({bool? isMacOS})
    : _enabled = isMacOS ?? Platform.isMacOS {
    if (!_enabled) return;
    final lib = DynamicLibrary.process();
    _lstat = _lookupLstat(lib);
    _malloc = lib.lookupFunction<_MallocC, _MallocDart>('malloc');
    _free = lib.lookupFunction<_FreeC, _FreeDart>('free');
  }

  final bool _enabled;
  late final _LstatDart _lstat;
  late final _MallocDart _malloc;
  late final _FreeDart _free;

  static _LstatDart _lookupLstat(DynamicLibrary lib) {
    // x86_64 exports the 64-bit-inode layout as `lstat$INODE64`; plain `lstat`
    // there is the legacy 32-bit-inode struct. arm64 only has `lstat`.
    try {
      return lib.lookupFunction<_LstatC, _LstatDart>('lstat\$INODE64');
    } on ArgumentError {
      return lib.lookupFunction<_LstatC, _LstatDart>('lstat');
    }
  }

  @override
  bool isOnlineOnly(String path) {
    if (!_enabled) return false;
    if (iCloudPlaceholderRealName(p.basename(path)) != null) return true;
    final bytes = utf8.encode(path);
    final cPath = _malloc(bytes.length + 1);
    final buf = _malloc(_statSize);
    if (cPath == nullptr || buf == nullptr) {
      if (cPath != nullptr) _free(cPath);
      if (buf != nullptr) _free(buf);
      return false;
    }
    try {
      cPath.asTypedList(bytes.length + 1)
        ..setAll(0, bytes)
        ..[bytes.length] = 0;
      if (_lstat(cPath, buf) != 0) return false;
      final flags = buf.cast<Uint32>()[_stFlagsOffset ~/ 4];
      return flags & sfDataless != 0;
    } finally {
      _free(cPath);
      _free(buf);
    }
  }
}

/// Slow fallback: spawns `stat -f %Xf`. Fine for one-off checks, far too slow
/// (a process per file) for scans. macOS only, like [FfiOnlineOnlyChecker].
class ProcessOnlineOnlyChecker implements OnlineOnlyChecker {
  ProcessOnlineOnlyChecker({bool? isMacOS})
    : _enabled = isMacOS ?? Platform.isMacOS;

  final bool _enabled;

  @override
  bool isOnlineOnly(String path) {
    if (!_enabled) return false;
    if (iCloudPlaceholderRealName(p.basename(path)) != null) return true;
    final r = Process.runSync('stat', ['-f', '%Xf', path]);
    if (r.exitCode != 0) return false;
    final flags = int.tryParse(r.stdout.toString().trim(), radix: 16) ?? 0;
    return flags & sfDataless != 0;
  }
}
