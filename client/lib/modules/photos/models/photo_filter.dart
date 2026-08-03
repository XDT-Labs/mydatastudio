enum PhotoSortOrder { dateDesc, dateAsc, title, size }

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
    String? mediaType,
    String? source,
    String? albumId,
    String? tag,
    String? location,
    bool? onlyFavorites,
    PhotoSortOrder? sortBy,
  }) {
    return PhotoFilter(
      searchQuery: searchQuery ?? this.searchQuery,
      mediaType: mediaType ?? this.mediaType,
      source: source ?? this.source,
      albumId: albumId ?? this.albumId,
      tag: tag ?? this.tag,
      location: location ?? this.location,
      onlyFavorites: onlyFavorites ?? this.onlyFavorites,
      sortBy: sortBy ?? this.sortBy,
    );
  }
}
