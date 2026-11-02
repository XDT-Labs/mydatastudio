import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

class _Api implements CloudFileApi {
  _Api(this.tree);
  final Map<String, List<CloudFileEntry>> tree;
  int pages = 0;
  @override
  String get scheme => 'fake';
  @override
  Future<CloudFilePage> listChildren(String id, {String? pageToken}) async {
    pages++;
    final all = tree[id] ?? const [];
    final start = int.parse(pageToken ?? '0');
    final end = (start + 2).clamp(0, all.length);
    return CloudFilePage(
      all.sublist(start, end),
      nextPageToken: end < all.length ? '$end' : null,
    );
  }

  @override
  bool isDownloadableMimeType(String m) =>
      !m.startsWith('application/x-native');
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _WholeApi extends _Api implements WholeDriveListing {
  _WholeApi(super.tree);
  @override
  Stream<List<CloudFileEntry>> listAllEntries() async* {
    yield tree.values.expand((e) => e).toList();
  }
}

CloudFileEntry _f(String id, String mime, int size) =>
    CloudFileEntry(id: id, name: id, mimeType: mime, size: size);

final _tree = {
  'root': [
    _f('a', 'image/png', 10),
    const CloudFileEntry(id: 'dir', name: 'dir', isFolder: true),
    _f('b', 'video/mp4', 100),
  ],
  'dir': [
    _f('c', 'image/jpeg', 20),
    _f('native', 'application/x-native-doc', 0),
  ],
};
const _images = ContentPolicy(downloadCategories: {ContentCategory.images});

void main() {
  test(
    'totals files, folders, bytes and what the policy would download',
    () async {
      final e = await CloudSyncEstimator.estimate(_Api(_tree), 'root', _images);
      expect(e.complete, isTrue);
      expect(e.folders, 1);
      expect(e.files, 4);
      expect(e.totalBytes, 130);
      expect(e.filesByCategory[ContentCategory.images], 2);
      expect(e.bytesByCategory[ContentCategory.videos], 100);
      expect(e.downloadFiles, 2);
      expect(e.downloadBytes, 30);
    },
  );

  test('cancelling returns a partial, incomplete estimate', () async {
    final api = _Api(_tree);
    var seen = 0;
    final e = await CloudSyncEstimator.estimate(
      api,
      'root',
      _images,
      onProgress: (_) => seen++,
      isCancelled: () => seen >= 1,
    );
    expect(e.complete, isFalse);
    expect(api.pages, 1);
    expect(e.files, lessThan(4));
  });

  test(
    'uses the whole-drive listing for root when the adapter has one',
    () async {
      final api = _WholeApi(_tree);
      final e = await CloudSyncEstimator.estimate(api, 'root', _images);
      expect(api.pages, 0);
      expect(e.files, 4);
      expect(e.complete, isTrue);
    },
  );
}
