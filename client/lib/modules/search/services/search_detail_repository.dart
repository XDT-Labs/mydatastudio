import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// Loads the full record behind a search hit.
///
/// `SearchResult` is deliberately a flattened shape shared by mail and files so
/// the two can be interleaved in one ranked list — it carries an id and just
/// enough to draw a row. The detail sidebars need the real `File` or `Email`,
/// so this is the one seam where search reaches back into the tables its
/// results came from.
///
/// Paths come back exactly as stored (relative to the collection's local copy).
/// Resolving them is the caller's job, via `FilePathResolver` and the
/// [collectionById] the same result names — the collection is not implied by
/// the file, and search spans all of them.
class SearchDetailRepository {
  const SearchDetailRepository();

  Future<File?> fileById(String id) async {
    final db = DatabaseManager.instance.database;
    if (db == null) return null;
    final rows = await db.select('SELECT * FROM files WHERE id = ? LIMIT 1', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return File.fromDbMap(rows.first);
  }

  Future<Email?> emailById(String id) async {
    final db = DatabaseManager.instance.database;
    if (db == null) return null;
    final emails = await EmailRepository(db).getAllById([id]);
    return emails.isEmpty ? null : emails.first;
  }

  Future<Collection?> collectionById(String id) =>
      CollectionRepository().collectionById(id);
}
