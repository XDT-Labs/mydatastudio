import 'package:mydatastudio/modules/files/services/scanners/dropbox_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_scanner.dart';

/// Dropbox scanner registered for `file.dropbox` collections. Like
/// `CloudFileIsolate` for Drive, it only plugs a [DropboxFileApi] factory into
/// the provider-neutral [CloudFileScanner].
class DropboxFileIsolate extends CloudFileScanner {
  DropboxFileIsolate(
    super.loggerIsolatePort, {
    super.storagePath,
    super.appDir,
    super.dbName,
  }) : super(apiFactory: DropboxFileApi.create);
}
