import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class CustomPathProviderPlatform extends PathProviderPlatform {
  final PathProviderPlatform original;
  final String customSupportPath;

  CustomPathProviderPlatform(this.original, this.customSupportPath);

  @override
  Future<String?> getTemporaryPath() => original.getTemporaryPath();

  @override
  Future<String?> getApplicationSupportPath() async => customSupportPath;

  @override
  Future<String?> getLibraryPath() => original.getLibraryPath();

  @override
  Future<String?> getApplicationDocumentsPath() => original.getApplicationDocumentsPath();

  @override
  Future<String?> getExternalStoragePath() => original.getExternalStoragePath();

  @override
  Future<List<String>?> getExternalCachePaths() => original.getExternalCachePaths();

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) =>
      original.getExternalStoragePaths(type: type);

  @override
  Future<String?> getDownloadsPath() => original.getDownloadsPath();
}
