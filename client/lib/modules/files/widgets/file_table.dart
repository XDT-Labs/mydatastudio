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
import 'package:path/path.dart' as p;

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

  // ── Responsive breakpoints ─────────────────────────────────────────────
  // Columns are hidden in order: type → size → date → individual actions.
  static const double _kHideType = 525;
  static const double _kHideSize = 415;
  static const double _kHideDate = 305;
  static const double _kMenuActions = 280;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;

        // Visibility flags derived from available width
        final showType = totalWidth >= _kHideType;
        final showSize = totalWidth >= _kHideSize;
        final showDate = totalWidth >= _kHideDate;
        final useMenuActions = totalWidth < _kMenuActions;

        // Fixed column widths (only count visible ones)
        const checkboxWidth = 48.0;
        const typeWidth = 80.0;
        const sizeWidth = 80.0;
        const dateWidth = 120.0;
        const actionsWidth = 130.0;
        const menuWidth = 48.0;
        const spacing = 16.0;
        const margin = 24.0;

        // Number of spacing gaps = number of visible non-name columns
        int visibleExtra = 0;
        double fixedWidths = checkboxWidth + margin;
        if (showType) {
          fixedWidths += typeWidth;
          visibleExtra++;
        }
        if (showSize) {
          fixedWidths += sizeWidth;
          visibleExtra++;
        }
        if (showDate) {
          fixedWidths += dateWidth;
          visibleExtra++;
        }
        fixedWidths += useMenuActions ? menuWidth : actionsWidth;
        visibleExtra++;
        fixedWidths += visibleExtra * spacing;

        final nameWidth = max(160.0, totalWidth - fixedWidths);

        // Keep sort index in range when columns disappear
        final maxSortIndex =
            1 + (showType ? 1 : 0) + (showSize ? 1 : 0) + (showDate ? 1 : 0);
        if (sortColumnIndex > maxSortIndex) {
          sortColumnIndex = 0;
        }

        final columns = getColumns(
          context,
          nameWidth: nameWidth,
          typeWidth: typeWidth,
          sizeWidth: sizeWidth,
          dateWidth: dateWidth,
          actionsWidth: useMenuActions ? menuWidth : actionsWidth,
          showType: showType,
          showSize: showSize,
          showDate: showDate,
        );
        final rows = getRows(
          context,
          widget.data,
          nameWidth: nameWidth,
          typeWidth: typeWidth,
          sizeWidth: sizeWidth,
          dateWidth: dateWidth,
          actionsWidth: useMenuActions ? menuWidth : actionsWidth,
          showType: showType,
          showSize: showSize,
          showDate: showDate,
          useMenuActions: useMenuActions,
        );

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
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.8,
                ),
                letterSpacing: 1.0,
              ),
            ),
          ),
        );
      },
    );
  }

  List<DataColumn> getColumns(
    BuildContext context, {
    required double nameWidth,
    required double typeWidth,
    required double sizeWidth,
    required double dateWidth,
    required double actionsWidth,
    required bool showType,
    required bool showSize,
    required bool showDate,
  }) {
    DataColumn nameCol = DataColumn(
      label: SizedBox(
        width: nameWidth,
        child: const Align(
          alignment: Alignment.centerLeft,
          child: Text('NAME'),
        ),
      ),
      onSort: (idx, asc) {
        sortColumnIndex = idx;
        sortColumn = 'name';
        sortAsc = asc;
        SortChangedNotification(sortColumn, asc).dispatch(context);
      },
    );
    DataColumn? typeCol;
    if (showType) {
      typeCol = DataColumn(
        numeric: true,
        label: SizedBox(
          width: typeWidth,
          child: const Align(
            alignment: Alignment.centerRight,
            child: Text('TYPE'),
          ),
        ),
        onSort: (i, asc) {
          sortColumnIndex = i;
          sortColumn = 'contentType';
          sortAsc = asc;
          SortChangedNotification(sortColumn, asc).dispatch(context);
        },
      );
    }

    DataColumn? sizeCol;
    if (showSize) {
      sizeCol = DataColumn(
        numeric: true,
        label: SizedBox(
          width: sizeWidth,
          child: const Align(
            alignment: Alignment.centerRight,
            child: Text('SIZE'),
          ),
        ),
        onSort: (i, asc) {
          sortColumnIndex = i;
          sortColumn = 'size';
          sortAsc = asc;
          SortChangedNotification(sortColumn, asc).dispatch(context);
        },
      );
    }

    DataColumn? dateCol;
    if (showDate) {
      dateCol = DataColumn(
        label: SizedBox(
          width: dateWidth,
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text('DATE\nCREATED', maxLines: 2, softWrap: true),
          ),
        ),
        onSort: (i, asc) {
          sortColumnIndex = i;
          sortColumn = 'date_created';
          sortAsc = asc;
          SortChangedNotification(sortColumn, asc).dispatch(context);
        },
      );
    }

    final actionsCol = DataColumn(
      label: SizedBox(
        width: actionsWidth,
        child: const Center(child: Text('')),
      ),
    );

    return [
      nameCol,
      if (typeCol != null) typeCol,
      if (sizeCol != null) sizeCol,
      if (dateCol != null) dateCol,
      actionsCol,
    ];
  }

  List<DataRow> getRows(
    BuildContext context,
    List<FileAsset> assets, {
    required double nameWidth,
    required double typeWidth,
    required double sizeWidth,
    required double dateWidth,
    required double actionsWidth,
    required bool showType,
    required bool showSize,
    required bool showDate,
    required bool useMenuActions,
  }) {
    final theme = Theme.of(context);
    final List<DataRow> rows = [];

    for (var f in assets) {
      final fileAsset = f is File ? f : null;
      final moment = Moment.fromMillisecondsSinceEpoch(
        f.dateCreated.millisecondsSinceEpoch,
        isUtc: true,
      );
      final nameCell = DataCell(
        SizedBox(
          width: nameWidth,
          child: Row(
            children: [
              fileAsset != null
                  ? (fileAsset.thumbnail == null && !_isImageFile(fileAsset))
                      ? SizedBox(
                        width: 50,
                        height: 32,
                        child: Center(
                          child: Icon(
                            getIconForMimeType(fileAsset.contentType),
                            color: _getIconColor(fileAsset.contentType),
                          ),
                        ),
                      )
                      : getImageComponent(fileAsset)
                  : const SizedBox(
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
          if (fileAsset != null) {
            FileSelectedNotification(fileAsset).dispatch(context);
          } else {
            PathChangedNotification(f, sortColumn, sortAsc).dispatch(context);
          }
        },
      );

      // ── Type cell ─────────────────────────────────────────────
      final typeCell = DataCell(
        SizedBox(
          width: typeWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              fileAsset != null
                  ? _formatType(fileAsset.contentType, fileAsset.name)
                  : f.name.toLowerCase().contains('library')
                  ? 'Library'
                  : 'Folder',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );

      // ── Size cell ─────────────────────────────────────────────
      final sizeCell = DataCell(
        SizedBox(
          width: sizeWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              fileAsset != null ? _formatBytes(fileAsset.size) : '--',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ),
      );

      // ── Date cell ─────────────────────────────────────────────
      final dateCell = DataCell(
        SizedBox(
          width: dateWidth,
          child: Align(
            alignment: Alignment.centerLeft,
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
        ),
        showEditIcon: false,
      );

      // ── Actions cell — full row of icon buttons or popup menu ─
      final actionsCell = DataCell(
        SizedBox(
          width: actionsWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child:
                  useMenuActions
                      ? _buildMenuActions(context, f, theme)
                      : _buildIconActions(context, f, theme),
            ),
          ),
        ),
      );

      rows.add(
        DataRow(
          selected: selectedRows.contains(f.path),
          cells: [
            nameCell,
            if (showType) typeCell,
            if (showSize) sizeCell,
            if (showDate) dateCell,
            actionsCell,
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
    return rows;
  }

  /// Three icon buttons: details, open, delete.
  Widget _buildIconActions(BuildContext context, FileAsset f, ThemeData theme) {
    if (f is! File) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              Icons.info_outline,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
            tooltip: 'Details',
            onPressed: () => FileSelectedNotification(f).dispatch(context),
          ),
        ),
        Flexible(
          child: IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              Icons.open_in_new,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
            ),
            tooltip: 'Open',
            onPressed: () async {
              if (f.path.startsWith('gdrive://')) {
                final id = f.path.substring(9);
                await launchUrl(
                  Uri.parse('https://drive.google.com/file/d/$id/view'),
                );
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
              color: theme.colorScheme.error.withValues(alpha: 0.8),
            ),
            tooltip: 'Delete',
            onPressed: () => _showDeleteConfirmationDialog(context, f),
          ),
        ),
      ],
    );
  }

  /// Collapsed ⋯ popup menu used at very narrow widths.
  Widget _buildMenuActions(BuildContext context, FileAsset f, ThemeData theme) {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: Icon(
        Icons.more_vert,
        size: 20,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
      ),
      tooltip: 'Actions',
      onSelected: (value) async {
        switch (value) {
          case 'details':
            FileSelectedNotification(f).dispatch(context);
          case 'open':
            if (f is File) {
              if (f.path.startsWith('gdrive://')) {
                final id = f.path.substring(9);
                await launchUrl(
                  Uri.parse('https://drive.google.com/file/d/$id/view'),
                );
              } else {
                await OpenFilex.open(f.path);
              }
            }
          case 'delete':
            if (f is File) _showDeleteConfirmationDialog(context, f);
        }
      },
      itemBuilder:
          (context) => [
            PopupMenuItem(
              value: 'details',
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: 8),
                  const Text('Details'),
                ],
              ),
            ),
            if (f is File)
              PopupMenuItem(
                value: 'open',
                child: Row(
                  children: [
                    const Icon(Icons.open_in_new, size: 16),
                    const SizedBox(width: 8),
                    const Text('Open'),
                  ],
                ),
              ),
            if (f is File)
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Delete',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ),
              ),
          ],
    );
  }

  bool _isImageFile(File file) {
    if (file.contentType == FilesConstants.mimeTypeImage) return true;
    if (file.contentType.startsWith('image/')) return true;
    final ext = p.extension(file.name).toLowerCase();
    return [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tif',
      '.psd',
    ].contains(ext);
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
      await FileDesktopRepository(
        DatabaseManager.instance.database!,
      ).delete(file);

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
    } else if (contentType == 'text/csv' ||
        contentType.contains('csv') ||
        contentType.contains('spreadsheet')) {
      return Icons.table_chart;
    } else if (contentType.contains('zip') ||
        contentType.contains('archive') ||
        contentType.contains('compressed')) {
      return Icons.folder_zip;
    } else if (contentType.startsWith('image/')) {
      return Icons.image;
    }
    return Icons.insert_drive_file;
  }

  Color _getIconColor(String contentType) {
    if (contentType == 'application/pdf') {
      return Colors.red.shade400;
    } else if (contentType == 'text/csv' ||
        contentType.contains('csv') ||
        contentType.contains('spreadsheet')) {
      return Colors.green.shade400;
    } else if (contentType.contains('zip') ||
        contentType.contains('archive') ||
        contentType.contains('compressed')) {
      return Colors.amber.shade400;
    }
    return Colors.grey.shade400;
  }

  String _formatType(String contentType, String name) {
    if (contentType == 'application/pdf') {
      return 'PDF Document';
    } else if (contentType == 'text/csv') {
      return 'CSV Spreadsheet';
    } else if (contentType == 'application/zip' ||
        contentType == 'application/x-zip-compressed' ||
        name.endsWith('.zip')) {
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
