// Copyright 2019 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math';

import 'package:mydatatools/helpers/file_path_resolver.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:mydatatools/modules/files/notifications/file_notification.dart';
import 'package:mydatatools/modules/files/notifications/path_changed_notification.dart';
import 'package:mydatatools/modules/files/notifications/sort_changed_notification.dart';
import 'package:flutter/material.dart';
import 'package:moment_dart/moment_dart.dart';

import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

class FileTable extends StatefulWidget {
  const FileTable({
    super.key,
    required this.data,
    this.collection,
    this.scrollController,
  });
  final List<FileAsset> data;
  final Collection? collection;
  final ScrollController? scrollController;

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;

        // Define fixed widths for other columns + spacers
        const checkboxWidth = 48.0;
        const typeWidth = 80.0;
        const sizeWidth = 80.0;
        const dateWidth = 140.0;
        const actionsWidth = 150.0;
        const spacing = 16.0;
        const margin = 24.0; // 12 on each side

        // Total width occupied by other columns and spacing
        final fixedWidths =
            checkboxWidth +
            typeWidth +
            sizeWidth +
            dateWidth +
            actionsWidth +
            (4 * spacing) +
            margin;

        // Remaining space for Name column
        final nameWidth = max(200.0, totalWidth - fixedWidths);

        List<DataColumn> columns = getColumns(context);
        List<DataRow> rows = getRows(context, widget.data, nameWidth);

