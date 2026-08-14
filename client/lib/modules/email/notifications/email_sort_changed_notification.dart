import 'package:material_ui/material_ui.dart';

class EmailSortChangedNotification extends Notification {
  final String sortColumn;
  final bool sortAsc;

  EmailSortChangedNotification(this.sortColumn, this.sortAsc);
}
