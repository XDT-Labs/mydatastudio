import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatastudio/modules/email/notifications/email_selection_changed_notification.dart';
import 'package:mydatastudio/modules/email/notifications/email_sort_changed_notification.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:moment_dart/moment_dart.dart';
import 'dart:math' as math;

class EmailTable extends StatefulWidget {
  const EmailTable({
    super.key,
    required this.emails,
    this.scrollController,
    this.sortColumn = 'date',
    this.sortAsc = false,
    this.onLoadMore,
  });

  final List<Email> emails;

  /// Called when the user scrolls near the bottom of the list. Implementations
  /// should fetch the next page of emails and append them.
  final VoidCallback? onLoadMore;
  final ScrollController? scrollController;
  final String sortColumn;
  final bool sortAsc;

  @override
  State<EmailTable> createState() => _EmailTable();
}

class _EmailTable extends State<EmailTable> {
  late int sortColumnIndex;
  late String sortColumn;
  late bool sortAsc;

  late ScrollController _verticalScrollController;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _updateSortParams();
    if (widget.scrollController != null) {
      _verticalScrollController = widget.scrollController!;
      _ownsController = false;
    } else {
      _verticalScrollController = ScrollController();
      _ownsController = true;
    }
    _verticalScrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(EmailTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sortColumn != widget.sortColumn ||
        oldWidget.sortAsc != widget.sortAsc) {
      _updateSortParams();
    }
  }

  void _updateSortParams() {
    sortColumn = widget.sortColumn;
    sortAsc = widget.sortAsc;
    if (sortColumn == 'from') {
      sortColumnIndex = 0;
    } else if (sortColumn == 'date') {
      sortColumnIndex = 3;
    } else {
      sortColumnIndex = 1; // Default to subject index
    }
  }

  void _onScroll() {
    if (widget.onLoadMore == null) return;
    final pos = _verticalScrollController.position;
    // Trigger load-more when within 200px of the bottom
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      widget.onLoadMore!();
    }
  }

  @override
  void dispose() {
    _verticalScrollController.removeListener(_onScroll);
    if (_ownsController) {
      _verticalScrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.transparent,
      constraints: const BoxConstraints.expand(),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final List<DataColumn> columns = getColumns(
            context,
            constraints.maxWidth,
          );

          return SingleChildScrollView(
            controller: _verticalScrollController,
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: columns,
                sortColumnIndex: sortColumnIndex,
                sortAscending: sortAsc,
                showCheckboxColumn: true,
                onSelectAll: _onSelectAll,
                horizontalMargin: 8,
                columnSpacing: 8,
                dataRowMaxHeight: 40,
                dataRowMinHeight: 40,
                headingRowHeight: 40,
                headingRowColor: WidgetStateProperty.all(Colors.transparent),
                rows: getRows(context, widget.emails, constraints.maxWidth),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Handles the heading select-all checkbox.
  ///
  /// Must be supplied: with `onSelectAll` null, [DataTable] falls back to
  /// invoking every row's `onSelectChanged`, so ticking select-all also ran the
  /// per-row handler for each message.
  void _onSelectAll(bool? checked) {
    final select = checked ?? false;
    setState(() {
      for (final email in widget.emails) {
        email.isSelected = select;
      }
    });
    // Whatever row the user last picked is no longer a meaningful place to
    // extend a range from once everything has been set at once.
    _anchorId = null;
    EmailSelectionChangedNotification().dispatch(context);
  }

  /// The fixed end of a shift-click range: the last row checked *without*
  /// shift.
  ///
  /// Held as a message id rather than a row index because the list is re-sorted
  /// and re-paged underneath this table — an index would quietly come to mean a
  /// different message, and the range would run to the wrong place.
  String? _anchorId;

  /// Applies [selected] to a row, or to a whole range when shift is held.
  ///
  /// Shift-click extending a selection is what every mail client does, and
  /// without it marking a run of messages for deletion means clicking each one.
  /// The value being applied is the one the clicked row is taking, so
  /// shift-clicking a checked row clears the range instead of setting it.
  ///
  /// Rows outside the range are deliberately left alone: the anchor stays put
  /// so the range can be adjusted by shift-clicking again, and silently
  /// dropping selections the user made elsewhere would be worse than leaving
  /// them.
  void _applySelection(Email email, bool selected) {
    final anchorId = _anchorId;
    final anchorIndex =
        anchorId == null
            ? -1
            : widget.emails.indexWhere((e) => e.id == anchorId);
    final clickedIndex = widget.emails.indexWhere((e) => e.id == email.id);

    // No anchor (or one that has since scrolled out of the loaded page) leaves
    // nothing to extend from, so this falls back to a plain single-row toggle.
    if (HardwareKeyboard.instance.isShiftPressed &&
        anchorIndex >= 0 &&
        clickedIndex >= 0) {
      final start = math.min(anchorIndex, clickedIndex);
      final end = math.max(anchorIndex, clickedIndex);
      setState(() {
        for (var i = start; i <= end; i++) {
          widget.emails[i].isSelected = selected;
        }
      });
      EmailSelectionChangedNotification().dispatch(context);
      return;
    }

    setState(() => email.isSelected = selected);
    _anchorId = email.id;
    EmailSelectionChangedNotification().dispatch(context);
  }

  /// Handles a tap on a row's content — as opposed to its checkbox.
  ///
  /// Normally that opens the message. Shift-click never means "open": it is a
  /// range gesture, and the checkbox is a small target to have to hit for it.
  void _onCellTap(Email email) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      _applySelection(email, !(email.isSelected ?? false));
      return;
    }
    EmailSelectedNotification(email).dispatch(context);
  }

  List<DataColumn> getColumns(BuildContext context, double totalWidth) {
    const double fromWidth = 180.0;
    const double attachmentWidth = 32.0;
    const double dateWidth = 100.0;
    const double checkboxAndMarginWidth = 100.0;

    final double subjectWidth = math.max(
      100.0,
      totalWidth -
          (fromWidth + attachmentWidth + dateWidth + checkboxAndMarginWidth),
    );

    return <DataColumn>[
      DataColumn(
        label: const SizedBox(
          width: fromWidth,
          child: Text('From', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        onSort: (columnIndex, sortAscending) {
          setState(() {
            sortColumnIndex = columnIndex;
            sortColumn = 'from';
            sortAsc = sortAscending;
          });
          EmailSortChangedNotification(sortColumn, sortAsc).dispatch(context);
        },
      ),
      DataColumn(
        numeric: false,
        label: SizedBox(
          width: subjectWidth,
          child: const Text(
            'Subject',
            style: TextStyle(fontWeight: FontWeight.normal),
          ),
        ),
        onSort: (columnIndex, sortAscending) {
          setState(() {
            sortColumnIndex = columnIndex;
            sortColumn = 'subject';
            sortAsc = sortAscending;
          });
          EmailSortChangedNotification(sortColumn, sortAsc).dispatch(context);
        },
      ),
      const DataColumn(
        label: SizedBox(
          width: attachmentWidth,
          child: Icon(Icons.attachment, size: 16),
        ),
      ),
      DataColumn(
        numeric: false,
        label: const SizedBox(
          width: dateWidth,
          child: Text('Date', style: TextStyle(fontWeight: FontWeight.normal)),
        ),
        onSort: (columnIndex, sortAscending) {
          setState(() {
            sortColumnIndex = columnIndex;
            sortColumn = 'date';
            sortAsc = sortAscending;
          });
          EmailSortChangedNotification(sortColumn, sortAsc).dispatch(context);
        },
      ),
    ];
  }

  List<DataRow> getRows(
    BuildContext context,
    List<Email> emails,
    double totalWidth,
  ) {
    // Estimated widths for fixed columns
    const double fromWidth = 180.0;
    const double attachmentWidth = 32.0;
    const double dateWidth = 100.0;
    const double checkboxAndMarginWidth =
        100.0; // Space for the leading checkbox and cell margins

    // Calculate subject width to fill the remaining space
    final double subjectWidth = math.max(
      120.0,
      totalWidth -
          (fromWidth + attachmentWidth + dateWidth + checkboxAndMarginWidth),
    );

    return emails.map((email) {
      String from = email.from.split("<")[0].trim();
      Moment moment = Moment(email.date.toLocal());
      bool isToday =
          moment.format("yyyy-MM-dd") == Moment.now().format("yyyy-MM-dd");

      bool isRead = email.isRead;

      return DataRow(
        selected: email.isSelected ?? false,
        cells: [
          DataCell(
            SizedBox(
              width: fromWidth,
              child: Text(
                from,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                ),
              ),
            ),
            onTap: () => _onCellTap(email),
          ),
          DataCell(
            SizedBox(
              width: subjectWidth,
              child: Text(
                email.subject ?? '',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                ),
              ),
            ),
            onTap: () => _onCellTap(email),
          ),
          DataCell(
            SizedBox(
              width: attachmentWidth,
              child:
                  email.hasAttachments
                      ? const Icon(
                        Icons.attachment,
                        size: 16,
                        color: Colors.grey,
                      )
                      : const SizedBox.shrink(),
            ),
            onTap: () => _onCellTap(email),
          ),
          DataCell(
            SizedBox(
              width: dateWidth,
              child: Tooltip(
                message: moment.format("LLLL"),
                child: Text(
                  isToday
                      ? moment.format("h:mm A")
                      : moment.format("M/DD/YYYY"),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                  ),
                ),
              ),
            ),
            onTap: () => _onCellTap(email),
          ),
        ],
        // Only reached via the row's checkbox — every cell above has its own
        // onTap, which is what opens the message. Checking a row marks it for a
        // bulk action and nothing else; it used to also dispatch
        // EmailSelectedNotification, which is why ticking a checkbox opened the
        // email.
        onSelectChanged: (bool? e) => _applySelection(email, e ?? false),
      );
    }).toList();
  }
}
