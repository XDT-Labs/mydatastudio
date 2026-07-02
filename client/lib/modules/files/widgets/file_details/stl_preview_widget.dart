import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:three_js/three_js.dart' as three;
import 'package:three_js_simple_loaders/three_js_simple_loaders.dart';

/// Abstract interface enabling CI testing without OpenGL.
abstract class StlRenderer {
  void dispose();
  Widget build(BuildContext context);
}

/// Production renderer wrapping three_js.
class ThreeJsStlRenderer implements StlRenderer {
  ThreeJsStlRenderer({
    required String filePath,
    required Future<List<int>?> Function()? onDownloadGDrive,
    required VoidCallback onSetupComplete,
    required void Function(String?) onError,
    required void Function(bool) onLoading,
  }) : _filePath = filePath,
       _onDownloadGDrive = onDownloadGDrive,
       _onSetupComplete = onSetupComplete,
       _onError = onError,
       _onLoading = onLoading {
    _threeJs = three.ThreeJS(
      onSetupComplete: _onSetupComplete,
      setup: () => _initScene(),
    );
  }

  final String _filePath;
  final Future<List<int>?> Function()? _onDownloadGDrive;
  final VoidCallback _onSetupComplete;
  final void Function(String?) _onError;
  final void Function(bool) _onLoading;

  late three.ThreeJS _threeJs;
  three.OrbitControls? _orbitControls;

  @override
  void dispose() {
    _orbitControls?.deactivate();
    _orbitControls?.dispose();
    _threeJs.dispose();
  }

  @override
  Widget build(BuildContext context) => _threeJs.build();

  three.ThreeJS get threeJs => _threeJs;

  Future<void> _initScene() async {
    _onLoading(true);
    _onError(null);

    _threeJs.camera = three.PerspectiveCamera(
      45,
      _threeJs.width / _threeJs.height,
      0.1,
      2000,
    );
    _threeJs.scene = three.Scene();

    try {
      final scene = _threeJs.scene;
      final camera = _threeJs.camera as three.PerspectiveCamera;

      scene.background = three.Color.fromHex32(0x222222);

      final ambientLight = three.AmbientLight(0xffffff, 0.8);
      scene.add(ambientLight);

      final pointLight = three.PointLight(0xffffff, 1.2);
      camera.add(pointLight);
      scene.add(camera);

      final dirLight = three.DirectionalLight(0xffffff, 0.6);
      dirLight.position.setValues(1, 2, 1);
      scene.add(dirLight);

      final loader = STLLoader();
      three.Mesh? mesh;

      if (_filePath.startsWith('gdrive://') && _onDownloadGDrive != null) {
        final bytes = await _onDownloadGDrive();
        if (bytes != null) {
          final tempDir = await getTemporaryDirectory();
          final tempFile = io.File(p.join(tempDir.path, 'temp_preview.stl'));
          await tempFile.writeAsBytes(bytes);
          mesh = await loader.fromFile(tempFile);
        }
      } else {
        final file = io.File(_filePath);
        if (!await file.exists()) throw 'File does not exist: $_filePath';
        mesh = await loader.fromFile(file);
      }

      if (mesh == null) throw 'Could not load STL mesh';
      final geometry = mesh.geometry!;

      final material = three.MeshPhongMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0x3366ff),
        three.MaterialProperty.specular: three.Color.fromHex32(0x444444),
        three.MaterialProperty.shininess: 80,
      });

      mesh.material = material;
      geometry.computeBoundingBox();
      geometry.center();
      scene.add(mesh);

      final boundingBox = geometry.boundingBox!;
      final size = three.Vector3();
      boundingBox.getSize(size);
      final maxDim = [size.x, size.y, size.z].reduce((a, b) => a > b ? a : b);

      camera.position.setValues(0, maxDim * 0.5, maxDim * 2.5);
      camera.lookAt(three.Vector3(0, 0, 0));
      camera.updateProjectionMatrix();

      final controls = three.OrbitControls(camera, _threeJs.globalKey);
      controls.enableDamping = true;
      controls.dampingFactor = 0.08;
      controls.autoRotate = true;
      controls.autoRotateSpeed = 2.0;
      controls.enableZoom = true;
      controls.zoomSpeed = 1.2;
      controls.enableRotate = true;
      controls.rotateSpeed = 0.8;
      controls.enablePan = false;
      controls.minDistance = maxDim * 0.5;
      controls.maxDistance = maxDim * 8.0;
      controls.update();
      _orbitControls = controls;

      _threeJs.addAnimationEvent((_) => controls.update());
    } catch (e) {
      _onError(e.toString());
    } finally {
      _onLoading(false);
    }
  }
}

class StlPreviewWidget extends StatefulWidget {
  const StlPreviewWidget({
    super.key,
    required this.file,
    required this.previewHeight,
    required this.resolvedPath,
    this.onDownloadGDrive,
    @visibleForTesting this.rendererFactory,
  });

  final File file;
  final double previewHeight;
  final String resolvedPath;
  final Future<List<int>?> Function()? onDownloadGDrive;

  /// Injected in tests to avoid platform channels / OpenGL.
  final StlRenderer Function(File)? rendererFactory;

  @override
  State<StlPreviewWidget> createState() => _StlPreviewWidgetState();
}

class _StlPreviewWidgetState extends State<StlPreviewWidget> {
  StlRenderer? _renderer;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _createRenderer();
  }

  @override
  void didUpdateWidget(StlPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _renderer?.dispose();
      _renderer = null;
      setState(() {
        _loading = true;
        _error = null;
      });
      _createRenderer();
    }
  }

  void _createRenderer() {
    if (widget.rendererFactory != null) {
      _renderer = widget.rendererFactory!(widget.file);
      setState(() => _loading = false);
    } else {
      _renderer = ThreeJsStlRenderer(
        filePath: widget.resolvedPath,
        onDownloadGDrive: widget.onDownloadGDrive,
        onSetupComplete: () {
          if (mounted) setState(() {});
        },
        onError: (e) {
          if (mounted) setState(() => _error = e);
        },
        onLoading: (v) {
          if (mounted) setState(() => _loading = v);
        },
      );
    }
  }

  @override
  void dispose() {
    _renderer?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.previewHeight,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border.all(color: Colors.blue.withValues(alpha: 0.5)),
      ),
      child: Stack(
        children: [
          if (_renderer != null)
            KeyedSubtree(
              key: ValueKey(widget.file.path),
              child: _renderer!.build(context),
            ),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
