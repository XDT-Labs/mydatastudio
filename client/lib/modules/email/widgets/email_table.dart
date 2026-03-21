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
  });

  final List<Email> emails;
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

  @override
  void initState() {
    super.initState();
    _updateSortParams();
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade50,
      constraints: const BoxConstraints.expand(),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final List<DataColumn> columns = getColumns(
            context,
            constraints.maxWidth,
          );

          return SingleChildScrollView(
            scrollDirection: Axis.vertical,
            controller: widget.scrollController,
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
          setState(() {
            email.isSelected = e ?? false;
            if (email.isSelected == true) {
              EmailSelectedNotification(email).dispatch(context);
            }
          });
        },
      );
    }).toList();
  }
}
