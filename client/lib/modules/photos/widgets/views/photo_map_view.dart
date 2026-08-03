import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/views/trip_playback_controller.dart';

class _PhotoCluster {
  final List<File> files;
  final LatLng center;

  _PhotoCluster({required this.files, required this.center});
}

/// Interactive map view with geotagged photo markers, simple clustering,
/// polyline route lines, and trip playback controller.
class PhotoMapView extends StatefulWidget {
  const PhotoMapView({
    super.key,
    required this.files,
    required this.selectedIds,
    this.tileProvider,
  });

  final List<File> files;
  final Set<String> selectedIds;

  /// Optional injected [TileProvider] for widget tests (e.g. FakeMemoryTileProvider).
  final TileProvider? tileProvider;

  @override
  State<PhotoMapView> createState() => _PhotoMapViewState();
}

class _PhotoMapViewState extends State<PhotoMapView> {
  late final MapController _mapController;
  double _currentZoom = 10.0;
  File? _activePlaybackFile;
  late List<File> _cachedGeoFiles;

  List<File> get _geoFiles => _cachedGeoFiles;

  void _recomputeGeoFiles() {
    final validFiles = widget.files
        .where((f) => f.latitude != null && f.longitude != null)
        .toList();
    validFiles.sort((a, b) => a.dateCreated.compareTo(b.dateCreated));
    _cachedGeoFiles = validFiles;
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _recomputeGeoFiles();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fitBounds();
    });
  }

  @override
  void didUpdateWidget(PhotoMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.files != oldWidget.files) {
      _recomputeGeoFiles();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitBounds();
      });
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _fitBounds() {
    final geo = _geoFiles;
    if (geo.isEmpty) return;

    final points = geo.map((f) => LatLng(f.latitude!, f.longitude!)).toList();
    if (points.length == 1) {
      _mapController.move(points.first, 12.0);
    } else {
      final bounds = LatLngBounds.fromPoints(points);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(40.0),
        ),
      );
    }
  }

  List<_PhotoCluster> _clusterFiles(List<File> files, double threshold) {
    final List<_PhotoCluster> clusters = [];

    for (final file in files) {
      final lat = file.latitude!;
      final lng = file.longitude!;
      bool added = false;

      for (var i = 0; i < clusters.length; i++) {
        final c = clusters[i];
        final dLat = (c.center.latitude - lat).abs();
        final dLng = (c.center.longitude - lng).abs();
        if (dLat < threshold && dLng < threshold) {
          c.files.add(file);
          final newLat =
              (c.center.latitude * (c.files.length - 1) + lat) / c.files.length;
          final newLng =
              (c.center.longitude * (c.files.length - 1) + lng) / c.files.length;
          clusters[i] = _PhotoCluster(
            files: c.files,
            center: LatLng(newLat, newLng),
          );
          added = true;
          break;
        }
      }

      if (!added) {
        clusters.add(
          _PhotoCluster(
            files: [file],
            center: LatLng(lat, lng),
          ),
        );
      }
    }

    return clusters;
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
        size: 20,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Marker _buildSingleMarker(File file, ThemeData theme) {
    final isActive = _activePlaybackFile?.id == file.id;
    final isSelected = widget.selectedIds.contains(file.id);
    final colorScheme = theme.colorScheme;

    final borderColor =
        isSelected ? colorScheme.secondary : colorScheme.primary;

    return Marker(
      point: LatLng(file.latitude!, file.longitude!),
      width: 44,
      height: 44,
      child: GestureDetector(
        key: Key('photo_marker_${file.id}'),
        onTap: () {
          ViewStateService.instance.openInfo(file);
        },
        child: AnimatedScale(
          scale: isActive ? 1.25 : 1.0,
          duration: const Duration(milliseconds: 250),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: borderColor,
                width: isSelected ? 3.0 : 2.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: isActive
                      ? colorScheme.primary.withOpacity(0.8)
                      : colorScheme.primary.withOpacity(0.4),
                  blurRadius: isActive ? 12 : 6,
                  spreadRadius: isActive ? 3 : 1,
                ),
              ],
            ),
            child: ClipOval(
              child: _buildThumbnail(file, theme),
            ),
          ),
        ),
      ),
    );
  }

  Marker _buildClusterMarker(_PhotoCluster cluster, ThemeData theme) {
    final colorScheme = theme.colorScheme;
    return Marker(
      point: cluster.center,
      width: 44,
      height: 44,
      child: GestureDetector(
        key: Key('cluster_marker_${cluster.files.first.id}'),
        onTap: () {
          final targetZoom = (_currentZoom + 2.5).clamp(0.0, 18.0);
          _mapController.move(cluster.center, targetZoom);
        },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colorScheme.primaryContainer,
            border: Border.all(
              color: colorScheme.primary,
              width: 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withOpacity(0.3),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Center(
            child: Text(
              '${cluster.files.length}',
              style: TextStyle(
                color: colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Marker> _buildMarkers(List<File> geoFiles, ThemeData theme) {
    final List<Marker> markers = [];
    if (_currentZoom < 8.0) {
      final clusters = _clusterFiles(geoFiles, 0.5);
      for (final cluster in clusters) {
        if (cluster.files.length == 1) {
          markers.add(_buildSingleMarker(cluster.files.first, theme));
        } else {
          markers.add(_buildClusterMarker(cluster, theme));
        }
      }
    } else {
      for (final file in geoFiles) {
        markers.add(_buildSingleMarker(file, theme));
      }
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final geo = _geoFiles;

    if (geo.isEmpty) {
      return Container(
        key: const Key('photo_map_empty_state'),
        color: theme.colorScheme.surface,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.map_outlined,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                'No geotagged photos found',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Photos with GPS coordinates will appear on the map',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final initialCenter = LatLng(geo.first.latitude!, geo.first.longitude!);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: _currentZoom,
            onPositionChanged: (position, hasGesture) {
              if (position.zoom != _currentZoom) {
                setState(() {
                  _currentZoom = position.zoom;
                });
              }
            },
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.mydatastudio.app',
              tileProvider: widget.tileProvider,
            ),
            if (geo.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points:
                        geo.map((f) => LatLng(f.latitude!, f.longitude!)).toList(),
                    strokeWidth: 3.0,
                    color: theme.colorScheme.primary.withValues(alpha: 0.5),
                    pattern: const StrokePattern.dotted(),
                  ),
                ],
              ),
            MarkerLayer(
              markers: _buildMarkers(geo, theme),
            ),
            SimpleAttributionWidget(
              source: Text(
                '© OpenStreetMap contributors, © CARTO',
                style: TextStyle(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
        Positioned(
          bottom: 24,
          left: 0,
          right: 0,
          child: Center(
            child: TripPlaybackController(
              geoFiles: geo,
              mapController: _mapController,
              onActiveFileChanged: (file) {
                if (mounted && _activePlaybackFile?.id != file?.id) {
                  setState(() {
                    _activePlaybackFile = file;
                  });
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}
