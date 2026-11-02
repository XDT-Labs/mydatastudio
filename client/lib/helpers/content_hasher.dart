import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';

/// Lowercase sha256 hex of [file]'s bytes, streamed so a multi-GB video is
/// never held in memory.
Future<String> sha256OfFile(io.File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// Whether a scanned file must be (re)hashed: it is new, its size or mtime
/// differs from the stored row, or — never — merely because the row has no
/// hash yet (legacy rows are left alone so a rescan never re-reads the whole
/// archive; they pick a hash up when the file next changes).
///
/// mtime is compared at whole-second precision because the database stores
/// seconds-resolution times.
bool contentHashStale({
  required int? cachedSize,
  required DateTime? cachedModified,
  required int size,
  required DateTime modified,
}) {
  if (cachedSize == null || cachedModified == null) return true;
  return cachedSize != size ||
      cachedModified.millisecondsSinceEpoch ~/ 1000 !=
          modified.millisecondsSinceEpoch ~/ 1000;
}

/// Hash of [file], or null when it is an online-only placeholder: reading a
/// dataless file would download it just to compute a hash.
Future<String?> hashUnlessOnlineOnly(
  io.File file,
  OnlineOnlyChecker checker, {
  Future<String> Function(io.File) hasher = sha256OfFile,
}) async {
  if (checker.isOnlineOnly(file.path)) return null;
  return hasher(file);
}
