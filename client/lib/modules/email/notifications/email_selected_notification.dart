import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/email.dart';

class EmailSelectedNotification extends Notification {
  final Email email;

  EmailSelectedNotification(this.email);
}
