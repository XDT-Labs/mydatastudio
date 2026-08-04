/// Time-bucket granularity for grouping photos in the timeline view.
enum PhotoSectionGranularity { month, year }

/// One bucket's worth of aggregate info from the database — used to build
/// the timeline's section headers and quick-jump scrubber without loading
/// the files themselves.
class PhotoSectionSummary {
  const PhotoSectionSummary({required this.bucketKey, required this.count});

  /// `yyyy-MM` for month granularity, `yyyy` for year granularity.
  final String bucketKey;
  final int count;
}
