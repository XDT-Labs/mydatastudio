import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

/// Optional capability: a provider that can list every file in the drive in a
/// few large pages, much faster than walking folder by folder. Only valid for
/// the whole-drive root.
abstract class WholeDriveListing {
  /// Pages of every non-trashed item. Folders may be included.
  Stream<List<CloudFileEntry>> listAllEntries();
}

/// Totals from a metadata-only walk. [complete] is false when the walk was
/// cancelled, in which case the numbers are a lower bound.
class CloudSyncEstimate {
  int files = 0;
  int folders = 0;
  int totalBytes = 0;
  int downloadFiles = 0;
  int downloadBytes = 0;
  bool complete = false;
  final Map<ContentCategory, int> filesByCategory = {};
  final Map<ContentCategory, int> bytesByCategory = {};

  void add(CloudFileEntry e, ContentPolicy policy, CloudFileApi api) {
    if (e.isFolder) {
      folders++;
      return;
    }
    final size = e.size ?? 0;
    final cat = ContentPolicy.categorize(e.mimeType, e.name);
    files++;
    totalBytes += size;
    filesByCategory[cat] = (filesByCategory[cat] ?? 0) + 1;
    bytesByCategory[cat] = (bytesByCategory[cat] ?? 0) + size;
    if (e.isDownloadable &&
        api.isDownloadableMimeType(e.mimeType ?? '') &&
        policy.shouldDownloadEntry(e)) {
      downloadFiles++;
      downloadBytes += size;
    }
  }
}

/// Counts what a first sync would see and download, without downloading.
class CloudSyncEstimator {
  /// [onProgress] receives the running estimate after each page.
  /// [isCancelled] is polled between pages; the partial result is returned
  /// with `complete == false`.
  static Future<CloudSyncEstimate> estimate(
    CloudFileApi api,
    String rootFolderId,
    ContentPolicy policy, {
    void Function(CloudSyncEstimate progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final result = CloudSyncEstimate();
    bool cancelled() => isCancelled?.call() ?? false;

    if (rootFolderId == 'root' && api is WholeDriveListing) {
      await for (final page in (api as WholeDriveListing).listAllEntries()) {
        for (final e in page) {
          result.add(e, policy, api);
        }
        onProgress?.call(result);
        if (cancelled()) return result;
      }
      result.complete = true;
      return result;
    }

    final queue = <String>[rootFolderId];
    for (var i = 0; i < queue.length; i++) {
      String? token;
      do {
        final page = await api.listChildren(queue[i], pageToken: token);
        for (final e in page.entries) {
          result.add(e, policy, api);
          if (e.isFolder) queue.add(e.id);
        }
        token = page.nextPageToken;
        onProgress?.call(result);
        if (cancelled()) return result;
      } while (token != null);
    }
    result.complete = true;
    return result;
  }
}
