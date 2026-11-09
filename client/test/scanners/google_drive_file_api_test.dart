import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/modules/files/services/scanners/google_drive_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';

/// `CloudFileApi.download` promises [CloudFileNotFoundException] for a file
/// that's gone, so callers can retire it instead of retrying forever. Drive
/// must keep that promise like Dropbox and OneDrive do.
void main() {
  GoogleDriveFileApi api(int status) => GoogleDriveFileApi(
    drive.DriveApi(
      MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': status, 'message': 'x'},
          }),
          status,
          headers: {'content-type': 'application/json'},
        ),
      ),
    ),
  );

  late String dest;
  setUp(() {
    dest = '${io.Directory.systemTemp.createTempSync('mds_gd_').path}/f';
  });

  test('a file gone from Drive (404) is CloudFileNotFoundException', () {
    expect(
      api(404).download('abc', dest),
      throwsA(isA<CloudFileNotFoundException>()),
    );
  });

  test('other failures stay Drive errors, to be retried', () {
    expect(
      api(500).download('abc', dest),
      throwsA(isA<drive.DetailedApiRequestError>()),
    );
  });
}
