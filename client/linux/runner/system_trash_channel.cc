#include "system_trash_channel.h"

#include <gio/gio.h>

static void respond(FlMethodCall* call, FlMethodResponse* response) {
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("system_trash: failed to respond: %s", error->message);
  }
}

static void respond_error(FlMethodCall* call, const gchar* code,
                          const gchar* message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
  respond(call, response);
}

static void trash_finished(GObject* source, GAsyncResult* result,
                           gpointer user_data) {
  g_autoptr(FlMethodCall) call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;

  // Already gone counts as success: the caller's goal is that the file is not
  // on disk, and reporting failure would make a retry look necessary.
  if (g_file_trash_finish(G_FILE(source), result, &error) ||
      g_error_matches(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND)) {
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    respond(call, response);
    return;
  }

  // A volume with no usable trash (read-only shares, some network mounts) or
  // missing permission. GLib never falls back to deleting, so the file is
  // still there, and the Dart side reports that rather than assuming it moved.
  respond_error(call, "trash_failed", error->message);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(call), "moveToTrash") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    respond(call, response);
    return;
  }

  FlValue* args = fl_method_call_get_args(call);
  FlValue* path =
      args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
          ? fl_value_lookup_string(args, "path")
          : nullptr;
  if (path == nullptr || fl_value_get_type(path) != FL_VALUE_TYPE_STRING ||
      fl_value_get_string(path)[0] == '\0') {
    respond_error(call, "bad_arguments",
                  "moveToTrash requires a non-empty 'path'");
    return;
  }

  // GIO implements the freedesktop.org Trash spec: $XDG_DATA_HOME/Trash on the
  // home volume, $topdir/.Trash-$uid elsewhere, and unique names with their
  // .trashinfo files. Asynchronous because a batch delete, or a slow network
  // mount, would otherwise freeze the UI.
  g_autoptr(GFile) file = g_file_new_for_path(fl_value_get_string(path));
  g_file_trash_async(file, G_PRIORITY_DEFAULT, nullptr, trash_finished,
                     g_object_ref(call));
}

void system_trash_channel_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Deliberately never unreferenced, so the handler outlives this function.
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "mydatastudio/system_trash", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, nullptr,
                                            nullptr);
}
