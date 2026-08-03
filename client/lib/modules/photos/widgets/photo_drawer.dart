import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/album_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_nav_item.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/drawer_section.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/storage_meter.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';

class PhotoDrawer extends StatefulWidget {
  const PhotoDrawer({super.key});

  @override
  State<PhotoDrawer> createState() => _PhotoDrawerState();
}

class _PhotoDrawerState extends State<PhotoDrawer> {
  StreamSubscription<String>? _activeNavSub;
  StreamSubscription<PhotoFilter>? _activeFilterSub;
  StreamSubscription<Map<String, int>>? _sourceCountsSub;
  StreamSubscription<Map<String, int>>? _tagCountsSub;
  StreamSubscription<Map<String, int>>? _locationCountsSub;
  StreamSubscription<List<File>>? _photosSub;

  String _activeNav = 'all';
  PhotoFilter _activeFilter = const PhotoFilter();
  Map<String, int> _sourceCounts = {};
  Map<String, int> _tagCounts = {};
  Map<String, int> _locationCounts = {};
  List<File> _photos = [];
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

      _activeFilterSub = ViewStateService.instance.activeFilter.listen((filter) {
        if (mounted) setState(() => _activeFilter = filter);
      });

      _sourceCountsSub = PhotosService.instance.sourceCounts.listen((counts) {
        if (mounted) setState(() => _sourceCounts = counts);
      });

      _tagCountsSub = PhotosService.instance.tagCounts.listen((counts) {
        if (mounted) setState(() => _tagCounts = counts);
      });

      _locationCountsSub = PhotosService.instance.locationCounts.listen((counts) {
        if (mounted) setState(() => _locationCounts = counts);
      });

      _photosSub = PhotosService.instance.sink.listen((_) {
        if (mounted) {
          _loadLibraryCounts();
        }
      });

