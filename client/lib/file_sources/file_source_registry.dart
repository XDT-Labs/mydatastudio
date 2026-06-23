import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/file_sources/file_source_provider.dart';
import 'package:mydatastudio/file_sources/google_drive/google_drive_provider.dart';
import 'package:mydatastudio/file_sources/local/local_file_provider.dart';
import 'package:mydatastudio/models/tables/collection.dart';

/// Central factory that maps a [Collection.scanner] string to the correct
/// [FileSourceProvider].
///
/// All UI action services (download, delete, open) must resolve their provider
/// through this registry — never instantiate providers directly in UI code.
///
/// ### Adding a new provider
/// 1. Implement [FileSourceProvider].
/// 2. Add the new constant to [AppConstants].
/// 3. Register the mapping here.
class FileSourceRegistry {
  FileSourceRegistry._();

  static final Map<String, FileSourceProvider> _providers = {
    AppConstants.scannerFileLocal: LocalFileProvider(),
    AppConstants.scannerFileGDrive: GoogleDriveProvider(),
    // AppConstants.scannerFileDropbox: DropboxProvider(),      // future
  };

  /// Returns the [FileSourceProvider] for the given [collection].
  ///
  /// Throws [ArgumentError] if no provider is registered for
  /// [Collection.scanner].
  static FileSourceProvider forCollection(Collection collection) {
    final provider = _providers[collection.scanner];
    if (provider == null) {
      throw ArgumentError(
        'No FileSourceProvider registered for scanner "${collection.scanner}". '
        'Register it in FileSourceRegistry._providers.',
      );
    }
    return provider;
  }

  /// Returns `true` if a provider exists for [scannerType].
  static bool isSupported(String scannerType) =>
      _providers.containsKey(scannerType);

  /// Registers (or replaces) a provider at runtime. Useful for testing.
  static void register(String scannerType, FileSourceProvider provider) {
    _providers[scannerType] = provider;
  }
}
