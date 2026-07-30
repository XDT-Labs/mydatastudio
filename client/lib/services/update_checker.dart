import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:path/path.dart' as p;

/// A published release that is newer than the running build.
class ReleaseUpdate {
  const ReleaseUpdate({
    required this.version,
    required this.pageUrl,
    required this.notes,
  });

  /// Release version with the tag's `v` prefix stripped, e.g. `1.2.3`.
  final String version;

  /// GitHub release page, opened in the user's browser to download the DMG.
  final String pageUrl;

  /// Release notes body. Markdown, and may be empty.
  final String notes;
}

/// Checks the project's GitHub releases for a newer version and reports it, so
/// the user can download the new DMG themselves. It never downloads or
/// installs anything — replacing the running `.app` in place is Sparkle's job
/// and is tracked separately in TODO.md.
///
/// Every failure path returns null: an update check is a convenience, and a
/// rate limit or a flaky network must never interrupt startup or produce a
/// dialog the user can't act on. Failures are logged, not surfaced.
class UpdateChecker {
  UpdateChecker._();

  @visibleForTesting
  static const repoSlug = 'XDT-Labs/mydatastudio';

  /// `/releases/latest` excludes pre-releases and drafts, which is what we
  /// want — the beta channel shouldn't prompt everyone to upgrade.
  static const _apiUrl =
      'https://api.github.com/repos/$repoSlug/releases/latest';

  /// The unauthenticated GitHub API allows 60 requests/hour per IP. One check a
  /// day is far inside that and keeps a user who restarts the app repeatedly
  /// from spending the budget.
  static const _checkInterval = Duration(hours: 24);

  static const _requestTimeout = Duration(seconds: 10);

  static final AppLogger _logger = AppLogger(null);

  /// The newer release, or null when the app is current, the check was
  /// throttled, the user skipped this version, or anything went wrong.
  ///
  /// Pass [force] for a user-initiated "Check for updates" action, which should
  /// answer immediately and ignore both the throttle and a skipped version.
  static Future<ReleaseUpdate?> check({bool force = false}) async {
    try {
      final state = await _readState();
      final lastChecked = state['lastCheckedAt'] as String?;

      if (!force && lastChecked != null) {
        final last = DateTime.tryParse(lastChecked);
        if (last != null &&
            DateTime.now().difference(last) < _checkInterval) {
          return null;
        }
      }

      final response = await http
          .get(
            Uri.parse(_apiUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
            },
          )
          .timeout(_requestTimeout);

      // Record the attempt on any answer from GitHub, including a 403 rate
      // limit, so a throttled client backs off instead of retrying each
      // launch. A thrown request (offline) deliberately doesn't count, so the
      // next launch tries again.
      await _writeState({...state, 'lastCheckedAt': DateTime.now().toIso8601String()});

      if (response.statusCode != 200) {
        _logger.d(
          '[update] GitHub returned ${response.statusCode}; skipping check',
        );
        return null;
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final tag = body['tag_name'] as String?;
      if (tag == null || tag.isEmpty) {
        _logger.d('[update] Release has no tag_name; skipping check');
        return null;
      }

      final latest = normalizeVersion(tag);
      final current = normalizeVersion(await PythonManager.currentAppVersion());

      if (compareVersions(latest, current) <= 0) {
        _logger.d('[update] Running $current, latest is $latest — up to date');
        return null;
      }

      if (!force && state['skippedVersion'] == latest) {
        _logger.d('[update] $latest was skipped by the user');
        return null;
      }

      _logger.i('[update] Update available: $current -> $latest');
      return ReleaseUpdate(
        version: latest,
        pageUrl:
            body['html_url'] as String? ??
            'https://github.com/$repoSlug/releases/latest',
        notes: (body['body'] as String?)?.trim() ?? '',
      );
    } catch (e) {
      // Includes SocketException when offline and TimeoutException on a slow
      // link — both are normal and not worth bothering the user about.
      _logger.d('[update] Update check failed: $e');
      return null;
    }
  }

  /// Suppress the prompt for [version] until a release newer than it appears.
  static Future<void> skipVersion(String version) async {
    try {
      final state = await _readState();
      await _writeState({...state, 'skippedVersion': version});
      _logger.i('[update] Skipping version $version');
    } catch (e) {
      _logger.d('[update] Could not persist skipped version: $e');
    }
  }

  /// Strip a tag's `v` prefix and any build metadata, leaving the dotted
  /// numeric core: `v1.2.3` and `1.2.3+7` both yield `1.2.3`.
  @visibleForTesting
  static String normalizeVersion(String raw) {
    var v = raw.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    // Build metadata (`+7`) and pre-release suffixes (`-beta.1`) don't take
    // part in the comparison. `/releases/latest` never returns a pre-release,
    // so dropping the suffix can't make a beta outrank a stable release.
    v = v.split('+').first.split('-').first;
    return v.trim();
  }

  /// Compare two normalized dotted-numeric versions. Returns a negative number
  /// when [a] is older than [b], 0 when equal, positive when newer. Missing
  /// components count as 0, so `1.2` equals `1.2.0`. Non-numeric components
  /// count as 0 rather than throwing — a malformed tag should read as "not
  /// newer" instead of failing the check.
  @visibleForTesting
  static int compareVersions(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    final length = left.length > right.length ? left.length : right.length;

    for (var i = 0; i < length; i++) {
      final l = i < left.length ? (int.tryParse(left[i]) ?? 0) : 0;
      final r = i < right.length ? (int.tryParse(right[i]) ?? 0) : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  /// Throttle timestamp and skipped version, kept in a small JSON file beside
  /// the app's other loose Application Support state (config.json, the font
  /// cache) rather than in the database — none of it is worth a schema
  /// migration, and losing it only costs one extra update prompt.
  static Future<File> _stateFile() async {
    final supportPath = await DatabaseManager.getRealApplicationSupportPath();
    return File(p.join(supportPath, 'update_check.json'));
  }

  static Future<Map<String, dynamic>> _readState() async {
    final file = await _stateFile();
    if (!file.existsSync()) return {};
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      // Corrupt or hand-edited: start over rather than block the check.
      _logger.d('[update] Ignoring unreadable ${file.path}: $e');
      return {};
    }
  }

  static Future<void> _writeState(Map<String, dynamic> state) async {
    final file = await _stateFile();
    file.writeAsStringSync(jsonEncode(state));
  }
}
