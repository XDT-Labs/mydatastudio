import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';

/// Floating trip playback controller overlay for the [PhotoMapView].
class TripPlaybackController extends StatefulWidget {
  const TripPlaybackController({
    super.key,
    required this.geoFiles,
    required this.mapController,
    this.onActiveFileChanged,
    this.onFileSelected,
  });

  final List<File> geoFiles;
  final MapController mapController;
  final ValueChanged<File?>? onActiveFileChanged;
  final VoidCallback? onFileSelected;

  @override
  State<TripPlaybackController> createState() => _TripPlaybackControllerState();
}

class _TripPlaybackControllerState extends State<TripPlaybackController> {
  int _currentIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0; // 1.0x, 2.0x, 4.0x
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.geoFiles.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyActiveFile();
      });
    }
  }

  @override
  void didUpdateWidget(TripPlaybackController oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.geoFiles != oldWidget.geoFiles) {
      if (_currentIndex >= widget.geoFiles.length) {
        _currentIndex = 0;
      }
      _notifyActiveFile();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _notifyActiveFile() {
    if (widget.geoFiles.isEmpty) {
      widget.onActiveFileChanged?.call(null);
      return;
    }
    final file = widget.geoFiles[_currentIndex];
    widget.onActiveFileChanged?.call(file);
  }

  void _startTimer() {
    _timer?.cancel();
    final intervalMs = (3000 / _playbackSpeed).round();
    _timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      _advance();
    });
  }

  void _pause() {
    _timer?.cancel();
    setState(() {
      _isPlaying = false;
    });
  }

  void _advance() {
    if (_currentIndex < widget.geoFiles.length - 1) {
      setState(() {
        _currentIndex++;
      });
      _panToCurrentAndNotify();
    } else {
      _pause();
    }
  }

  void _togglePlayPause() {
    if (widget.geoFiles.isEmpty) return;

    if (_isPlaying) {
      _pause();
    } else {
      if (_currentIndex >= widget.geoFiles.length - 1) {
        setState(() {
          _currentIndex = 0;
        });
      }
      setState(() {
        _isPlaying = true;
      });
      _panToCurrentAndNotify();
      _startTimer();
    }
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _currentIndex = 0;
      _isPlaying = false;
    });
    _panToCurrentAndNotify();
  }

  void _panToCurrentAndNotify() {
    if (widget.geoFiles.isEmpty) return;
    final file = widget.geoFiles[_currentIndex];
    _notifyActiveFile();
    if (file.latitude != null && file.longitude != null) {
      widget.mapController.move(
        LatLng(file.latitude!, file.longitude!),
        widget.mapController.camera.zoom,
      );
    }
  }

  Widget _buildThumbnail(File file, ThemeData theme) {
    final provider = ThumbnailResolver.providerFor(file.thumbnail);
    if (provider != null) {
      return Image(
        image: provider,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildFallbackIcon(theme),
      );
    }
    return _buildFallbackIcon(theme);
  }

  Widget _buildFallbackIcon(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.photo,
        size: 16,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.geoFiles.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final maxVal = (widget.geoFiles.length - 1).toDouble();
    final sliderVal = _currentIndex.toDouble().clamp(0.0, maxVal > 0 ? maxVal : 1.0);
    final divisions = widget.geoFiles.length > 1 ? widget.geoFiles.length - 1 : null;
    final currentFile = widget.geoFiles[_currentIndex];

    return Card(
      elevation: 6,
      color: colorScheme.surfaceContainerHigh.withOpacity(0.95),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Play / Pause Button
            IconButton(
              key: const Key('trip_playback_play_pause_button'),
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              color: colorScheme.primary,
              onPressed: _togglePlayPause,
              tooltip: _isPlaying ? 'Pause playback' : 'Play trip playback',
            ),

            // Reset Button
            IconButton(
              key: const Key('trip_playback_reset_button'),
              icon: const Icon(Icons.skip_previous),
              color: colorScheme.onSurfaceVariant,
              onPressed: _reset,
              tooltip: 'Reset to start',
            ),

            const SizedBox(width: 4),

            // Speed Dropdown
            DropdownButtonHideUnderline(
              child: DropdownButton<double>(
                key: const Key('trip_playback_speed_dropdown'),
                value: _playbackSpeed,
                dropdownColor: colorScheme.surfaceContainerHigh,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text('1x')),
                  DropdownMenuItem(value: 2.0, child: Text('2x')),
                  DropdownMenuItem(value: 4.0, child: Text('4x')),
                ],
                onChanged: (val) {
                  if (val == null) return;
                  setState(() {
                    _playbackSpeed = val;
                  });
                  if (_isPlaying) {
                    _startTimer();
                  }
                },
              ),
            ),

            const SizedBox(width: 8),

            // Progress Slider
            SizedBox(
              width: 140,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  activeTrackColor: colorScheme.primary,
                  inactiveTrackColor: colorScheme.surfaceContainerHighest,
                  thumbColor: colorScheme.primary,
                ),
                child: Slider(
                  key: const Key('trip_playback_slider'),
                  value: maxVal > 0 ? sliderVal : 0.0,
                  min: 0.0,
                  max: maxVal > 0 ? maxVal : 1.0,
                  divisions: divisions,
                  onChanged: maxVal > 0
                      ? (val) {
                          setState(() {
                            _currentIndex = val.round();
                          });
                          _panToCurrentAndNotify();
                        }
                      : null,
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Current Photo Info
            InkWell(
              onTap: () {
                widget.onFileSelected?.call();
                ViewStateService.instance.openInfo(currentFile);
              },
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: _buildThumbnail(currentFile, theme),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            currentFile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colorScheme.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (currentFile.latitude != null &&
                              currentFile.longitude != null)
                            Text(
                              '${currentFile.latitude!.toStringAsFixed(2)}, ${currentFile.longitude!.toStringAsFixed(2)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 10,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
