import 'package:mydatastudio/models/tables/collection.dart';
import 'package:material_ui/material_ui.dart';

class ChangeCollectionNotification extends Notification {
  final Collection? val;
  ChangeCollectionNotification(this.val);
}
