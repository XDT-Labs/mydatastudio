import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class VideoFilePreview extends StatefulWidget {
  final String path;
  final double height;
  final bool isGDrive;
  final Future<List<int>?> Function()? onDownloadGDrive;

  const VideoFilePreview({
    super.key,
    required this.path,
    required this.height,
    this.isGDrive = false,
    this.onDownloadGDrive,
  });

  @override
  State<VideoFilePreview> createState() => _VideoFilePreviewState();
}

class _VideoFilePreviewState extends State<VideoFilePreview> {
  late final Player _player;
  late final VideoController _controller;
  bool _loading = true;
  String? _error;
  File? _tempFile;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _initPlayer();
  }

  @override
  void didUpdateWidget(VideoFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _cleanupAndRestart();
    }
  }

  Future<void> _cleanupAndRestart() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _player.stop();
    try {
      if (_tempFile != null && await _tempFile!.exists()) {
        await _tempFile!.delete();
      }
    } catch (_) {}
    _tempFile = null;
    await _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      String mediaPath;

      if (widget.isGDrive && widget.onDownloadGDrive != null) {
        debugPrint('VideoFilePreview: Downloading GDrive file...');
        final bytes = await widget.onDownloadGDrive!();
        if (bytes == null || bytes.isEmpty) {
          throw Exception('Failed to download video from Google Drive (empty response)');
        }
        debugPrint('VideoFilePreview: Downloaded ${bytes.length} bytes');
        final tempDir = await getTemporaryDirectory();
        final ext = p.extension(widget.path).isNotEmpty
            ? p.extension(widget.path)
            : '.mp4';
        final fileName = 'video_preview_${widget.path.hashCode}$ext';
        _tempFile = File(p.join(tempDir.path, fileName));
        await _tempFile!.writeAsBytes(bytes, flush: true);
        mediaPath = _tempFile!.path;
        debugPrint('VideoFilePreview: Written to temp: $mediaPath');
      } else {
        final file = File(widget.path);
        if (!await file.exists()) {
          throw Exception('File not found: ${widget.path}');
        }
        mediaPath = widget.path;
      }

      debugPrint('VideoFilePreview: Opening media: $mediaPath');
      await _player.open(Media(mediaPath), play: false);

      // Wait for the player to have the duration populated,
      // meaning it has read the file headers (buffered enough to display).
      // We listen to state rather than blindly trusting open() completion.
      final stateStream = _player.stream.duration.firstWhere(
        (d) => d > Duration.zero,
        orElse: () => Duration.zero,
      );

      // Time out after 8 seconds so we don't wait forever
      await Future.any([
        stateStream,
        Future.delayed(const Duration(seconds: 8)),
      ]);

      if (mounted) setState(() => _loading = false);
    } catch (e, stack) {
      debugPrint('VideoFilePreview error: $e\n$stack');
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    try {
      if (_tempFile != null && _tempFile!.existsSync()) {
        _tempFile!.deleteSync();
      }
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return Container(
        color: Colors.grey.shade900,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white70),
              SizedBox(height: 12),
              Text(
                'Loading video…',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        color: Colors.grey.shade100,
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.video_file, size: 40, color: Colors.grey.shade400),
              const SizedBox(height: 8),
              const Text(
                'Could not load video preview',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Video(
        controller: _controller,
        controls: MaterialVideoControls,
        fit: BoxFit.contain,
      ),
    );
  }
}
