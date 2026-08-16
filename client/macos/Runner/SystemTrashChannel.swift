import Cocoa
import FlutterMacOS

/// Moves files to the macOS Trash on behalf of the Dart side.
///
/// Dart has no cross-platform "move to trash" API — `File.delete()` is an
/// unlink, which destroys the file. The photos module promises the user a
/// recoverable delete, so the move has to go through `NSFileManager.trashItem`.
///
/// The channel name is shared with `lib/modules/files/services/utilities/system_trash.dart`.
/// A platform without this channel gets a `MissingPluginException` there, which
/// is handled by leaving the file alone rather than deleting it — see TODO.md
/// for the Windows Recycle Bin equivalent.
enum SystemTrashChannel {
  static let name = "mydatastudio/system_trash"

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: controller.engine.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      guard call.method == "moveToTrash" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        !path.isEmpty
      else {
        result(
          FlutterError(
            code: "bad_arguments",
            message: "moveToTrash requires a non-empty 'path'",
            details: nil
          )
        )
        return
      }

      let url = URL(fileURLWithPath: path)

      // Already gone counts as success: the caller's goal is that the file is
      // not on disk, and reporting failure would make a retry look necessary.
      guard FileManager.default.fileExists(atPath: path) else {
        result(true)
        return
      }

      do {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        result(true)
      } catch {
        // Locked file, a volume with no trash (some network and external
        // volumes), or missing permission. Reported rather than swallowed so
        // the Dart side can leave the file in place instead of assuming it
        // moved.
        result(
          FlutterError(
            code: "trash_failed",
            message: error.localizedDescription,
            details: path
          )
        )
      }
    }
  }
}
