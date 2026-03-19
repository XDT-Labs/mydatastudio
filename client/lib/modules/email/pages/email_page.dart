import 'dart:async';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatatools/modules/email/notifications/email_sort_changed_notification.dart';
import 'package:mydatatools/modules/email/pages/new_email_page.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/modules/email/services/get_emails_service.dart';
import 'package:mydatatools/modules/email/services/get_email_folders_service.dart';
import 'package:mydatatools/modules/email/widgets/email_details.dart';
import 'package:mydatatools/modules/email/widgets/email_table.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:rxdart/rxdart.dart';

class EmailPage extends StatefulWidget {
  const EmailPage({super.key});

  static BehaviorSubject<Collection?> selectedCollection = BehaviorSubject<Collection?>.seeded(null);
  static BehaviorSubject<String?> selectedFolder = BehaviorSubject<String?>.seeded(null);

  @override
  State<EmailPage> createState() => _EmailPage();
}

class _EmailPage extends State<EmailPage> {
  AppLogger logger = AppLogger(null);

  GetEmailsService? _emailService;
  GetCollectionsService? _collectionService;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;
  StreamSubscription? _selectedFolderSub;
  StreamSubscription? _emailsSub;
  StreamSubscription? _folderSub;
  
  List<Collection> collections = [];
  Collection? collection;
  String? selectedFolderName;
  int count = 0;
  List<Email> emails = [];
  String sortColumn = 'date';
  bool sortAsc = false;
  String emailLayout = 'vertical';
  Email? selectedEmail;
  double _drawerWidth = 600;
  bool isSidebarExpanded = false;
  bool isSearching = false;
  final TextEditingController searchController = TextEditingController();

