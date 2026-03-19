import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatatools/modules/email/notifications/email_sort_changed_notification.dart';
import 'package:flutter/material.dart';
import 'package:moment_dart/moment_dart.dart';
import 'dart:math' as math;

class EmailTable extends StatefulWidget {
  const EmailTable({super.key, required this.emails});

  final List<Email> emails;

  @override
  State<EmailTable> createState() => _EmailTable();
}

class _EmailTable extends State<EmailTable> {
  int sortColumnIndex = 0;
  String sortColumn = 'path';
  bool sortAsc = true;

  @override
  Widget build(BuildContext context) {
    List<DataColumn> columns = getColumns(context);

    return Container(
      color: Colors.grey.shade50,
      constraints: const BoxConstraints.expand(),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return SingleChildScrollView(
            child: DataTable(
              columns: columns,
              sortColumnIndex: sortColumnIndex,
              sortAscending: sortAsc,
              showCheckboxColumn: true,
              horizontalMargin: 12,
              dataRowMaxHeight: 40,
              dataRowMinHeight: 40,
              headingRowHeight: 40,
              rows: getRows(context, widget.emails, constraints.maxWidth),
            ),
          );
        },
      ),
    );
  }

  List<DataColumn> getColumns(BuildContext context) {
    return <DataColumn>[
      DataColumn(
        label: const Text(
          'From',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'from';
          sortAsc = sortAscending;
          EmailSortChangedNotification(sortColumn, sortAsc).dispatch(context);
        },
      ),
      const DataColumn(
        numeric: false,
        label: Text('Subject', style: TextStyle(fontWeight: FontWeight.normal)),
      ),
      const DataColumn(label: Icon(Icons.attachment, size: 16)),
      DataColumn(
        numeric: true,
        label: const Text(
          'Date',
          style: TextStyle(fontWeight: FontWeight.normal),
        ),
        onSort: (columnIndex, sortAscending) {
          sortColumnIndex = columnIndex;
          sortColumn = 'date';
          sortAsc = sortAscending;
          EmailSortChangedNotification(sortColumn, sortAsc).dispatch(context);
        },
      ),
    ];
  }

  List<DataRow> getRows(BuildContext context, List<Email> emails, double width) {
    return emails.map((email) {
      String from = email.from.split("<")[0].trim();
      Moment moment = Moment.fromMillisecondsSinceEpoch(
        email.date.toUtc().millisecondsSinceEpoch,
        isUtc: true,
      );

      bool isRead = email.isRead;

      return DataRow(
        selected: email.isSelected ?? false,
        cells: [
          DataCell(
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                from,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontWeight: isRead ? FontWeight.normal : FontWeight.bold,
                ),
              ),
            ),
            onTap: () => EmailSelectedNotification(email).dispatch(context),
          ),
          DataCell(
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: math.max(100.0, width - 400)),
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
            email.hasAttachments
                ? const Icon(Icons.attachment, size: 16, color: Colors.grey)
                : const SizedBox.shrink(),
            onTap: () => EmailSelectedNotification(email).dispatch(context),
          ),
          DataCell(
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 100),
              child: Tooltip(
                message: email.date.toLocal().toString(),
                child: Text(
                  moment.fromNow(form: Abbreviation.full),
                  overflow: TextOverflow.clip,
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
