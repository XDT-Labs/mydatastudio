import 'package:flutter/services.dart';
import 'package:mydatastudio/app_logger.dart';

/// Moves a file to the operating system's trash.
///
/// Dart has no cross-platform API for this and `io.File.delete()` is a
/// permanent unlink, so the actual move happens in native code behind a method
/// channel. macOS is implemented (`NSFileManager.trashItem`); Windows and Linux
/// are not — see TODO.md.
///
/// On a platform with no implementation this returns false and **leaves the
/// file alone**. It deliberately does not fall back to deleting: the user was
/// promised something recoverable, and quietly destroying the file instead
/// would be a worse outcome than not removing it at all. The caller decides
/// what to do with a false — the photos delete path still records the file as
/// user-deleted, so it disappears from the app either way.
class SystemTrash {
  SystemTrash({MethodChannel? channel, AppLogger? logger})
      : _channel = channel ?? const MethodChannel('mydatastudio/system_trash'),
        _logger = logger ?? AppLogger(null);

  final MethodChannel _channel;
  final AppLogger _logger;

  /// Moves [path] to the trash. Returns whether it actually got there.
  Future<bool> moveToTrash(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('moveToTrash', {
        'path': path,
      });
      return ok ?? false;
    } on MissingPluginException {
      // No native implementation on this platform. Expected on Windows and
      // Linux until their runners implement the channel.
      _logger.w(
        'SystemTrash: no implementation on this platform; leaving $path '
        'on disk',
      );
      return false;
    } on PlatformException catch (e) {
      // The file is locked, on a volume with no trash, or already gone.
      _logger.w('SystemTrash: could not trash $path: ${e.message}');
      return false;
    }
  }
}
