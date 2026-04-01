import 'package:mydatatools/models/tables/collection.dart';
import 'package:rxdart/rxdart.dart';

/// [CollectionScanner] is the base interface for all data synchronization
/// modules in MyDataTools (Files, Email, Social, etc.).
///
/// Synchronization Rules (MUST be followed by all implementations):
/// 1. [Registration-Only Startup] Scanners MUST only register on startup.
/// 2. [Force Safety Gate] start() MUST return immediately if force is false.
/// 3. [Manual Sync] User-initiated syncs MUST call start(force: true).
/// 4. [Discovery vs Sync] Discover items quickly, sync heavy metadata incrementally.
/// 5. [Targeted Scanning vs Full Sync] Scanners MUST support both full collection
///    syncs (path == null) and targeted folder scans (path != null).
class CollectionScanner {
  /// Emits true when a scan is active, false otherwise.
  final BehaviorSubject<bool> isScanning = BehaviorSubject<bool>.seeded(false);

  /// Starts the scanning process for a collection.
  ///
  /// [collection] The data collection to synchronize.
  /// [path] Mode selector:
  ///   - If NULL: **Full Sync**. Exhaustive traversal of the entire collection.
  ///   - If NOT NULL: **Targeted Scan**. Focuses ONLY on the specified folder ID
  ///     or directory path to provide immediate UI feedback during navigation.
  /// [recursive] Whether to synchronize nested children/folders.
  /// [force] CRITICAL: If false, the scanner MUST return immediately without
  /// spawning isolates or starting network/IO work (Rule 2).
  ///
  /// Returns 0 on success (including skipped/registration-only), -1 on error.
  Future<int> start(
    Collection collection,
    String? path,
    bool recursive,
    bool force,
  ) async {
    return Future(() => -1);
  }

  /// Provider-specific action to move items to trash.
  Future<void> moveToTrash(
    Collection collection,
    String folderId,
    List<int> uids,
  ) async {}

  /// Immediately stops any active scanning isolates and cleans up resources.
  void stop() async {}
}
