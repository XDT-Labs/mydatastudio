import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/file_asset.dart';

class FiledNotification extends Notification {
  const FiledNotification();
}


class FileDeletedNotification extends FiledNotification {
  const FileDeletedNotification();
}

class SelectionChangedNotification extends FiledNotification {
  final List<FileAsset> selectedItems;
  const SelectionChangedNotification(this.selectedItems);
}

class FileSelectedNotification extends FiledNotification {
  final FileAsset asset;
  const FileSelectedNotification(this.asset);
}


