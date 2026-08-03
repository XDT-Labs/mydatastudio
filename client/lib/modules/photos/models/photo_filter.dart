enum PhotoSortOrder { dateDesc, dateAsc, title, size }

const Object _sentinel = Object();

class PhotoFilter {
  final String searchQuery;
  final String? mediaType;
  final String? source;
  final String? albumId;
  final String? tag;
  final String? location;
  final bool onlyFavorites;
  final PhotoSortOrder sortBy;

  const PhotoFilter({
    this.searchQuery = '',
    this.mediaType,
    this.source,
    this.albumId,
    this.tag,
    this.location,
    this.onlyFavorites = false,
    this.sortBy = PhotoSortOrder.dateDesc,
  });

  PhotoFilter copyWith({
    String? searchQuery,
    Object? mediaType = _sentinel,
    Object? source = _sentinel,
    Object? albumId = _sentinel,
    Object? tag = _sentinel,
    Object? location = _sentinel,
    bool? onlyFavorites,
    PhotoSortOrder? sortBy,
  }) {
    return PhotoFilter(
      searchQuery: searchQuery ?? this.searchQuery,
      mediaType: mediaType == _sentinel ? this.mediaType : mediaType as String?,
      source: source == _sentinel ? this.source : source as String?,
      albumId: albumId == _sentinel ? this.albumId : albumId as String?,
      tag: tag == _sentinel ? this.tag : tag as String?,
      location: location == _sentinel ? this.location : location as String?,
      onlyFavorites: onlyFavorites ?? this.onlyFavorites,
      sortBy: sortBy ?? this.sortBy,
    );
  }
}
