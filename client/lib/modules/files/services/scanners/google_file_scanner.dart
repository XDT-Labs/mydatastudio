import 'package:mydatastudio/modules/files/services/scanners/google_drive_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_scanner.dart';

/// Google Drive scanner registered for `file.gdrive` collections.
///
/// All scan logic lives in the provider-neutral [CloudFileScanner]; this just
/// plugs in [GoogleDriveFileApi]. A new provider does the same with its own
/// `CloudFileApi` factory.
class CloudFileIsolate extends CloudFileScanner {
  CloudFileIsolate(
    super.loggerIsolatePort, {
    super.storagePath,
    super.appDir,
    super.dbName,
  }) : super(apiFactory: GoogleDriveFileApi.create);
}
