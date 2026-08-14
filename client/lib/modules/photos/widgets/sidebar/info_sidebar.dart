import 'dart:async';
import 'dart:io' as io;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/tabbed_metadata_section.dart';
import 'package:mydatastudio/modules/photos/models/photo_source.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/utils/byte_formatter.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/tag_chip.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// A right slide-over sidebar for inspecting and editing photo metadata,
/// tags, and album membership.
class InfoSidebar extends StatefulWidget {
  const InfoSidebar({super.key, this.repository, this.tileProvider});

  final PhotosRepository? repository;

  /// Optional injected [TileProvider] for the LOCATION tab's map, for widget
  /// tests (e.g. FakeMemoryTileProvider) to avoid real network requests.
  final TileProvider? tileProvider;

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

  Collection? _collection;
  PhotoSource? _source;
  Map<String, IfdTag>? _exifData;
  bool _loadingExif = false;

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
      _collection = null;
      _source = null;
      _exifData = null;
    });
    if (file != null) {
      _loadTagsAndAlbums(file.id);
      _loadCollection(file);
      _loadSource(file);
      _loadExif(file);
    } else {
      setState(() {
        _tags = [];
        _allAlbums = [];
        _fileAlbumIds = {};
      });
    }
  }

  Future<void> _loadCollection(File file) async {
    try {
      final collection = await CollectionRepository().collectionById(
        file.collectionId,
      );
      if (mounted && _currentFile?.id == file.id) {
        setState(() => _collection = collection);
      }
    } catch (_) {
      // No DB available or the collection was deleted out from under an
      // open file — the EXIF/Location/Similar tabs just stay hidden.
    }
  }

  Future<void> _loadSource(File file) async {
    final repo = widget.repository ?? PhotosRepository();
    try {
      final source = await repo.sourceFor(file);
      if (mounted && _currentFile?.id == file.id) {
        setState(() => _source = source);
      }
    } catch (_) {
      // No DB available — the Source row falls back to the collection id.
    }
  }

  /// Opens the message this photo was attached to in the Email module.
  Future<void> _openSourceEmail(String emailId) async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;

    final emails = await EmailRepository(db).getAllById([emailId]);
    if (!mounted || emails.isEmpty) return;

    // Queued before routing: EmailPage picks the request up when it mounts.
    EmailPage.openEmailRequest.add(emails.first);
    GoRouter.of(context).go('/email');
  }

  /// Opens this photo's folder in the Files module, with the file selected.
  void _openSourceFile(File file) {
    // The photos module rewrites `path` to an absolute one for thumbnailing
    // (see PhotosRepository._fileWithAbsolutePath); the Files module navigates
    // by the DB-relative `parent`, which that rewrite leaves untouched.
    RxFilesPage.openFileRequest.add(file);
    GoRouter.of(context).go('/files');
  }

  // The photos module only ever holds images or videos (see
  // PhotosRepository's `_isMedia` filter), so "not a video" is sufficient.
  bool _isImage(File file) => !file.contentType.startsWith('video/');

  Future<void> _loadExif(File file) async {
    if (!_isImage(file)) return;

    // Photos loaded through PhotosRepository already carry an absolute
    // `path` (see photos_repository.dart's _fileWithAbsolutePath), unlike
    // the DB-relative paths File models normally hold.
    final ioFile = io.File(file.path);
    if (!await ioFile.exists()) return;

    setState(() => _loadingExif = true);
    try {
      final exif = await readExifFromFile(ioFile);
      if (mounted && _currentFile?.id == file.id) {
        setState(() => _exifData = exif);
      }
    } catch (_) {}
    if (mounted && _currentFile?.id == file.id) {
      setState(() => _loadingExif = false);
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
      final fileToPublish =
          nextFile ??
          File(
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
              _MetadataRow(label: 'File Size', value: formatBytes(file.size)),
              _MetadataRow(label: 'Content Type', value: file.contentType),
              _MetadataRow(
                label: 'Date Created',
                value: DateFormat.yMMMd().add_jm().format(file.dateCreated),
              ),
              _MetadataRow(
                label: 'Location',
                value: _formatLocation(file.latitude, file.longitude),
              ),
              _SourceRow(
                source: _source,
                fallback: file.collectionId,
                onOpenEmail: _openSourceEmail,
                onOpenFile: () => _openSourceFile(file),
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
                  TextButton(onPressed: _addTag, child: const Text('Add')),
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

              // 7. EXIF / Location / Similar tabs (same section used by the
              // Files module's file details drawer)
              if (_collection != null) ...[
                DefaultTabController(
                  length: _isImage(file) ? 3 : 1,
                  child: TabbedMetadataSection(
                    file: file,
                    collection: _collection!,
                    exifData: _exifData,
                    isLoadingExif: _loadingExif,
                    showExif: _isImage(file),
                    tileProvider: widget.tileProvider,
                    onNavigateToFile: (target) {
                      ViewStateService.instance.openInfo(target);
                    },
                    onDeleteFile: (_) {
                      PhotosService.instance.refresh();
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The `Source` row: where the photo came from, as a
/// `<collection>/<folder>/<leaf>` trail, and a way back to it.
///
/// A photo in the grid gives no clue whether it was scanned off disk or pulled
/// out of a mailbox, and no way to reach whatever surrounded it. So the trail
/// is a link in both cases — to the message for an attachment, to the folder
/// for a file.
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.fallback,
    required this.onOpenEmail,
    required this.onOpenFile,
  });

  final PhotoSource? source;

  /// Shown until [source] resolves, and if it never does.
  final String fallback;

  final Future<void> Function(String emailId) onOpenEmail;
  final VoidCallback onOpenFile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final resolved = source;

    if (resolved == null) {
      return _MetadataRow(label: 'Source', value: fallback);
    }

    final isEmail = resolved.isEmail;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              'Source',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: isEmail
                  ? () => onOpenEmail(resolved.emailId!)
                  : onOpenFile,
              borderRadius: BorderRadius.circular(4),
              child: Tooltip(
                message: isEmail
                    ? 'Open this email'
                    : 'Show this file in Files',
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1.0, right: 4.0),
                      child: Icon(
                        isEmail ? Icons.email_outlined : Icons.folder_outlined,
                        size: 13,
                        color: colorScheme.primary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        resolved.path,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w500,
                          decoration: TextDecoration.underline,
                          decorationColor: colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

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
