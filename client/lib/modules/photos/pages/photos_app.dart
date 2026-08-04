import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/animated_info_panel.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/info_sidebar.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/photos_toolbar.dart';
import 'package:mydatastudio/modules/photos/widgets/viewer/fullscreen_viewer.dart';
import 'package:mydatastudio/modules/photos/widgets/keyboard_shortcut_handler.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_grid.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_list_view.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_map_view.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_timeline_view.dart';

import 'package:mydatastudio/modules/photos/services/photos_repository.dart';

/// Main orchestration page for the Photos application module.
class PhotosApp extends StatefulWidget {
  const PhotosApp({super.key, this.photosRepository});

  final PhotosRepository? photosRepository;

  @override
  State<PhotosApp> createState() => _PhotosAppState();
}

class _PhotosAppState extends State<PhotosApp> {
  late final PhotosRepository _photosRepo;

  StreamSubscription? _viewModeSub;
  StreamSubscription? _photosSub;
  StreamSubscription? _geoFilesSub;
  StreamSubscription? _infoOpenSub;
  StreamSubscription? _lightboxSub;
  StreamSubscription? _filterSub;
  StreamSubscription? _selectionSub;

  PhotoViewMode _viewMode = PhotoViewMode.grid;
  List<File> _files = [];
  List<File> _geoFiles = [];
  bool _isInfoOpen = false;
  File? _lightboxMedia;
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _photosRepo = widget.photosRepository ?? PhotosRepository();
    _viewMode = ViewStateService.instance.viewMode.value;
    _files = PhotosService.instance.sink.valueOrNull ?? [];
    _geoFiles = PhotosService.instance.photosWithLocation.valueOrNull ?? [];
    _isInfoOpen = ViewStateService.instance.isInfoOpen.value;
    _lightboxMedia = ViewStateService.instance.lightboxMedia.value;
    _selectedIds = SelectionService.instance.selectedIds.value;

    _viewModeSub = ViewStateService.instance.viewMode.listen((mode) {
      if (mounted) setState(() => _viewMode = mode);
    });

    _photosSub = PhotosService.instance.sink.listen((files) {
      if (mounted) setState(() => _files = files);
    });

    _geoFilesSub = PhotosService.instance.photosWithLocation.listen((files) {
      if (mounted) setState(() => _geoFiles = files);
    });

    _infoOpenSub = ViewStateService.instance.isInfoOpen.listen((isOpen) {
      if (mounted) setState(() => _isInfoOpen = isOpen);
    });

    _lightboxSub = ViewStateService.instance.lightboxMedia.listen((media) {
      if (mounted) setState(() => _lightboxMedia = media);
    });

    _filterSub = ViewStateService.instance.activeFilter.listen((filter) {
      PhotosService.instance.invoke(PhotosServiceCommand(filter));
    });

    _selectionSub = SelectionService.instance.selectedIds.listen((ids) {
      if (mounted) setState(() => _selectedIds = ids);
    });
  }

  @override
  void dispose() {
    _viewModeSub?.cancel();
    _photosSub?.cancel();
    _geoFilesSub?.cancel();
    _infoOpenSub?.cancel();
    _lightboxSub?.cancel();
    _filterSub?.cancel();
    _selectionSub?.cancel();
    super.dispose();
  }

  Widget _buildActiveView() {
    switch (_viewMode) {
      case PhotoViewMode.grid:
        return PhotoGrid(
          files: _files,
          selectedIds: _selectedIds,
        );
      case PhotoViewMode.list:
        return PhotoListView(
          files: _files,
          selectedIds: _selectedIds,
        );
      case PhotoViewMode.timeline:
        return PhotoTimelineView(
          files: _files,
          selectedIds: _selectedIds,
        );
      case PhotoViewMode.map:
        return PhotoMapView(
          files: _geoFiles,
          selectedIds: _selectedIds,
        );
    }
  }

  Widget _buildInfoPanel() {
    return AnimatedInfoPanel(
      isOpen: _isInfoOpen,
      child: const InfoSidebar(),
    );
  }

  Widget _buildStatusBar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final videoCount = _files.where((f) {
      final mime = f.contentType;
      return mime.startsWith('video/') ||
          f.name.endsWith('.mp4') ||
          f.name.endsWith('.mov') ||
          f.name.endsWith('.avi');
    }).length;
    final photoCount = _files.length - videoCount;

    String countText = '$photoCount photos, $videoCount videos';
    if (_selectedIds.isNotEmpty) {
      countText = '${_selectedIds.length} items selected · $countText';
    }

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text(
            countText,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Text(
            'SPACE: View · I: Info · ESC: Close',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.keyboard_outlined),
            tooltip: 'Keyboard Shortcuts',
            iconSize: 16,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(),
            onPressed: () {
              showDialog<void>(
                context: context,
                builder: (context) => const KeyboardShortcutsModal(),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardShortcutHandler(
      child: Stack(
        children: [
          Column(
            children: [
              const PhotosToolbar(),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: _buildActiveView(),
                    ),
                    _buildInfoPanel(),
                  ],
                ),
              ),
              _buildStatusBar(context),
            ],
          ),
          if (_lightboxMedia != null)
            Positioned.fill(
              child: Row(
                children: [
                  Expanded(
                    child: FullscreenViewer(
                      currentFile: _lightboxMedia!,
                      mediaList: _files,
                      onClose: () => ViewStateService.instance.setLightboxMedia(null),
                      onOpenInfo: (file) => ViewStateService.instance.openInfo(file),
                      onToggleFavorite: (file) async {
                        await _photosRepo.toggleFavorite(file.id);
                        final updatedList = await PhotosService.instance.refresh();
                        final updated = updatedList.firstWhere(
                          (f) => f.id == file.id,
                          orElse: () => file..isFavorite = !file.isFavorite,
                        );
                        ViewStateService.instance.setLightboxMedia(updated);
                      },
                    ),
                  ),
                  _buildInfoPanel(),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
