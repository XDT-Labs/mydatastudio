// Copyright 2019 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:mydatatools/modules/files/notifications/file_notification.dart';
import 'package:mydatatools/modules/files/notifications/path_changed_notification.dart';
import 'package:mydatatools/modules/files/notifications/sort_changed_notification.dart';
import 'package:flutter/material.dart';
import 'package:moment_dart/moment_dart.dart';
import 'package:mydatatools/modules/files/services/delete_file_service.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:open_filex/open_filex.dart';

class FileTable extends StatefulWidget {
  const FileTable({super.key, required this.data});
  final List<FileAsset> data;

  @override
  State<FileTable> createState() => _FileTable();
}

class _FileTable extends State<FileTable> {
  int sortColumnIndex = 0;
  String sortColumn = 'name';
  bool sortAsc = true;
  List<String> selectedRows = [];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    List<DataColumn> columns = getColumns(context);
    List<DataRow> rows = getRows(context, widget.data);

    return Expanded(
      flex: 1,
      child: Container(
        constraints: const BoxConstraints.expand(),
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          child: DataTable(
            columns: columns,
            rows: rows,
            sortColumnIndex: sortColumnIndex,
            sortAscending: sortAsc,
            showCheckboxColumn: true,
            onSelectAll: (bool? selected) {
              if (selected != null) {
                setState(() {
                  if (selected) {
                    selectedRows = widget.data.map((f) => f.path).toList();
                  } else {
                    selectedRows.clear();
                  }
                });
                _notifySelectionChanged(context);
              }
            },
            dataTextStyle: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w200,
              fontSize: 15,
              color: Colors.black87,
            ),
            headingTextStyle: theme.textTheme.titleSmall?.copyWith(
              fontWeight:
                  FontWeight.w200, // Keep headers slightly bolder than data
              fontSize: 15,
              color: Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  List<DataColumn> getColumns(BuildContext context) {
    return <DataColumn>[
      DataColumn(
        label: const Expanded(
          flex: 2,
          child: Text('Name', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'name';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        numeric: true,
        label: const Expanded(
          flex: 1,
          child: Text('Type', style: TextStyle(fontWeight: FontWeight.normal)),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'contentType';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        numeric: true,
        label: const Expanded(
          flex: 1,
          child: Text('Size', style: TextStyle(fontWeight: FontWeight.normal)),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'size';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        label: const Expanded(
          flex: 1,
          child: Text(
            'Date\nCreated',
            maxLines: 2,
            softWrap: true,
            style: TextStyle(fontWeight: FontWeight.normal),
          ),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'date_created';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      const DataColumn(
        label: Center(
          child: Text(
            'Actions',
            style: TextStyle(fontWeight: FontWeight.normal),
          ),
        ),
      ),
    ];
  }

  List<DataRow> getRows(BuildContext context, List<FileAsset> assets) {
    //DateFormat df = DateFormat('yyyy-MM-dd HH:mm');
    List<DataRow> rows = [];

    //Create a row for every item returns from DB
    for (var f in assets) {
      if (f is File) {
        //File Cells
        var moment = Moment.fromMillisecondsSinceEpoch(
          f.dateCreated.millisecondsSinceEpoch,
          isUtc: true,
        );
        bool isImage = f.contentType == FilesConstants.mimeTypeImage;

        rows.add(
          DataRow(
            selected: selectedRows.contains(f.path),
            cells: [
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 200,
                  ), //SET max width
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      !isImage
                          ? Icon(getIconForMimeType(f.contentType))
                          : getImageComponent(isImage, f),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
                onTap: () {
                  FileSelectedNotification(f).dispatch(context);
                },
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 100,
                  ), //SET max width
                  child: Text(
                    f.contentType.split("/").last,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 150,
                  ), //SET max width
                  child: Text(
                    _formatBytes(f.size),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 250,
                  ), //SET max width
                  child: Tooltip(
                    message: f.dateCreated.toLocal().toString(),
                    child: Text(
                      moment.fromNowPrecise(
                        form: Abbreviation.full,
                        includeWeeks: true,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ),
                showEditIcon: false,
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 150,
                  ), //SET max width
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.open_in_new),
                        onPressed: () async {
                          //download
                          ///io.File file = await dataProvider.fileService.fileRepository.downloadFile(f);
                          //show message
                          //var msg = ScaffoldMessenger.of(context);
                          //msg.showSnackBar(SnackBar(content: Text('File download to: ${file.path}')));
                          //then open
                          // TODO: trigger open in default app
                          await OpenFilex.open(f.path);
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _showDeleteConfirmationDialog(context, f),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            onSelectChanged: (bool? e) {
              setState(() {
                if (e != null && e) {
                  selectedRows.add(f.path);
                } else {
                  selectedRows.remove(f.path);
                }
              });
              _notifySelectionChanged(context);
            },
          ),
        );
      } else {
        //Folder Row (mostly empty cells)
        rows.add(
          DataRow(
            selected: selectedRows.contains(f.path),
            cells: [
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 300,
                  ), //SET max width
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      const Icon(Icons.folder),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(f.name, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
                onTap: () {
                  PathChangedNotification(
                    f,
                    sortColumn,
                    sortAsc,
                  ).dispatch(context);
                },
              ),
              const DataCell(Text('')),
              const DataCell(Text('')),
              const DataCell(Text('')),
              const DataCell(Text('')),
            ],
            onSelectChanged: (bool? e) {
              setState(() {
                if (e != null && e) {
                  selectedRows.add(f.path);
                } else {
                  selectedRows.remove(f.path);
                }
              });
              _notifySelectionChanged(context);
            },
          ),
        );
      }
    }
    return rows;
  }

  void _notifySelectionChanged(BuildContext context) {
    final selectedItems = widget.data.where((f) => selectedRows.contains(f.path)).toList();
    SelectionChangedNotification(selectedItems).dispatch(context);
  }

  Future<void> _showDeleteConfirmationDialog(BuildContext context, File file) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // user must tap button!
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete File'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text('Are you sure you want to delete "${file.name}"?'),
                const SizedBox(height: 8),
                const Text('This will permanently remove the file from your computer and the database.', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _deleteFile(context, file);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteFile(BuildContext context, File file) async {
    try {
      // 1. Delete from file system
      final ioFile = io.File(file.path);
      if (await ioFile.exists()) {
        await ioFile.delete();
      }

      // 2. Delete from database
      final db = DatabaseManager.instance.database;
      if (db != null) {
        await DeleteFileService.instance.invoke(DeleteFileServiceCommand(file, db));
      }

      // 3. Notify parent to refresh
      if (context.mounted) {
        const FileDeletedNotification().dispatch(context);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted "${file.name}"')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting file: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget getImageComponent(bool isImage, File file) {
    if (isImage) {
      try {
        if (file.thumbnail != null) {
          return Padding(
            padding: const EdgeInsets.all(4),
            child: Image(
              image: ResizeImage(
                MemoryImage(base64Decode(file.thumbnail!)),
                width: 100,
                height: 64,
              ),
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.all(4),
            child: Image(
              image: ResizeImage(
                FileImage(io.File(file.path)),
                width: 100,
                height: 64,
              ),
            ),
          );
        }
      } catch (err) {
        //do nothing, return placeholder
      }
    }
    return const Placeholder();
  }

  IconData? getIconForMimeType(String contentType) {
    switch (contentType) {
      case FilesConstants.mimeTypeImage:
        return Icons.image;
      case FilesConstants.mimeTypePdf:
        return Icons.picture_as_pdf;
      default:
        return Icons.file_present;
    }
  }

  String _formatBytes(num bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    return ((bytes / pow(1024, i)).toStringAsFixed(
          1,
        )).replaceAll(RegExp(r'\.0$'), '') +
        ' ' +
        suffixes[i];
  }
}
