import 'package:mydatastudio/modules/files/notifications/file_notification.dart';

class SortChangedNotification extends FiledNotification {
  final String sortColumn;
  final bool sortAsc;

  SortChangedNotification(this.sortColumn, this.sortAsc);
}
