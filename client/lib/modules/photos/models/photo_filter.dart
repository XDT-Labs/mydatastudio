import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';

enum PhotoSortOrder { dateDesc, dateAsc, title, size }

const Object _sentinel = Object();

class PhotoFilter {
  final String searchQuery;
  final String? mediaType;
  final String? collectionId;
  final List<String>? collectionIds;
  final String? albumId;
  final String? tag;
  final String? location;

  /// A gazetteer place to search around, filtering on the GPS coordinates
  /// EXIF gave the photos. Independent of [location], which matches
  /// AI-detected landmark names.
  final PhotoPlaceFilter? place;

  final bool onlyFavorites;
  final PhotoSortOrder sortBy;

  const PhotoFilter({
    this.searchQuery = '',
    this.mediaType,
    this.collectionId,
    this.collectionIds,
    this.albumId,
    this.tag,
    this.location,
    this.place,
    this.onlyFavorites = false,
    this.sortBy = PhotoSortOrder.dateDesc,
  });

  PhotoFilter copyWith({
    String? searchQuery,
    Object? mediaType = _sentinel,
    Object? collectionId = _sentinel,
    Object? collectionIds = _sentinel,
    Object? albumId = _sentinel,
    Object? tag = _sentinel,
    Object? location = _sentinel,
    Object? place = _sentinel,
    bool? onlyFavorites,
    PhotoSortOrder? sortBy,
  }) {
    return PhotoFilter(
      searchQuery: searchQuery ?? this.searchQuery,
      mediaType: mediaType == _sentinel ? this.mediaType : mediaType as String?,
      collectionId: collectionId == _sentinel
          ? this.collectionId
          : collectionId as String?,
      collectionIds: collectionIds == _sentinel
          ? this.collectionIds
          : collectionIds as List<String>?,
      albumId: albumId == _sentinel ? this.albumId : albumId as String?,
      tag: tag == _sentinel ? this.tag : tag as String?,
      location: location == _sentinel ? this.location : location as String?,
      place: place == _sentinel ? this.place : place as PhotoPlaceFilter?,
      onlyFavorites: onlyFavorites ?? this.onlyFavorites,
      sortBy: sortBy ?? this.sortBy,
    );
  }
}