        return Container(
          constraints: const BoxConstraints.expand(),
          child: SingleChildScrollView(
            controller: widget.scrollController,
            scrollDirection: Axis.vertical,
            child: DataTable(
              dataRowMaxHeight: 40,
              dataRowMinHeight: 40,
              headingRowHeight: 40,
              headingRowColor: WidgetStateProperty.all(Colors.transparent),
              columnSpacing: spacing,
              horizontalMargin: 12,
              showCheckboxColumn: true,
              columns: columns,
              rows: rows,
              sortColumnIndex: sortColumnIndex,
              sortAscending: sortAsc,
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
                fontWeight: FontWeight.normal,
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              headingTextStyle: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.8),
                letterSpacing: 1.0,
              ),
            ),
          ),
        );
      },
    );
  }

  List<DataColumn> getColumns(BuildContext context) {
    return <DataColumn>[
      DataColumn(
        label: const Text('NAME'),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'name';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        numeric: true,
        label: const Text('TYPE'),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'contentType';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        numeric: true,
        label: const Text('SIZE'),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'size';
          sortAsc = sortAscending;
          SortChangedNotification(sortColumn, sortAscending).dispatch(context);
        },
      ),
      DataColumn(
        label: const Text(
          'DATE\nCREATED',
          maxLines: 2,
          softWrap: true,
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
          child: Text('ACTIONS'),
        ),
      ),
    ];
  }

  List<DataRow> getRows(
    BuildContext context,
    List<FileAsset> assets,
    double nameWidth,
  ) {
    final theme = Theme.of(context);
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
                  constraints: BoxConstraints(maxWidth: nameWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      (f.thumbnail == null && !isImage)
                          ? SizedBox(
                              width: 50,
                              height: 32,
                              child: Center(
                                child: Icon(
                                  getIconForMimeType(f.contentType),
                                  color: _getIconColor(f.contentType),
                                ),
                              ),
                            )
                          : getImageComponent(f),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
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
                  constraints: const BoxConstraints(maxWidth: 80),
                  child: Text(
                    _formatType(f.contentType, f.name),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 80),
                  child: Text(
                    _formatBytes(f.size),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
              DataCell(
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Tooltip(
                    message:
                        '${f.dateCreated.toLocal().toString()} and ${assets.length - 1} more',
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
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.info_outline,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.8),
                          ),
                          tooltip: 'Details',
                          onPressed: () {
                            FileSelectedNotification(f).dispatch(context);
                          },
                        ),
                      ),
                      Flexible(
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.open_in_new,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.8),
                          ),
                          tooltip: 'Open',
                          onPressed: () async {
                            if (f.path.startsWith('gdrive://')) {
                              final id = f.path.substring(9);
                              final url =
                                  'https://drive.google.com/file/d/$id/view';
                              await launchUrl(Uri.parse(url));
                            } else {
                              await OpenFilex.open(f.path);
                            }
                          },
                        ),
                      ),
                      Flexible(
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                            Icons.delete,
                            size: 20,
                            color: theme.colorScheme.error.withOpacity(0.8),
                          ),
                          tooltip: 'Delete',
                          onPressed:
                              () => _showDeleteConfirmationDialog(context, f),
                        ),
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
        //Folder Row
        var moment = Moment.fromMillisecondsSinceEpoch(
          f.dateCreated.millisecondsSinceEpoch,
          isUtc: true,
        );
        rows.add(
          DataRow(
            selected: selectedRows.contains(f.path),
            cells: [
              DataCell(
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: nameWidth),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 50,
                        height: 32,
                        child: Center(
                          child: Icon(Icons.folder, color: Colors.amber),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
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
              DataCell(
                Text(
                  f.name.toLowerCase().contains('library') ? 'Library' : 'Folder',
                ),
              ),
              const DataCell(Text('--')),
              DataCell(
                Text(
                  moment.fromNowPrecise(
                    form: Abbreviation.full,
                    includeWeeks: true,
                  ),
                ),
              ),
              const DataCell(SizedBox.shrink()),
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
    final selectedItems =
        widget.data.where((f) => selectedRows.contains(f.path)).toList();
    SelectionChangedNotification(selectedItems).dispatch(context);
  }

  Future<void> _showDeleteConfirmationDialog(
    BuildContext context,
    File file,
  ) async {
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
                const Text(
                  'This will permanently remove the file from your computer and the database.',
                  style: TextStyle(color: Colors.red),
                ),
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
      await FileDesktopRepository(DatabaseManager.instance.database!).delete(file);

      // 3. Notify parent to refresh
      if (context.mounted) {
        const FileDeletedNotification().dispatch(context);

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Deleted "${file.name}"')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget getImageComponent(File file) {
    try {
      final ImageProvider provider;
      if (file.thumbnail != null) {
        provider =
            file.thumbnail!.startsWith('http')
                ? NetworkImage(file.thumbnail!)
                : MemoryImage(base64Decode(file.thumbnail!));
      } else {
        // Use the resolver to handle relative paths (e.g., from email attachments)
        final collection = widget.collection;
        if (collection != null) {
          final absPath = FilePathResolver.absoluteFromPath(
            file.path,
            collection,
          );
          provider = FileImage(io.File(absPath));
        } else {
          provider = FileImage(io.File(file.path));
        }
      }

      return SizedBox(
        width: 50,
        height: 32,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Image(
              image: ResizeImage(provider, height: 32),
              fit: BoxFit.contain,
              errorBuilder:
                  (context, error, stackTrace) =>
                      Icon(getIconForMimeType(file.contentType)),
            ),
          ),
        ),
      );
    } catch (err) {
      //do nothing, return placeholder
    }
    return const SizedBox(
      width: 50,
      height: 32,
      child: Center(child: Icon(Icons.broken_image)),
    );
  }

  IconData? getIconForMimeType(String contentType) {
    if (contentType == 'application/pdf') {
      return Icons.picture_as_pdf;
    } else if (contentType == 'text/csv' || contentType.contains('csv') || contentType.contains('spreadsheet')) {
      return Icons.table_chart;
    } else if (contentType.contains('zip') || contentType.contains('archive') || contentType.contains('compressed')) {
      return Icons.folder_zip;
    } else if (contentType.startsWith('image/')) {
      return Icons.image;
    }
    return Icons.insert_drive_file;
  }

  Color _getIconColor(String contentType) {
    if (contentType == 'application/pdf') {
      return Colors.red.shade400;
    } else if (contentType == 'text/csv' || contentType.contains('csv') || contentType.contains('spreadsheet')) {
      return Colors.green.shade400;
    } else if (contentType.contains('zip') || contentType.contains('archive') || contentType.contains('compressed')) {
      return Colors.amber.shade400;
    }
    return Colors.grey.shade400;
  }

  String _formatType(String contentType, String name) {
    if (contentType == 'application/pdf') {
      return 'PDF Document';
    } else if (contentType == 'text/csv') {
      return 'CSV Spreadsheet';
    } else if (contentType == 'application/zip' || contentType == 'application/x-zip-compressed' || name.endsWith('.zip')) {
      return 'ZIP Archive';
    } else if (contentType.startsWith('image/')) {
      return contentType;
    }
    return contentType.split('/').last.toUpperCase();
  }

  String _formatBytes(num bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')} ${suffixes[i]}';
  }
}
