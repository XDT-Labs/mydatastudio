import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatatools/modules/email/notifications/email_sort_changed_notification.dart';
import 'package:flutter/material.dart';
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
      color: Colors.white,
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
                horizontalMargin: 8,
                columnSpacing: 8,
                dataRowMaxHeight: 40,
                dataRowMinHeight: 40,
                headingRowHeight: 40,
                headingRowColor: WidgetStateProperty.all(Colors.white),
                rows: getRows(context, widget.emails, constraints.maxWidth),
              ),
            ),
          );
        },
      ),
    );
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
            onTap: () => EmailSelectedNotification(email).dispatch(context),
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
            onTap: () => EmailSelectedNotification(email).dispatch(context),
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
            onTap: () => EmailSelectedNotification(email).dispatch(context),
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
            onTap: () => EmailSelectedNotification(email).dispatch(context),
          ),
        ],
        onSelectChanged: (bool? e) {
          debugPrint("Email row select changed: ${email.subject} - $e");
          setState(() {
            email.isSelected = e ?? false;
            // Always dispatch notification when a row is clicked/selected
            EmailSelectedNotification(email).dispatch(context);
          });
        },
      );
    }).toList();
  }
}
