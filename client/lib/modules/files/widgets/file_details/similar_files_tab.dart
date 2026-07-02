import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

class SimilarFilesTab extends StatefulWidget {
  const SimilarFilesTab({
    super.key,
    required this.file,
    required this.collection,
    this.onNavigateToFile,
    this.onDeleteFile,
  });

  final File file;
  final Collection collection;
  final void Function(File)? onNavigateToFile;
  final void Function(File)? onDeleteFile;

  @override
  State<SimilarFilesTab> createState() => _SimilarFilesTabState();
}

class _SimilarFilesTabState extends State<SimilarFilesTab> {
  double _threshold = 80.0;
  bool _loading = true;
  bool _noEmbedding = false;
  List<({File file, double similarity})> _allResults = [];

  @override
  void initState() {
    super.initState();
    _runSearch();
  }

  @override
  void didUpdateWidget(SimilarFilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id) {
      setState(() {
        _loading = true;
        _noEmbedding = false;
        _allResults = [];
      });
      _runSearch();
    }
  }

  Future<void> _runSearch() async {
    final repo = DatabaseManager.instance.repository;
    if (repo == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final embedding = await repo.getFileSiglip2Embedding(widget.file.id);
    if (!mounted) return;
    if (embedding == null) {
      setState(() {
        _loading = false;
        _noEmbedding = true;
      });
      return;
    }

    final results = await repo.findSimilarImages(
      embedding,
      excludeFileId: widget.file.id,
    );
    if (!mounted) return;
    setState(() {
      _allResults = results;
      _loading = false;
    });
  }

  List<({File file, double similarity})> get _filtered =>
      _allResults.where((r) => r.similarity >= _threshold).toList();

  // ── Lightbox ──────────────────────────────────────────────────────────────

  void _showLightbox(BuildContext context, File file) {
    showDialog(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.all(24),
            child: Stack(
              alignment: Alignment.topRight,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.8,
                    maxWidth: MediaQuery.of(ctx).size.width * 0.8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: _lightboxContent(file),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Widget _lightboxContent(File file) {
    if (file.thumbnail != null) {
      try {
        if (file.thumbnail!.startsWith('http')) {
          return Image.network(file.thumbnail!, fit: BoxFit.contain);
        }
        return Image.memory(base64Decode(file.thumbnail!), fit: BoxFit.contain);
      } catch (_) {}
    }
    if (file.path.startsWith('/')) {
      final ioFile = io.File(file.path);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
    }
    return const Center(
      child: Icon(Icons.photo, color: Colors.white54, size: 80),
    );
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _handleDelete(BuildContext context, File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete Image'),
            content: Text(
              'Delete "${file.name}" from your computer and database?\n\nThis cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final resolvedPath = file.localPath ?? (
          file.collectionId == widget.collection.id
              ? FilePathResolver.absolute(file, widget.collection)
              : file.path
      );
      final ioFile = io.File(resolvedPath);
      if (await ioFile.exists()) await ioFile.delete();

      await FileDesktopRepository(
        DatabaseManager.instance.database!,
      ).delete(file);

      if (!mounted) return;
      setState(() => _allResults.removeWhere((r) => r.file.id == file.id));
      widget.onDeleteFile?.call(file);

      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${file.name}"')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting "${file.name}": $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [_buildSliderRow(), Expanded(child: _buildContent(context))],
    );
  }

  Widget _buildSliderRow() {
    return Row(
      children: [
        const SizedBox(width: 8),
        Text(
          'Min similarity: ${_threshold.round()}%',
          style: const TextStyle(fontSize: 11),
        ),
        Expanded(
          child: Slider(
            value: _threshold,
            min: 0,
            max: 100,
            divisions: 20,
            onChanged: (v) => setState(() => _threshold = v),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_noEmbedding) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 40,
              color: Colors.grey,
            ),
            SizedBox(height: 8),
            Text(
              'Visual embeddings for this image are still being generated',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final results = _filtered;
    if (results.isEmpty) {
      return Center(
        child: Text(
          'No images above ${_threshold.round()}% similarity',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 0.7,
      ),
      itemCount: results.length,
      itemBuilder: (_, index) {
        final item = results[index];
        return _SimilarImageCell(
          file: item.file,
          similarity: item.similarity,
          onTap: () => _showLightbox(context, item.file),
          onNavigate: () => widget.onNavigateToFile?.call(item.file),
          onDelete: () => _handleDelete(context, item.file),
        );
      },
    );
  }
}

class _SimilarImageCell extends StatelessWidget {
  const _SimilarImageCell({
    required this.file,
    required this.similarity,
    required this.onTap,
    required this.onNavigate,
    required this.onDelete,
  });

  final File file;
  final double similarity;
  final VoidCallback onTap;
  final VoidCallback onNavigate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildImage(),
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        '${similarity.round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Tooltip(
              message: 'Go to folder',
              child: GestureDetector(
                onTap: onNavigate,
                child: const Icon(Icons.folder_open_outlined, size: 14),
              ),
            ),
            Tooltip(
              message: 'Delete',
              child: GestureDetector(
                onTap: onDelete,
                child: const Icon(
                  Icons.delete_outline,
                  size: 14,
                  color: Colors.redAccent,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildImage() {
    final thumb = file.thumbnail;
    if (thumb != null) {
      try {
        if (thumb.startsWith('http')) {
          return Image.network(
            thumb,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _placeholder(),
          );
        }
        return Image.memory(
          base64Decode(thumb),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _placeholder(),
        );
      } catch (_) {}
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: Colors.grey.shade800,
      child: const Icon(Icons.photo, color: Colors.grey, size: 24),
    );
  }
}
