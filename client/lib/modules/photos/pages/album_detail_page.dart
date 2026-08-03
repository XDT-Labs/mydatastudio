import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_grid.dart';


/// Page for viewing details and files belonging to a specific Album.
class AlbumDetailPage extends StatefulWidget {
  final String albumId;
  final PhotosRepository? photosRepository;

  const AlbumDetailPage({
    super.key,
    required this.albumId,
    this.photosRepository,
  });

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late final PhotosRepository _repo;
  StreamSubscription? _selectionSub;

  Album? _album;
  List<File> _files = [];
  Set<String> _selectedIds = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _repo = widget.photosRepository ?? PhotosRepository();
    _selectedIds = SelectionService.instance.selectedIds.value;

    _selectionSub = SelectionService.instance.selectedIds.listen((selected) {
      if (mounted) setState(() => _selectedIds = selected);
    });

    _loadData();
  }

  @override
  void dispose() {
    _selectionSub?.cancel();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final album = await _repo.getAlbum(widget.albumId);
    final files = await _repo.photos(
      filter: PhotoFilter(albumId: widget.albumId),
    );

    if (mounted) {
      setState(() {
        _album = album;
        _files = files;
        _isLoading = false;
      });
    }
  }

  Future<void> _showEditDialog() async {
    if (_album == null) return;

    final nameController = TextEditingController(text: _album!.name);
    final descController = TextEditingController(text: _album!.description ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          title: const Text('Edit Album'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Album Title',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Description',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (result == true) {
      final newName = nameController.text.trim();
      final newDesc = descController.text.trim();
      if (newName.isNotEmpty) {
        await _repo.updateAlbum(
          widget.albumId,
          newName,
          newDesc.isEmpty ? null : newDesc,
        );
        _loadData();
      }
    }
  }

  Future<void> _showDeleteConfirmDialog() async {
    if (_album == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          title: const Text('Delete Album'),
          content: Text(
            'Are you sure you want to delete "${_album!.name}"? Photos will not be deleted from your library.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      await _repo.deleteAlbum(widget.albumId);
      if (mounted) {
        context.go('/photos');
      }
    }
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    File? coverFile;
    if (_album?.coverFileId != null) {
      coverFile = _files.cast<File?>().firstWhere(
            (f) => f?.id == _album!.coverFileId,
            orElse: () => null,
          );
    }
    coverFile ??= _files.isNotEmpty ? _files.first : null;

    return Container(
      padding: const EdgeInsets.all(24.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant,
            width: 1.0,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to Photos',
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/photos');
                  }
                },
              ),
              const SizedBox(width: 8),
              Text(
                'Album',
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit Album',
                onPressed: _showEditDialog,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete Album',
                color: colorScheme.error,
                onPressed: _showDeleteConfirmDialog,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: Container(
                  width: 96,
                  height: 96,
                  color: colorScheme.surfaceContainerHigh,
                  child: (coverFile != null && ThumbnailResolver.providerFor(coverFile.thumbnail) != null)
                      ? Image(
                          image: ThumbnailResolver.providerFor(coverFile.thumbnail)!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Icon(
                              Icons.collections_bookmark_outlined,
                              size: 48,
                              color: colorScheme.onSurfaceVariant,
                            );
                          },
                        )
                      : Icon(
                          Icons.collections_bookmark_outlined,
                          size: 48,
                          color: colorScheme.onSurfaceVariant,
                        ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _album?.name ?? 'Album Details',
                      style: textTheme.headlineMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_album?.description != null &&
                        _album!.description!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        _album!.description!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      '${_files.length} ${_files.length == 1 ? "photo" : "photos"}',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_album == null) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Album not found'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => context.go('/photos'),
                child: const Text('Back to Photos'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Column(
        children: [
          _buildHeader(context),
          Expanded(
            child: _files.isEmpty
                ? Center(
                    child: Text(
                      'No photos in this album yet',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  )
                : PhotoGrid(
                    files: _files,
                    selectedIds: _selectedIds,
                  ),
          ),
        ],
      ),
    );
  }
}
