import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/models/photo_source_group.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/album_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_nav_item.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_section.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/location_search_field.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/source_group_header.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/storage_meter.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';
import 'package:mydatastudio/services/get_collections_service.dart';

IconData _sourceGroupIcon(PhotoSourceGroup group) {
  switch (group) {
    case PhotoSourceGroup.local:
      return Icons.folder;
    case PhotoSourceGroup.gdrive:
      return Icons.cloud;
    case PhotoSourceGroup.gmail:
    case PhotoSourceGroup.yahoo:
    case PhotoSourceGroup.outlook:
      return Icons.email;
    case PhotoSourceGroup.other:
      return Icons.device_unknown;
  }
}

/// Collection display name — for accounts named `"Drive (user@example.com)"`
/// this shows just the email, matching FileDrawer/EmailDrawer.
String _collectionDisplayName(Collection c) {
  final match = RegExp(r'\(([^)]+)\)').firstMatch(c.name);
  if (match != null) return match.group(1) ?? c.name;
  return c.name;
}

bool _sameIds(Set<String> a, Set<String> b) {
  return a.length == b.length && a.containsAll(b);
}

class PhotoDrawer extends StatefulWidget {
  const PhotoDrawer({super.key});

  @override
  State<PhotoDrawer> createState() => _PhotoDrawerState();
}

class _PhotoDrawerState extends State<PhotoDrawer> {
  StreamSubscription<String>? _activeNavSub;
  StreamSubscription<PhotoFilter>? _activeFilterSub;
  StreamSubscription<Map<String, int>>? _collectionCountsSub;
  StreamSubscription<Map<String, int>>? _tagCountsSub;
  StreamSubscription<Map<String, int>>? _locationCountsSub;
  StreamSubscription<List<File>>? _photosSub;
  StreamSubscription<List<Collection>>? _collectionsSub;

  String _activeNav = 'all';
  PhotoFilter _activeFilter = const PhotoFilter();
  Map<String, int> _collectionPhotoCounts = {};
  Map<String, int> _tagCounts = {};
  Map<String, int> _locationCounts = {};
  List<File> _photos = [];
  List<Collection> _sourceCollections = [];
  final Set<PhotoSourceGroup> _collapsedGroups =
      PhotoSourceGroup.values.toSet();
  List<({Album album, int count})> _albums = [];

  int _usedBytes = 0;
  int _totalBytes = 0;
  int _allCount = 0;
  int _favoritesCount = 0;
  int _videosCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      _activeNavSub = ViewStateService.instance.activeNav.listen((nav) {
        if (mounted) setState(() => _activeNav = nav);
      });

      _activeFilterSub = ViewStateService.instance.activeFilter.listen((
        filter,
      ) {
        if (mounted) setState(() => _activeFilter = filter);
      });

      _collectionCountsSub = PhotosService.instance.collectionPhotoCounts
          .listen((counts) {
            if (mounted) setState(() => _collectionPhotoCounts = counts);
          });

      _tagCountsSub = PhotosService.instance.tagCounts.listen((counts) {
        if (mounted) setState(() => _tagCounts = counts);
      });

      _locationCountsSub = PhotosService.instance.locationCounts.listen((
        counts,
      ) {
        if (mounted) setState(() => _locationCounts = counts);
      });

      _photosSub = PhotosService.instance.sink.listen((_) {
        if (mounted) {
          _loadLibraryCounts();
        }
      });

      _collectionsSub = GetCollectionsService.instance.sink.listen((value) {
        if (mounted) {
          setState(() {
            _sourceCollections =
                value
                    .where((c) => c.type == 'file' || c.type == 'email')
                    .toList()
                  ..sort(
                    (a, b) =>
                        a.name.toLowerCase().compareTo(b.name.toLowerCase()),
                  );
          });
        }
      });
      GetCollectionsService.instance.invoke(GetCollectionsServiceCommand(null));