      _loadAlbums();
      _loadStorage();
      _loadLibraryCounts();
    });
  }

  @override
  void dispose() {
    _activeNavSub?.cancel();
    _activeFilterSub?.cancel();
    _sourceCountsSub?.cancel();
    _tagCountsSub?.cancel();
    _locationCountsSub?.cancel();
    _photosSub?.cancel();
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
        _activeFilter.source != null ||
        _activeFilter.albumId != null ||
        _activeFilter.tag != null ||
        _activeFilter.location != null ||
        _activeFilter.onlyFavorites;
  }

  Future<void> _showCreateAlbumDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlbumModal(
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
      builder: (context) => AlertDialog(
        title: const Text('Delete Album'),
        content: const Text('Are you sure you want to delete this album? Photos will not be deleted.'),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete album: $e')),
        );
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
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Section 1 — Library
                    DrawerNavItem(
                      label: 'All Photos',
                      icon: Icons.photo_library,
                      count: _allCount > 0 ? _allCount : (_photos.isNotEmpty && _activeNav == 'all' ? _photos.length : null),
                      isActive: _activeNav == 'all',
                      onTap: _clearFilters,
                    ),
                    const SizedBox(height: 2),
                    DrawerNavItem(
                      label: 'Favorites',
                      icon: Icons.favorite,
                      count: _favoritesCount > 0 ? _favoritesCount : null,
                      isActive: _activeNav == 'favorites' || _activeFilter.onlyFavorites,
                      onTap: () {
                        const newFilter = PhotoFilter(onlyFavorites: true);
                        ViewStateService.instance.setActiveNav('favorites');
                        ViewStateService.instance.updateFilter(newFilter);
                        PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
                      },
                    ),
                    const SizedBox(height: 2),
                    DrawerNavItem(
                      label: 'Videos',
                      icon: Icons.videocam,
                      count: _videosCount > 0 ? _videosCount : null,
                      isActive: _activeNav == 'videos' || _activeFilter.mediaType == 'video',
                      onTap: () {
                        const newFilter = PhotoFilter(mediaType: 'video');
                        ViewStateService.instance.setActiveNav('videos');
                        ViewStateService.instance.updateFilter(newFilter);
                        PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DrawerNavItem(
                            label: 'Local Folders',
                            icon: Icons.folder,
                            count: _sourceCounts['local'],
                            isActive: _activeFilter.source == 'local',
                            onTap: () {
                              final isCurrent = _activeFilter.source == 'local';
                              final newFilter = isCurrent ? const PhotoFilter() : const PhotoFilter(source: 'local');
                              ViewStateService.instance.setActiveNav(isCurrent ? 'all' : 'source_local');
                              ViewStateService.instance.updateFilter(newFilter);
                              PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
                            },
                          ),
                          const SizedBox(height: 2),
                          DrawerNavItem(
                            label: 'Google Drive',
                            icon: Icons.cloud,
                            count: _sourceCounts['gdrive'] ?? _sourceCounts['drive'],
                            isActive: _activeFilter.source == 'gdrive',
                            onTap: () {
                              final isCurrent = _activeFilter.source == 'gdrive';
                              final newFilter = isCurrent ? const PhotoFilter() : const PhotoFilter(source: 'gdrive');
                              ViewStateService.instance.setActiveNav(isCurrent ? 'all' : 'source_gdrive');
                              ViewStateService.instance.updateFilter(newFilter);
                              PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
                            },
                          ),
                          const SizedBox(height: 2),
                          DrawerNavItem(
                            label: 'Email Attachments',
                            icon: Icons.email,
                            count: _sourceCounts['email'] ?? _sourceCounts['gmail'],
                            isActive: _activeFilter.source == 'email',
                            onTap: () {
                              final isCurrent = _activeFilter.source == 'email';
                              final newFilter = isCurrent ? const PhotoFilter() : const PhotoFilter(source: 'email');
                              ViewStateService.instance.setActiveNav(isCurrent ? 'all' : 'source_email');
                              ViewStateService.instance.updateFilter(newFilter);
                              PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
                            },
                          ),
                        ],
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
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add, size: 14, color: colorScheme.primary),
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
                      child: _albums.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                              child: Text(
                                'No albums',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: _albums.map((item) {
                                final album = item.album;
                                final count = item.count;
                                final isActive = _activeFilter.albumId == album.id;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 2.0),
                                  child: DrawerNavItem(
                                    label: album.name,
                                    icon: Icons.collections_bookmark_outlined,
                                    count: count > 0 ? count : null,
                                    isActive: isActive,
                                    onSecondaryAction: () => _deleteAlbum(album.id),
                                    secondaryActionTooltip: 'Delete album',
                                    onTap: () {
                                      final newFilter = isActive
                                          ? const PhotoFilter()
                                          : PhotoFilter(albumId: album.id);
                                      ViewStateService.instance.setActiveNav(isActive ? 'all' : 'album_${album.id}');
                                      ViewStateService.instance.updateFilter(newFilter);
                                      PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
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
                      child: _tagCounts.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                              child: Text(
                                'No tags',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _tagCounts.entries.map((entry) {
                                  final tag = entry.key;
                                  final count = entry.value;
                                  final isActive = _activeFilter.tag == tag;
                                  return TagChip(
                                    tag: tag,
                                    count: count,
                                    isActive: isActive,
                                    onTap: () {
                                      final newFilter = isActive
                                          ? const PhotoFilter()
                                          : PhotoFilter(tag: tag);
                                      ViewStateService.instance.setActiveNav(isActive ? 'all' : 'tag_$tag');
                                      ViewStateService.instance.updateFilter(newFilter);
                                      PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
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
                    DrawerSection(
                      title: 'Locations',
                      icon: Icons.place_outlined,
                      initiallyExpanded: false,
                      child: _locationCounts.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                              child: Text(
                                'No locations',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: _locationCounts.entries.map((entry) {
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
                                      final newFilter = isActive
                                          ? const PhotoFilter()
                                          : PhotoFilter(location: loc);
                                      ViewStateService.instance.setActiveNav(isActive ? 'all' : 'loc_$loc');
                                      ViewStateService.instance.updateFilter(newFilter);
                                      PhotosService.instance.invoke(PhotosServiceCommand(newFilter));
                                    },
                                  ),
                                );
                              }).toList(),
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
