import 'package:mydatastudio/modules/files/services/scanners/onedrive_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_scanner.dart';

/// OneDrive scanner registered for `file.onedrive` collections. Only plugs a
/// [OneDriveFileApi] factory into the provider-neutral [CloudFileScanner].
class OneDriveFileIsolate extends CloudFileScanner {
  OneDriveFileIsolate(
    super.loggerIsolatePort, {
    super.storagePath,
    super.appDir,
    super.dbName,
  }) : super(apiFactory: OneDriveFileApi.create);
}
