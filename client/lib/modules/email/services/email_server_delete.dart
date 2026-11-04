import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';

/// Moves [emails] to the server's trash, including their copies in other
/// folders, and returns the ones that got there. Only those may be deleted
/// locally: anything else is still on the server, so the next sync would bring
/// it straight back.
///
/// A row with no UID can't be addressed on the server and is left out.
Future<List<Email>> moveToServerTrash(
  List<Email> emails,
  Collection collection,
  CollectionScanner scanner, {
  String? fallbackFolder,
}) async {
  final byFolder = <String, List<Email>>{};
  for (final email in emails) {
    if (email.uid == null) continue;
    final folder = email.folderId ?? fallbackFolder ?? 'INBOX';
    byFolder.putIfAbsent(folder, () => []).add(email);
  }

  final moved = <Email>[];
  for (final MapEntry(key: folder, value: group) in byFolder.entries) {
    final otherCopies = <String, List<String>>{};
    for (final email in group) {
      final messageId = email.messageId;
      if (messageId == null) continue;
      for (final label in email.labels ?? const <String>[]) {
        if (label.isEmpty || label == folder) continue;
        otherCopies.putIfAbsent(label, () => []).add(messageId);
      }
    }
    try {
      final ok = await scanner.moveToTrash(
        collection,
        folder,
        group.map((e) => e.uid!).toList(),
        otherCopies: otherCopies,
      );
      if (ok) moved.addAll(group);
    } catch (e) {
      AppLogger(null).e('Moving messages in $folder to trash failed: $e');
    }
  }
  return moved;
}
