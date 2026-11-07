#ifndef RUNNER_SYSTEM_TRASH_CHANNEL_H_
#define RUNNER_SYSTEM_TRASH_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Registers the `mydatastudio/system_trash` method channel that SystemTrash
// (system_trash.dart) calls. The channel lives as long as the process.
void system_trash_channel_register(FlBinaryMessenger* messenger);

#endif  // RUNNER_SYSTEM_TRASH_CHANNEL_H_
