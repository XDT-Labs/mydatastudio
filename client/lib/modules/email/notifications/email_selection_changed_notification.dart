import 'package:material_ui/material_ui.dart';

/// Raised when the set of checked rows changes.
///
/// Deliberately separate from [EmailSelectedNotification]: checking a row's
/// checkbox marks it for a bulk action, while tapping the row opens it. The two
/// used to share one notification, which is why ticking a checkbox — or the
/// select-all box — also opened a message.
class EmailSelectionChangedNotification extends Notification {}
