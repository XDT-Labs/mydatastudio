import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

File _f(String name, String mime, int size) => File(
  id: name,
  name: name,
  path: 'x://$name',
  parent: '',
  dateCreated: DateTime(2024),
  dateLastModified: DateTime(2024),
  collectionId: 'c',
  contentType: mime,
  isDeleted: false,
  size: size,
);

void main() {
  test('categorises provider and app mime types, extension as fallback', () {
    expect(ContentPolicy.categorize('image/png', 'a'), ContentCategory.images);
    expect(
      ContentPolicy.categorize('application/image', 'a'),
      ContentCategory.images,
    );
    expect(ContentPolicy.categorize('video/mp4', 'a'), ContentCategory.videos);
    expect(ContentPolicy.categorize('audio/mpeg', 'a'), ContentCategory.audio);
    expect(
      ContentPolicy.categorize('application/pdf', 'a'),
      ContentCategory.documents,
    );
    expect(
      ContentPolicy.categorize('application/octet-stream', 'x.MOV'),
      ContentCategory.videos,
    );
    expect(ContentPolicy.categorize(null, 'x.bin'), ContentCategory.other);
  });

  test('downloads only chosen categories within the size cap', () {
    const p = ContentPolicy(
      downloadCategories: {ContentCategory.images, ContentCategory.documents},
      maxFileBytes: 100,
    );
    expect(p.shouldDownload(_f('a.png', 'image/png', 100)), isTrue);
    expect(p.shouldDownload(_f('a.png', 'image/png', 101)), isFalse);
    expect(p.shouldDownload(_f('a.mp4', 'video/mp4', 1)), isFalse);
    expect(
      p.shouldDownloadEntry(
        const CloudFileEntry(
          id: '1',
          name: 'a.pdf',
          mimeType: 'application/pdf',
        ),
      ),
      isTrue,
    );
    expect(
      p.shouldDownloadEntry(
        const CloudFileEntry(id: '2', name: 'd', isFolder: true),
      ),
      isFalse,
    );
  });

  test('JSON round-trips', () {
    const p = ContentPolicy(
      downloadCategories: {ContentCategory.audio},
      maxFileBytes: 5,
      index: false,
    );
    final back = ContentPolicy.resolve(
      json: p.encode(),
      downloadLocalCopy: true,
    );
    expect(back.downloadCategories, {ContentCategory.audio});
    expect(back.maxFileBytes, 5);
    expect(back.index, isFalse);
  });

  test('null policy falls back to download_local_copy', () {
    final on = ContentPolicy.resolve(json: null, downloadLocalCopy: true);
    expect(on.downloadCategories, ContentCategory.values.toSet());
    expect(on.index, isTrue);
    final off = ContentPolicy.resolve(json: null, downloadLocalCopy: false);
    expect(off.downloadsAnything, isFalse);
    expect(
      ContentPolicy.resolve(
        json: '{bad',
        downloadLocalCopy: true,
      ).downloadsAnything,
      isTrue,
    );
  });
}
