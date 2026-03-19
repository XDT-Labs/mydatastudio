import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/email.dart';

class EmailSelectedNotification extends Notification {
  final Email email;

  EmailSelectedNotification(this.email);
}
