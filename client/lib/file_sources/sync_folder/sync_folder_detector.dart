import 'dart:io';

import 'package:path/path.dart' as p;

enum SyncProvider { iCloudDrive, googleDrive, dropbox, oneDrive, box, other }

class DetectedSyncFolder {
  const DetectedSyncFolder({
    required this.provider,
    required this.displayName,
    required this.path,
    this.account,
  });

  final SyncProvider provider;
  final String displayName;

  /// e.g. the email in `GoogleDrive-user@gmail.com`; null when unknown.
  final String? account;

  /// Directory a collection should be rooted at.
  final String path;

  @override
  String toString() => 'DetectedSyncFolder($provider, $displayName, $path)';
}

/// Finds macOS cloud sync folders: File Provider roots under
/// `~/Library/CloudStorage` and legacy iCloud Drive.
class SyncFolderDetector {
  /// [homeDir] is injectable for tests; defaults to `$HOME`.
  SyncFolderDetector({String? homeDir})
      : _home = homeDir ?? Platform.environment['HOME'] ?? '';

  final String _home;

  List<DetectedSyncFolder> detect() => [
        ..._detectCloudStorage(),
        ..._detectICloud(),
      ];

  List<DetectedSyncFolder> _detectCloudStorage() {
    final root = Directory(p.join(_home, 'Library', 'CloudStorage'));
    final result = <DetectedSyncFolder>[];
    for (final dir in _visibleSubdirs(root)) {
      final name = p.basename(dir.path);
      final dash = name.indexOf('-');
      final prefix = dash < 0 ? name : name.substring(0, dash);
      final suffix = dash < 0 ? null : name.substring(dash + 1);
      switch (prefix) {
        case 'GoogleDrive':
          // Content lives in `My Drive` and `Shared drives`, not the root.
          for (final sub in const ['My Drive', 'Shared drives']) {
            final subDir = Directory(p.join(dir.path, sub));
            if (subDir.existsSync()) {
              result.add(DetectedSyncFolder(
                provider: SyncProvider.googleDrive,
                displayName: suffix == null
                    ? 'Google Drive - $sub'
                    : 'Google Drive ($suffix) - $sub',
                account: suffix,
                path: subDir.path,
              ));
            }
          }
        case 'Dropbox':
          result.add(DetectedSyncFolder(
            provider: SyncProvider.dropbox,
            displayName: suffix == null ? 'Dropbox' : 'Dropbox ($suffix)',
            account: suffix,
            path: dir.path,
          ));
        case 'OneDrive':
          result.add(DetectedSyncFolder(
            provider: SyncProvider.oneDrive,
            displayName: suffix == null ? 'OneDrive' : 'OneDrive - $suffix',
            account: suffix,
            path: dir.path,
          ));
        case 'Box':
          result.add(DetectedSyncFolder(
            provider: SyncProvider.box,
            displayName: 'Box',
            account: suffix,
            path: dir.path,
          ));
        default:
          result.add(DetectedSyncFolder(
            provider: SyncProvider.other,
            displayName: name,
            path: dir.path,
          ));
      }
    }
    return result;
  }

  List<DetectedSyncFolder> _detectICloud() {
    final dir = Directory(
        p.join(_home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs'));
    if (!_safeExists(dir)) return const [];
    return [
      DetectedSyncFolder(
        provider: SyncProvider.iCloudDrive,
        displayName: 'iCloud Drive',
        path: dir.path,
      ),
    ];
  }

  Iterable<Directory> _visibleSubdirs(Directory root) {
    try {
      if (!root.existsSync()) return const [];
      return root
          .listSync(followLinks: true)
          .whereType<Directory>()
          .where((d) => !p.basename(d.path).startsWith('.'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      return const []; // unreadable (permissions): treat as absent
    }
  }

  bool _safeExists(Directory d) {
    try {
      return d.existsSync();
    } on FileSystemException {
      return false;
    }
  }
}
