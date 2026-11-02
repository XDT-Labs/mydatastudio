import 'dart:io';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:path/path.dart' as p;

enum SyncProvider {
  iCloudDrive,
  googleDrive,
  dropbox,
  oneDrive,
  box,
  pCloud,
  proton,
  mega,
  syncCom,
  other,
}

class DetectedSyncFolder {
  const DetectedSyncFolder({
    required this.provider,
    required this.displayName,
    required this.path,
    this.account,
    this.note,
  });

  final SyncProvider provider;
  final String displayName;

  /// e.g. the email in `GoogleDrive-user@gmail.com`; null when unknown.
  final String? account;

  /// Directory a collection should be rooted at.
  final String path;

  /// Short provider-specific caveat shown when the folder is added
  /// (e.g. what is not indexed); null when there is nothing to warn about.
  final String? note;

  @override
  String toString() => 'DetectedSyncFolder($provider, $displayName, $path)';
}

const _iCloudNote =
    'iCloud Drive syncs through macOS. Online-only files are listed but not '
    'downloaded.';
const _protonNote =
    'Proton Drive is end-to-end encrypted. We index the files the Proton '
    'Drive app has decrypted on this Mac.';
const _syncComNote = "Vault content isn't on this Mac, so it isn't indexed.";

/// Finds macOS cloud sync folders: File Provider roots under
/// `~/Library/CloudStorage`, legacy folders such as `~/Dropbox`, and iCloud
/// Drive plus the app containers beside it.
class SyncFolderDetector {
  /// [homeDir] is injectable for tests; defaults to `$HOME`.
  SyncFolderDetector({String? homeDir})
    : _home = homeDir ?? Platform.environment['HOME'] ?? '';

  final String _home;

  /// Each real directory is reported once, even when reachable through a
  /// symlink (e.g. `~/Dropbox` pointing into `~/Library/CloudStorage`).
  List<DetectedSyncFolder> detect() {
    final seen = <String>{};
    return [
      ..._detectCloudStorage(),
      ..._detectLegacyFolders(),
      ..._detectICloud(),
      ..._detectICloudAppContainers(),
    ].where((f) => seen.add(_resolved(f.path))).toList();
  }

  String _resolved(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  List<DetectedSyncFolder> _detectCloudStorage() {
    final root = Directory(p.join(_home, 'Library', 'CloudStorage'));
    final result = <DetectedSyncFolder>[];
    for (final dir in _visibleSubdirs(root)) {
      final name = p.basename(dir.path);
      final dash = name.indexOf('-');
      final prefix = dash < 0 ? name : name.substring(0, dash);
      final suffix = dash < 0 ? null : name.substring(dash + 1);
      // Matched case-insensitively and ignoring spaces: the real names of the
      // pCloud, Proton Drive and MEGA roots are unverified guesses
      // (`pCloud*`, `ProtonDrive-*` / `Proton Drive*`, `MEGA*`).
      switch (prefix.toLowerCase().replaceAll(' ', '')) {
        case 'googledrive':
          // Content lives in `My Drive` and `Shared drives`, not the root.
          for (final sub in const ['My Drive', 'Shared drives']) {
            final subDir = Directory(p.join(dir.path, sub));
            if (subDir.existsSync()) {
              result.add(
                DetectedSyncFolder(
                  provider: SyncProvider.googleDrive,
                  displayName:
                      suffix == null
                          ? 'Google Drive - $sub'
                          : 'Google Drive ($suffix) - $sub',
                  account: suffix,
                  path: subDir.path,
                ),
              );
            }
          }
        case 'dropbox':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.dropbox,
              displayName: suffix == null ? 'Dropbox' : 'Dropbox ($suffix)',
              account: suffix,
              path: dir.path,
            ),
          );
        case 'onedrive':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.oneDrive,
              displayName: suffix == null ? 'OneDrive' : 'OneDrive - $suffix',
              account: suffix,
              path: dir.path,
            ),
          );
        case 'box':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.box,
              displayName: 'Box',
              account: suffix,
              path: dir.path,
            ),
          );
        case 'pcloud' || 'pclouddrive':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.pCloud,
              displayName: 'pCloud Drive',
              account: suffix,
              path: dir.path,
            ),
          );
        case 'protondrive':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.proton,
              displayName: 'Proton Drive',
              account: suffix,
              path: dir.path,
              note: _protonNote,
            ),
          );
        case 'mega':
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.mega,
              displayName: 'MEGA',
              account: suffix,
              path: dir.path,
            ),
          );
        default:
          result.add(
            DetectedSyncFolder(
              provider: SyncProvider.other,
              displayName: name,
              path: dir.path,
            ),
          );
      }
    }
    return result;
  }

  /// Folders that classic (non-File-Provider) sync apps create in `$HOME`.
  List<DetectedSyncFolder> _detectLegacyFolders() {
    final legacy = <(String, SyncProvider, String, String?)>[
      ('Dropbox', SyncProvider.dropbox, 'Dropbox', null),
      ('MEGA', SyncProvider.mega, 'MEGA', null),
      ('Sync', SyncProvider.syncCom, 'Sync.com', _syncComNote),
    ];
    return [
      for (final (dirName, provider, title, note) in legacy)
        if (_safeExists(Directory(p.join(_home, dirName))))
          DetectedSyncFolder(
            provider: provider,
            displayName: title,
            path: p.join(_home, dirName),
            note: note,
          ),
    ];
  }

  Directory get _mobileDocuments =>
      Directory(p.join(_home, 'Library', 'Mobile Documents'));

  static const _iCloudDriveContainer = 'com~apple~CloudDocs';

  List<DetectedSyncFolder> _detectICloud() {
    final dir = Directory(p.join(_mobileDocuments.path, _iCloudDriveContainer));
    if (!_safeExists(dir)) return const [];
    return [
      DetectedSyncFolder(
        provider: SyncProvider.iCloudDrive,
        displayName: 'iCloud Drive',
        path: dir.path,
        note: _iCloudNote,
      ),
    ];
  }

  /// App-owned iCloud containers (`com~apple~Pages`, `iCloud~md~obsidian`...)
  /// that actually hold files. Listing needs the same permission as iCloud
  /// Drive; a denial just means there is nothing to offer.
  List<DetectedSyncFolder> _detectICloudAppContainers() {
    return [
      for (final dir in _visibleSubdirs(_mobileDocuments))
        if (p.basename(dir.path) != _iCloudDriveContainer &&
            _hasVisibleEntries(dir))
          DetectedSyncFolder(
            provider: SyncProvider.iCloudDrive,
            displayName: 'iCloud - ${_appName(p.basename(dir.path))}',
            path: dir.path,
            note: _iCloudNote,
          ),
    ];
  }

  /// `iCloud~md~obsidian` -> `Obsidian`: last `~` segment, first letter up.
  static String _appName(String container) {
    final last = container.split('~').last;
    return last.isEmpty ? container : last[0].toUpperCase() + last.substring(1);
  }

  bool _hasVisibleEntries(Directory dir) {
    try {
      return dir.listSync().any((e) => !isHiddenFileName(p.basename(e.path)));
    } on FileSystemException {
      return false;
    }
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
    } on FileSystemException catch (e) {
      // Unreadable (permissions): treat as absent, but leave a trace.
      AppLogger(null).w('Cannot list ${root.path}: $e');
      return const [];
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