  @override
  void initState() {
    _collectionService = GetCollectionsService.instance;

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      setState(() {
        collections = value;
      });
      if (value.isNotEmpty && EmailPage.selectedCollection.value == null) {
        //select default collection
        EmailPage.selectedCollection.add(value.first);
      }
    });

    _selectedCollectionSub = EmailPage.selectedCollection.listen((value) {
      if (value != null && collection != value) {
        setState(() {
          collection = value;
          // Reset folder when collection changes
          EmailPage.selectedFolder.add(null);
          selectedFolderName = null;
        });
        _refreshEmails();
      }
    });

    _selectedFolderSub = EmailPage.selectedFolder.listen((value) {
      if (mounted) {
        _refreshEmails();
        if (value == null) {
          setState(() => selectedFolderName = null);
        }
      }
    });
    
    _folderSub = GetEmailFoldersService.instance.sink.listen((List<EmailFolder> folders) {
      if (mounted && EmailPage.selectedFolder.value != null) {
        final folder = folders.where((f) => f.id == EmailPage.selectedFolder.value).firstOrNull;
        if (folder != null) {
          setState(() {
            selectedFolderName = folder.name;
          });
        }
      }
    });

    //get all email collections
    _collectionService?.invoke(GetCollectionsServiceCommand("email"));
    super.initState();
  }

  void _refreshEmails() {
    if (collection == null) return;

    _emailService = GetEmailsService.instance;
    if (_emailsSub != null) _emailsSub?.cancel();

    _emailsSub = _emailService!.sink.listen((value) {
      if (mounted) {
        setState(() {
          emails = value;
          count = value.length;
        });
      }
    });

    _emailService!.invoke(
      EmailServiceCommand(
        collection!,
        folderId: EmailPage.selectedFolder.value,
        search: searchController.text,
        sortColumn: sortColumn,
        sortAsc: sortAsc,
      ),
    );
    
    // Also trigger folder fetch to get names
    GetEmailFoldersService.instance.invoke(EmailFolderServiceCommand(collection!.id));
  }

  @override
  void dispose() {
    _emailsSub?.cancel();
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    _selectedFolderSub?.cancel();
    _folderSub?.cancel();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (collections.isEmpty) {
      return const NewEmailPage();
    }
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: isSearching
            ? TextField(
                controller: searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search emails...',
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  _refreshEmails();
                },
              )
            : getBreadcrumb(collection, selectedFolderName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(height: 1.0, color: Colors.grey.shade300),
        ),
        actions: <Widget>[
          if (isSearching)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.black),
              onPressed: () {
                setState(() {
                  isSearching = false;
                  searchController.clear();
                });
                _refreshEmails();
              },
            )
          else
            IconButton(
              icon: const Icon(Icons.search, color: Colors.black),
              tooltip: 'Search Emails',
              onPressed: () {
                setState(() {
                  isSearching = true;
                });
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.black),
            tooltip: 'Refresh',
            onPressed: () {
              if (collection != null) {
                logger.s("refresh emails");
                ScannerManager.getInstance()
                    .getScanner(collection!)
                    ?.start(collection!, null, true, true);
              }
            },
          ),
          const VerticalDivider(
            color: Colors.grey,
            thickness: 1,
            indent: 10,
            endIndent: 10,
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.black),
            tooltip: 'Delete Selected Messages',
            onPressed: emails.any((e) => e.isSelected == true)
                ? () => _showBulkDeleteConfirmation(context)
                : null,
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: NotificationListener<Notification>(
                    onNotification: (n) {
                      if (n is EmailSortChangedNotification) {
                        sortColumn = n.sortColumn;
                        sortAsc = n.sortAsc;
                        _emailService!.invoke(
                          EmailServiceCommand(
                            collection!,
                            folderId: EmailPage.selectedFolder.value,
                            search: searchController.text,
                            sortColumn: sortColumn,
                            sortAsc: sortAsc,
                          ),
                        );
                        return true;
                      }
                      if (n is EmailSelectedNotification) {
                        setState(() {
                          if (selectedEmail == null) {
                            // First open: Expand by default at 700px
                            _drawerWidth = 700.0;
                            isSidebarExpanded = true;
                          }
                          // Otherwise keep existing width/state
                          selectedEmail = n.email;
                        });
                        return true;
                      }
                      return false;
                    },
                    child: EmailTable(emails: emails),
                  ),
                ),
              ],
            ),
          ),
          if (selectedEmail != null) ...[
            // Drag handle
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _drawerWidth = (_drawerWidth - details.delta.dx)
                        .clamp(250.0, 900.0);
                    // Update expansion state based on 500px threshold
                    isSidebarExpanded = _drawerWidth > 500.0;
                  });
                },
                child: Container(
                  width: 10,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(
                      width: 1,
                      color: Colors.grey.shade300,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: _drawerWidth,
              child: EmailDetails(
                email: selectedEmail!,
                width: _drawerWidth,
                isExpanded: isSidebarExpanded,
                onClose: () => setState(() {
                  selectedEmail = null;
                  isSidebarExpanded = false;
                }),
                onExpand: () {
                  setState(() {
                    // Match File module's 300px / 700px toggle exactly
                    if (_drawerWidth >= 700.0) {
                      _drawerWidth = 300.0;
                      isSidebarExpanded = false;
                    } else {
                      _drawerWidth = 700.0;
                      isSidebarExpanded = true;
                    }
                  });
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  BreadCrumb getBreadcrumb(Collection? collection, String? folderName) {
    return BreadCrumb(
      items: <BreadCrumbItem>[
        BreadCrumbItem(
          content: const Icon(Icons.home, color: Colors.black),
          onTap: () {
            // maybe nav home
          },
        ),
        if (collection != null)
          BreadCrumbItem(
            content: Text(collection.name),
            onTap: () {
               EmailPage.selectedFolder.add(null);
            },
          ),
        if (folderName != null)
          BreadCrumbItem(
            content: Text(folderName),
            onTap: () {},
          ),
      ],
      divider: const Icon(Icons.chevron_right, color: Colors.black),
      overflow: const WrapOverflow(
        keepLastDivider: false,
        direction: Axis.horizontal,
      ),
    );
  }

  void _showBulkDeleteConfirmation(BuildContext context) {
    final selectedItems = emails.where((e) => e.isSelected == true).toList();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Emails'),
        content: Text('Are you sure you want to delete ${selectedItems.length} selected messages?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
             onPressed: () {
              Navigator.pop(context);
              _deleteSelectedEmails(selectedItems);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelectedEmails(List<Email> items) async {
    try {
      await EmailRepository(DatabaseManager.instance.database!).deleteEmails(items);
      _refreshEmails();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${items.length} messages deleted')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting emails: $e')),
        );
      }
    }
  }
}
