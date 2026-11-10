#ifndef RUNNER_SYSTEM_TRASH_CHANNEL_H_
#define RUNNER_SYSTEM_TRASH_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Creates the `mydatastudio/system_trash` method channel that SystemTrash
// (system_trash.dart) calls. The caller keeps it alive while the engine runs.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSystemTrashChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SYSTEM_TRASH_CHANNEL_H_
