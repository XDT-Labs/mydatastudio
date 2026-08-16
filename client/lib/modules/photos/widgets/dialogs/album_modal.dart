import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/album.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:uuid/uuid.dart';

enum AlbumModalMode { addToExisting, createNew }

/// Modal dialog for adding selected files to an existing album or creating a new album.
class AlbumModal extends StatefulWidget {
  final Set<String> selectedFileIds;
  final AlbumModalMode initialMode;
  final PhotosRepository? photosRepository;

  const AlbumModal({
    super.key,
    required this.selectedFileIds,
    this.initialMode = AlbumModalMode.addToExisting,
    this.photosRepository,
  });

  @override
  State<AlbumModal> createState() => _AlbumModalState();
}

class _AlbumModalState extends State<AlbumModal> {
  late AlbumModalMode _mode;
  late final PhotosRepository _repo;

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descController = TextEditingController();

  List<({Album album, int count})> _albumsWithCounts = [];
  bool _isLoading = true;
  final Set<String> _selectedAlbumIds = {};
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _repo = widget.photosRepository ?? PhotosRepository();
    _loadAlbums();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    super.dispose();
  }

  Future<void> _loadAlbums() async {
    setState(() => _isLoading = true);
    final albums = await _repo.allAlbumsWithCounts();
    if (mounted) {
      setState(() {
        _albumsWithCounts = albums;
        _isLoading = false;
        if (albums.isNotEmpty && _selectedAlbumIds.isEmpty) {
          _selectedAlbumIds.add(albums.first.album.id);
        }
      });
    }
  }

  Future<void> _handleAddToExisting() async {
    if (_selectedAlbumIds.isEmpty || _isSubmitting) return;

    setState(() => _isSubmitting = true);
    try {
      final selectedAlbums =
          _albumsWithCounts
              .where((a) => _selectedAlbumIds.contains(a.album.id))
              .toList();

      await _repo.addFilesToAlbums(widget.selectedFileIds, _selectedAlbumIds);

      if (mounted) {
        final names = selectedAlbums.map((a) => '"${a.album.name}"').join(', ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Added ${widget.selectedFileIds.length} item(s) to $names',
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to add to album: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _handleCreateAndAdd() async {
    if (!_formKey.currentState!.validate() || _isSubmitting) return;

    setState(() => _isSubmitting = true);
    try {
      final title = _titleController.text.trim();
      final description = _descController.text.trim();

      final coverId =
          widget.selectedFileIds.isEmpty ? null : widget.selectedFileIds.first;

      final newAlbum = Album(
        id: const Uuid().v4(),
        name: title,
        description: description.isEmpty ? null : description,
        coverFileId: coverId,
      );

      await _repo.createAlbum(newAlbum);
      await _repo.addFilesToAlbums(widget.selectedFileIds, [newAlbum.id]);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Created album "$title" and added ${widget.selectedFileIds.length} item(s)',
            ),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to create album: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Widget _buildTabToggle(ColorScheme colorScheme) {
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8.0),
      ),
      padding: const EdgeInsets.all(4.0),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _mode = AlbumModalMode.addToExisting),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                decoration: BoxDecoration(
                  color:
                      _mode == AlbumModalMode.addToExisting
                          ? colorScheme.primary
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(6.0),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Add to Existing Album',
                  style: TextStyle(
                    color:
                        _mode == AlbumModalMode.addToExisting
                            ? colorScheme.onPrimary
                            : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _mode = AlbumModalMode.createNew),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                decoration: BoxDecoration(
                  color:
                      _mode == AlbumModalMode.createNew
                          ? colorScheme.primary
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(6.0),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Create New Album',
                  style: TextStyle(
                    color:
                        _mode == AlbumModalMode.createNew
                            ? colorScheme.onPrimary
                            : colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExistingAlbumList(ColorScheme colorScheme, TextTheme textTheme) {
    if (_isLoading) {
      return const SizedBox(
        height: 180,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_albumsWithCounts.isEmpty) {
      return SizedBox(
        height: 180,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.collections_bookmark_outlined,
                size: 40,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 8),
              Text(
                'No albums found',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Switch to "Create New Album" tab to start one',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      height: 220,
      child: ListView.builder(
        itemCount: _albumsWithCounts.length,
        itemBuilder: (context, index) {
          final item = _albumsWithCounts[index];
          final album = item.album;
          final count = item.count;
          final isSelected = _selectedAlbumIds.contains(album.id);

          return CheckboxListTile(
            value: isSelected,
            onChanged: (val) {
              setState(() {
                if (val == true) {
                  _selectedAlbumIds.add(album.id);
                } else {
                  _selectedAlbumIds.remove(album.id);
                }
              });
            },
            activeColor: colorScheme.primary,
            title: Text(
              album.name,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              '$count ${count == 1 ? "item" : "items"}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            secondary: Icon(
              Icons.photo_album_outlined,
              color:
                  isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
            ),
          );
        },
      ),
    );
  }

  Widget _buildCreateNewForm(ColorScheme colorScheme, TextTheme textTheme) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _titleController,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Album Title *',
              hintText: 'e.g. Summer Vacation 2026',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Please enter an album title';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _descController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Description (Optional)',
              hintText: 'Add details about this collection...',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Dialog(
      backgroundColor: colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.library_add_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Album Management',
                    style: textTheme.titleLarge?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildTabToggle(colorScheme),
            const SizedBox(height: 20),
            if (_mode == AlbumModalMode.addToExisting)
              _buildExistingAlbumList(colorScheme, textTheme)
            else
              _buildCreateNewForm(colorScheme, textTheme),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8.0),
                    ),
                  ),
                  onPressed:
                      _isSubmitting
                          ? null
                          : (_mode == AlbumModalMode.addToExisting
                              ? (_selectedAlbumIds.isNotEmpty &&
                                      _albumsWithCounts.isNotEmpty
                                  ? _handleAddToExisting
                                  : null)
                              : _handleCreateAndAdd),
                  child:
                      _isSubmitting
                          ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                          : Text(
                            _mode == AlbumModalMode.addToExisting
                                ? 'Add to Album'
                                : 'Create & Add',
                          ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
