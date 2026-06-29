import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';

class SimilarFilesTab extends StatefulWidget {
  const SimilarFilesTab({
    super.key,
    required this.file,
    required this.collection,
  });

  final File file;
  final Collection collection;

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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildSliderRow(),
        Expanded(child: _buildContent()),
      ],
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

  Widget _buildContent() {
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
              'No visual embedding for this image',
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
        childAspectRatio: 0.85,
      ),
      itemCount: results.length,
      itemBuilder: (context, index) {
        final item = results[index];
        return _SimilarImageCell(file: item.file, similarity: item.similarity);
      },
    );
  }
}

class _SimilarImageCell extends StatelessWidget {
  const _SimilarImageCell({required this.file, required this.similarity});

  final File file;
  final double similarity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
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
        const SizedBox(height: 2),
        Text(
          file.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 9),
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