      _loadAlbums();
      _loadStorage();
      _loadLibraryCounts();
    });
  }

  @override
  void dispose() {
    _activeNavSub?.cancel();
    _activeFilterSub?.cancel();
    _collectionCountsSub?.cancel();
    _tagCountsSub?.cancel();
    _locationCountsSub?.cancel();
    _photosSub?.cancel();
    _collectionsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    final albums = await PhotosRepository().allAlbumsWithCounts();
    if (mounted) {
      setState(() => _albums = albums);
    }
  }

  Future<void> _loadStorage() async {
    final usage = await PhotosRepository().storageUsage();
    if (mounted) {
      setState(() {
        _usedBytes = usage.usedBytes;
        _totalBytes = usage.totalBytes;
      });
    }
  }

  Future<void> _loadLibraryCounts() async {
    final counts = await PhotosRepository().libraryCounts();
    if (!mounted) return;
    setState(() {
      _allCount = counts.total;
      _favoritesCount = counts.favorites;
      _videosCount = counts.videos;
    });
  }

  void _clearFilters() {
    ViewStateService.instance.setActiveNav('all');
    ViewStateService.instance.updateFilter(const PhotoFilter());
    PhotosService.instance.invoke(PhotosServiceCommand(const PhotoFilter()));
    _loadLibraryCounts();
  }

  bool get _isFilterActive {
    return _activeNav != 'all' ||
        _activeFilter.searchQuery.isNotEmpty ||
        _activeFilter.mediaType != null ||
        _activeFilter.collectionId != null ||
        (_activeFilter.collectionIds?.isNotEmpty ?? false) ||
        _activeFilter.albumId != null ||
        _activeFilter.tag != null ||
        _activeFilter.location != null ||
        _activeFilter.place != null ||
        _activeFilter.onlyFavorites;
  }

  void _selectSourceGroup(PhotoSourceGroup group, Set<String> ids) {
    final isCurrent =
        _activeFilter.collectionId == null &&
        _activeFilter.collectionIds != null &&
        _sameIds(_activeFilter.collectionIds!.toSet(), ids);
    final newFilter =
        isCurrent
            ? const PhotoFilter()
            : PhotoFilter(collectionIds: ids.toList());
    ViewStateService.instance.setActiveNav(
      isCurrent ? 'all' : 'source_group_${group.name}',
    );
    ViewStateService.instance.updateFilter(newFilter);
    PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
    if (!isCurrent) {
      setState(() => _collapsedGroups.remove(group));
    }
  }

  /// Applies a place picked from the gazetteer, keeping the rest of the
  /// filter — a location narrows what is already on screen rather than
  /// replacing it, the way picking an album or a source does.
  ///
  /// The landmark filter is the exception, and is cleared. Both express "show
  /// me this place", but one matches coordinates and the other a name the
  /// image analysis wrote, so combining them asks for photos that are near
  /// Chicago *and* tagged with some unrelated landmark — which is nothing.
  /// Searching a city while a landmark was still selected emptied the grid.
  void _selectPlace(PhotoPlaceFilter place) {
    final newFilter = _activeFilter.copyWith(place: place, location: null);
    ViewStateService.instance.setActiveNav('place_${place.label}');
    ViewStateService.instance.updateFilter(newFilter);
    PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
  }

  void _clearPlace() {
    final newFilter = _activeFilter.copyWith(place: null);
    ViewStateService.instance.setActiveNav('all');
    ViewStateService.instance.updateFilter(newFilter);
    PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
  }

  void _selectCollection(Collection c) {
    final isCurrent = _activeFilter.collectionId == c.id;
    final newFilter =
        isCurrent ? const PhotoFilter() : PhotoFilter(collectionId: c.id);
    ViewStateService.instance.setActiveNav(
      isCurrent ? 'all' : 'source_collection_${c.id}',
    );
    ViewStateService.instance.updateFilter(newFilter);
    PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
  }

  List<Widget> _buildSourceGroups(ThemeData theme, ColorScheme colorScheme) {
    final Map<PhotoSourceGroup, List<Collection>> grouped = {};
    for (final c in _sourceCollections) {
      grouped.putIfAbsent(photoSourceGroupFor(c.scanner), () => []).add(c);
    }

    const order = kPhotoSourceGroupOrder;

    final widgets = <Widget>[];
    for (final group in order) {
      final cols = grouped[group];
      if (cols == null || cols.isEmpty) continue;

      final ids = cols.map((c) => c.id).toSet();
      final groupCount = cols.fold<int>(
        0,
        (sum, c) => sum + (_collectionPhotoCounts[c.id] ?? 0),
      );
      final isGroupActive =
          _activeFilter.collectionId == null &&
          _activeFilter.collectionIds != null &&
          _sameIds(_activeFilter.collectionIds!.toSet(), ids);
      final isExpanded = !_collapsedGroups.contains(group);

      widgets.add(
        SourceGroupHeader(
          label: photoSourceGroupLabel(group),
          icon: _sourceGroupIcon(group),
          count: groupCount > 0 ? groupCount : null,
          isActive: isGroupActive,
          isExpanded: isExpanded,
          onTap: () => _selectSourceGroup(group, ids),
          onToggleExpand:
              () => setState(() {
                if (isExpanded) {
                  _collapsedGroups.add(group);
                } else {
                  _collapsedGroups.remove(group);
                }
              }),
        ),
      );

      if (isExpanded) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 16.0, top: 2.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  cols.map((c) {
                    final count = _collectionPhotoCounts[c.id];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2.0),
                      child: DrawerNavItem(
                        label: _collectionDisplayName(c),
                        icon: _sourceGroupIcon(group),
                        count: (count != null && count > 0) ? count : null,
                        isActive: _activeFilter.collectionId == c.id,
                        onTap: () => _selectCollection(c),
                      ),
                    );
                  }).toList(),
            ),
          ),
        );
      }
      widgets.add(const SizedBox(height: 2));
    }
    return widgets;
  }

  Future<void> _showCreateAlbumDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlbumModal(
            selectedFileIds: SelectionService.instance.selectedIds.value,
            initialMode: AlbumModalMode.createNew,
          ),
    );

    if (result == true) {
      await _loadAlbums();
    }
  }

  Future<void> _deleteAlbum(String albumId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Delete Album'),
            content: const Text(
              'Are you sure you want to delete this album? Photos will not be deleted.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
    );

    if (confirmed != true) return;

    try {
      await PhotosRepository().deleteAlbum(albumId);
      if (_activeFilter.albumId == albumId) {
        _clearFilters();
      }
      await _loadAlbums();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete album: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SizedBox(
      width: 240,
      child: Container(
        color: colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8.0,
                  vertical: 12.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Section 1 — Library
                    DrawerNavItem(
                      label: 'All Photos',
                      icon: Icons.photo_library,
                      count:
                          _allCount > 0
                              ? _allCount
                              : (_photos.isNotEmpty && _activeNav == 'all'
                                  ? _photos.length
                                  : null),
                      isActive: _activeNav == 'all',
                      onTap: _clearFilters,
                    ),
                    const SizedBox(height: 2),
                    DrawerNavItem(
                      label: 'Favorites',
                      icon: Icons.favorite,
                      count: _favoritesCount > 0 ? _favoritesCount : null,
                      isActive:
                          _activeNav == 'favorites' ||
                          _activeFilter.onlyFavorites,
                      onTap: () {
                        const newFilter = PhotoFilter(onlyFavorites: true);
                        ViewStateService.instance.setActiveNav('favorites');
                        ViewStateService.instance.updateFilter(newFilter);
                        PhotosService.instance.invoke(
                          PhotosServiceCommand(newFilter),
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    DrawerNavItem(
                      label: 'Videos',
                      icon: Icons.videocam,
                      count: _videosCount > 0 ? _videosCount : null,
                      isActive:
                          _activeNav == 'videos' ||
                          _activeFilter.mediaType == 'video',
                      onTap: () {
                        const newFilter = PhotoFilter(mediaType: 'video');
                        ViewStateService.instance.setActiveNav('videos');
                        ViewStateService.instance.updateFilter(newFilter);
                        PhotosService.instance.invoke(
                          PhotosServiceCommand(newFilter),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    const SizedBox(height: 12),

                    // Section 2 — Sources
                    DrawerSection(
                      title: 'Sources',
                      icon: Icons.cloud_outlined,
                      initiallyExpanded: true,
                      child:
                          _sourceCollections.isEmpty
                              ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12.0,
                                  vertical: 6.0,
                                ),
                                child: Text(
                                  'No sources',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                              : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: _buildSourceGroups(
                                  theme,
                                  colorScheme,
                                ),
                              ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    const SizedBox(height: 12),

                    // Section 3 — Albums
                    DrawerSection(
                      title: 'Albums',
                      icon: Icons.photo_album_outlined,
                      initiallyExpanded: true,
                      trailing: InkWell(
                        onTap: _showCreateAlbumDialog,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.add,
                                size: 14,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                '+ New',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child:
                          _albums.isEmpty
                              ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12.0,
                                  vertical: 6.0,
                                ),
                                child: Text(
                                  'No albums',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                              : Column(
                                mainAxisSize: MainAxisSize.min,
                                children:
                                    _albums.map((item) {
                                      final album = item.album;
                                      final count = item.count;
                                      final isActive =
                                          _activeFilter.albumId == album.id;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 2.0,
                                        ),
                                        child: DrawerNavItem(
                                          label: album.name,
                                          icon:
                                              Icons
                                                  .collections_bookmark_outlined,
                                          count: count > 0 ? count : null,
                                          isActive: isActive,
                                          onSecondaryAction:
                                              () => _deleteAlbum(album.id),
                                          secondaryActionTooltip:
                                              'Delete album',
                                          onTap: () {
                                            final newFilter =
                                                isActive
                                                    ? const PhotoFilter()
                                                    : PhotoFilter(
                                                      albumId: album.id,
                                                    );
                                            ViewStateService.instance
                                                .setActiveNav(
                                                  isActive
                                                      ? 'all'
                                                      : 'album_${album.id}',
                                                );
                                            ViewStateService.instance
                                                .updateFilter(newFilter);
                                            PhotosService.instance.invoke(
                                              PhotosServiceCommand(newFilter),
                                            );
                                          },
                                        ),
                                      );
                                    }).toList(),
                              ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    const SizedBox(height: 12),

                    // Section 4 — Tags
                    DrawerSection(
                      title: 'Tags',
                      icon: Icons.label_outlined,
                      initiallyExpanded: false,
                      child:
                          _tagCounts.isEmpty
                              ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12.0,
                                  vertical: 6.0,
                                ),
                                child: Text(
                                  'No tags',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                              : Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8.0,
                                  vertical: 4.0,
                                ),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children:
                                      _tagCounts.entries.map((entry) {
                                        final tag = entry.key;
                                        final count = entry.value;
                                        final isActive =
                                            _activeFilter.tag == tag;
                                        return TagChip(
                                          tag: tag,
                                          count: count,
                                          isActive: isActive,
                                          onTap: () {
                                            final newFilter =
                                                isActive
                                                    ? const PhotoFilter()
                                                    : PhotoFilter(tag: tag);
                                            ViewStateService.instance
                                                .setActiveNav(
                                                  isActive ? 'all' : 'tag_$tag',
                                                );
                                            ViewStateService.instance
                                                .updateFilter(newFilter);
                                            PhotosService.instance.invoke(
                                              PhotosServiceCommand(newFilter),
                                            );
                                          },
                                        );
                                      }).toList(),
                                ),
                              ),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    const SizedBox(height: 12),

                    // Section 5 — Locations
                    //
                    // A search box rather than a list: the landmark names this
                    // section used to enumerate are written only when the
                    // vision model recognises something famous, so for most
                    // libraries it was permanently empty. The EXIF coordinates
                    // it searches instead are already there.
                    DrawerSection(
                      title: 'Locations',
                      icon: Icons.place_outlined,
                      initiallyExpanded: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LocationSearchField(
                            // Keyed on the active filter so choosing any other
                            // one — an album, a source, All Photos — rebuilds
                            // this with empty state. The place filter itself
                            // is already dropped by those (they replace the
                            // filter outright), but the text typed here and
                            // the suggestions under it live in the widget and
                            // would otherwise sit there afterwards, reading as
                            // a location filter that refused to clear.
                            // Typing does not change the active nav, so an
                            // in-progress search is left alone.
                            key: ValueKey('location-search-$_activeNav'),
                            selected: _activeFilter.place,
                            onSelected: _selectPlace,
                            onCleared: _clearPlace,
                          ),
                          // Headed separately because the two are not variants
                          // of one thing. Above searches coordinates and takes
                          // a radius; below matches a name the image analysis
                          // recognised, on photos that largely carry no
                          // coordinates at all. Presented as one list, the
                          // missing radius on these reads as a bug.
                          if (_locationCounts.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Padding(
                              padding: const EdgeInsets.only(
                                left: 12.0,
                                bottom: 4.0,
                              ),
                              child: Text(
                                'Recognised in photos',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                          if (_locationCounts.isNotEmpty)
                            ..._locationCounts.entries.map((entry) {
                              final loc = entry.key;
                              final count = entry.value;
                              final isActive = _activeFilter.location == loc;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 2.0),
                                child: DrawerNavItem(
                                  label: loc,
                                  icon: Icons.location_on,
                                  count: count > 0 ? count : null,
                                  isActive: isActive,
                                  onTap: () {
                                    // Replaces the filter outright, which is
                                    // also what drops any searched place —
                                    // see _selectPlace for why the two cannot
                                    // both be applied.
                                    final newFilter =
                                        isActive
                                            ? const PhotoFilter()
                                            : PhotoFilter(location: loc);
                                    ViewStateService.instance.setActiveNav(
                                      isActive ? 'all' : 'loc_$loc',
                                    );
                                    ViewStateService.instance.updateFilter(
                                      newFilter,
                                    );
                                    PhotosService.instance.invoke(
                                      PhotosServiceCommand(newFilter),
                                    );
                                  },
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Clear Filters button
                    if (_isFilterActive) ...[
                      Center(
                        child: TextButton.icon(
                          onPressed: _clearFilters,
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Clear Filters'),
                          style: TextButton.styleFrom(
                            foregroundColor: colorScheme.error,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ),

            // Bottom Storage Meter
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: StorageMeter(
                usedBytes: _usedBytes,
                totalBytes: _totalBytes,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
