import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/email.dart';

class EmailSelectedNotification extends Notification {
  final Email email;

  EmailSelectedNotification(this.email);
}
