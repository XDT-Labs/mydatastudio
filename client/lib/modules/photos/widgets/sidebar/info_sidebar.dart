import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';

/// A right slide-over sidebar for inspecting and editing photo metadata,
/// tags, and album membership.
class InfoSidebar extends StatefulWidget {
  const InfoSidebar({
    super.key,
    this.repository,
  });

  final PhotosRepository? repository;

  @override
  State<InfoSidebar> createState() => _InfoSidebarState();
}

class _InfoSidebarState extends State<InfoSidebar> {
  StreamSubscription<File?>? _infoMediaSub;
  File? _currentFile;
  bool _isEditingTitle = false;
  late final TextEditingController _titleController;
  late final TextEditingController _tagController;

  List<String> _tags = [];
  List<Album> _allAlbums = [];
  Set<String> _fileAlbumIds = {};

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _tagController = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _infoMediaSub = ViewStateService.instance.infoMedia.listen((file) {
        if (mounted) _onFileChanged(file);
      });
    });
  }

  @override
  void dispose() {
    _infoMediaSub?.cancel();
    _titleController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _onFileChanged(File? file) {
    setState(() {
      _currentFile = file;
      _isEditingTitle = false;
      _titleController.text = file?.name ?? '';
    });
    if (file != null) {
      _loadTagsAndAlbums(file.id);
    } else {
      setState(() {
        _tags = [];
        _allAlbums = [];
        _fileAlbumIds = {};
      });
    }
  }

  Future<void> _loadTagsAndAlbums(String fileId) async {
    final repo = widget.repository ?? PhotosRepository();
    final tags = await repo.getTagsForFile(fileId);
    final albums = await repo.allAlbums();
    final fileAlbums = await repo.getAlbumsForFile(fileId);
    if (mounted && _currentFile?.id == fileId) {
      setState(() {
        _tags = tags;
        _allAlbums = albums;
        _fileAlbumIds = fileAlbums.map((a) => a.id).toSet();
      });
    }
  }

  Future<void> _submitTitle() async {
    if (_currentFile == null) return;
    final newName = _titleController.text.trim();
    if (newName.isEmpty || newName == _currentFile!.name) {
      setState(() {
        _isEditingTitle = false;
      });
      return;
    }
    final fileId = _currentFile!.id;
    final repo = widget.repository ?? PhotosRepository();
    final updatedFile = await repo.updateFileName(fileId, newName);
    final nextFile = updatedFile ?? await repo.getFile(fileId);

    if (mounted && (nextFile != null || _currentFile?.id == fileId)) {
      final fileToPublish = nextFile ?? File(
        id: _currentFile!.id,
        name: newName,
        collectionId: _currentFile!.collectionId,
        path: _currentFile!.path,
        parent: _currentFile!.parent,
        size: _currentFile!.size,
        contentType: _currentFile!.contentType,
        dateCreated: _currentFile!.dateCreated,
        dateLastModified: _currentFile!.dateLastModified,
        thumbnail: _currentFile!.thumbnail,
        latitude: _currentFile!.latitude,
        longitude: _currentFile!.longitude,
        isFavorite: _currentFile!.isFavorite,
        isDeleted: _currentFile!.isDeleted,
        description: _currentFile!.description,
      );

      setState(() {
        _currentFile = fileToPublish;
        _isEditingTitle = false;
      });
      ViewStateService.instance.infoMedia.add(fileToPublish);
    }
  }

  Future<void> _addTag() async {
    final text = _tagController.text.trim();
    if (text.isEmpty || _currentFile == null) return;
    final fileId = _currentFile!.id;
    final repo = widget.repository ?? PhotosRepository();
    await repo.addTag(fileId, text);
    _tagController.clear();
    final tags = await repo.getTagsForFile(fileId);
    if (mounted && _currentFile?.id == fileId) {
      setState(() {
        _tags = tags;
      });
    }
  }

  Future<void> _removeTag(String tag) async {
    if (_currentFile == null) return;
    final fileId = _currentFile!.id;
    final repo = widget.repository ?? PhotosRepository();
    await repo.removeTag(fileId, tag);
    final tags = await repo.getTagsForFile(fileId);
    if (mounted && _currentFile?.id == fileId) {
      setState(() {
        _tags = tags;
      });
    }
  }

  Future<void> _toggleAlbum(Album album, bool isMember) async {
    if (_currentFile == null) return;
    final fileId = _currentFile!.id;
    final repo = widget.repository ?? PhotosRepository();
    if (isMember) {
      await repo.addFileToAlbum(fileId, album.id);
    } else {
      await repo.removeFileFromAlbum(fileId, album.id);
    }
    final fileAlbums = await repo.getAlbumsForFile(fileId);
    if (mounted && _currentFile?.id == fileId) {
      setState(() {
        _fileAlbumIds = fileAlbums.map((a) => a.id).toSet();
      });
    }
  }

  Future<void> _openInFinder(String path) async {
    try {
      await Process.run('open', ['-R', path]);
    } catch (_) {}
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = (log(bytes) / log(1024)).floor();
    i = i.clamp(0, suffixes.length - 1);
    final num val = bytes / pow(1024, i);
    if (i == 0) return '$bytes B';
    return '${val.toStringAsFixed(1)} ${suffixes[i]}';
  }

  String _formatLocation(double? lat, double? lng) {
    if (lat == null || lng == null) return 'Unknown';
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final file = _currentFile;
    if (file == null) {
      return Material(
        color: colorScheme.surfaceContainer,
        child: Center(
          child: Text(
            'No file selected',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    final imageProvider = ThumbnailResolver.providerFor(file.thumbnail);
    final isVideo = file.contentType.startsWith('video/');

    return Material(
      color: colorScheme.surfaceContainer,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Header bar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Details',
                    style: textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => ViewStateService.instance.closeInfo(),
                    tooltip: 'Close',
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 2. Preview card
              ClipRRect(
                borderRadius: BorderRadius.circular(8.0),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: GestureDetector(
                    onTap: () => ViewStateService.instance.openLightbox(file),
                    child: Container(
                      color: colorScheme.surfaceContainerHighest,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (imageProvider != null)
                            Image(
                              image: imageProvider,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (ctx, err, stack) => Icon(
                                isVideo ? Icons.videocam : Icons.image,
                                size: 48,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            )
                          else
                            Icon(
                              isVideo ? Icons.videocam : Icons.image,
                              size: 48,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          if (isVideo)
                            Container(
                              decoration: const BoxDecoration(
                                color: Colors.black45,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(8.0),
                              child: const Icon(
                                Icons.play_arrow,
                                size: 32,
                                color: Colors.white,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // 3. Title section
              if (_isEditingTitle)
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _titleController,
                        autofocus: true,
                        style: textTheme.titleSmall?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _submitTitle(),
                      ),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.check),
                      onPressed: _submitTitle,
                      tooltip: 'Save title',
                    ),
                  ],
                )
              else
                InkWell(
                  onTap: () => setState(() => _isEditingTitle = true),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 4.0,
                      horizontal: 2.0,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            file.name,
                            style: textTheme.titleSmall?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.edit,
                          size: 16,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              const Divider(height: 24),

              // 4. EXIF data grid
              Text(
                'Information',
                style: textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const _MetadataRow(label: 'Resolution', value: 'Unknown'),
              _MetadataRow(
                label: 'File Size',
                value: _formatBytes(file.size),
              ),
              _MetadataRow(
                label: 'Content Type',
                value: file.contentType,
              ),
              _MetadataRow(
                label: 'Date Created',
                value: DateFormat.yMMMd().add_jm().format(file.dateCreated),
              ),
              _MetadataRow(
                label: 'Location',
                value: _formatLocation(file.latitude, file.longitude),
              ),
              _MetadataRow(
                label: 'Source',
                value: file.collectionId,
              ),
              const Divider(height: 24),

              // 5. Tags section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Tags (${_tags.length})',
                    style: textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_tags.isEmpty)
                Text(
                  'No tags assigned',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Wrap(
                  spacing: 6.0,
                  runSpacing: 6.0,
                  children: _tags.map((tag) {
                    return TagChip(
                      tag: tag,
                      onTap: () {},
                      onRemove: () => _removeTag(tag),
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _tagController,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurface,
                      ),
                      decoration: const InputDecoration(
                        hintText: 'Add new tag...',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addTag(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _addTag,
                    child: const Text('Add'),
                  ),
                ],
              ),
              const Divider(height: 24),

              // 6. Album membership section
              Text(
                'Albums',
                style: textTheme.titleSmall?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              if (_allAlbums.isEmpty)
                Text(
                  'No albums created',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                Column(
                  children: _allAlbums.map((album) {
                    final isMember = _fileAlbumIds.contains(album.id);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        album.name,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                      value: isMember,
                      onChanged: (checked) =>
                          _toggleAlbum(album, checked ?? false),
                    );
                  }).toList(),
                ),
              const Divider(height: 24),

              // 7. Action buttons (bottom)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openInFinder(file.path),
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Open in Finder'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.error,
                        side: BorderSide(color: colorScheme.error),
                      ),
                      onPressed: () async {
                        final repo = widget.repository ?? PhotosRepository();
                        await repo.deleteFile(file.id);
                        await PhotosService.instance.refresh();
                        ViewStateService.instance.closeInfo();
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
