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

  static BehaviorSubject<Collection?> selectedCollection =
      BehaviorSubject<Collection?>.seeded(null);
  static BehaviorSubject<String?> selectedFolder =
      BehaviorSubject<String?>.seeded(null);
  static BehaviorSubject<bool> isDeleting = BehaviorSubject<bool>.seeded(false);

  @override
  State<EmailPage> createState() => _EmailPage();
}

class _EmailPage extends State<EmailPage> {
  AppLogger logger = AppLogger(null);


  GetCollectionsService? _collectionService;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;
  StreamSubscription? _selectedFolderSub;
  StreamSubscription? _emailsSub;
  StreamSubscription? _folderSub;
  StreamSubscription? _scannerSub;

  List<Collection> collections = [];
  Collection? collection;
  bool isScanning = false;
  String? selectedFolderName;
  int count = 0;
  List<Email> emails = [];
  String sortColumn = 'date';
  bool sortAsc = false;
  String emailLayout = 'vertical';

  final ScrollController _scrollController = ScrollController();
  static const int _pageSize = 100;
  int _currentOffset = 0;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  Email? selectedEmail;
  double _drawerWidth = 600;
  bool isSidebarExpanded = false;
  bool isSearching = false;
  final TextEditingController searchController = TextEditingController();
  bool _needsFolderAutoSelect = false;

  @override
  void initState() {
    _scrollController.addListener(_onScroll);
    _collectionService = GetCollectionsService.instance;

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      final emailCollections = value.where((c) => c.type == 'email').toList();
      setState(() {
        collections = emailCollections;
      });
      if (emailCollections.isNotEmpty &&
          EmailPage.selectedCollection.value == null) {
        //select default collection
        _needsFolderAutoSelect = true;
        EmailPage.selectedCollection.add(emailCollections.first);
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
        _listenToScannerStatus(value);
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

    _folderSub = GetEmailFoldersService.instance.sink.listen((
      List<EmailFolder> folders,
    ) {
      if (mounted) {
        if (_needsFolderAutoSelect && folders.isNotEmpty) {
          _needsFolderAutoSelect = false;
          final inbox =
              folders
                  .where(
                    (f) =>
                        f.id.toUpperCase() == 'INBOX' ||
                        f.name.toUpperCase() == 'INBOX',
                  )
                  .firstOrNull;
          if (inbox != null) {
            EmailPage.selectedFolder.add(inbox.id);
          }
        }

        if (EmailPage.selectedFolder.value != null) {
          final folder =
              folders
                  .where((f) => f.id == EmailPage.selectedFolder.value)
                  .firstOrNull;
          if (folder != null) {
            setState(() {
              selectedFolderName = folder.name;
            });

            // Automatically sync the folder after we have its name
            if (collection != null) {
              logger.s(
                "Refreshing $selectedFolderName folder for ${collection!.name}",
              );
              ScannerManager.getInstance()
                  .getScanner(collection!)
                  ?.start(collection!, folder.id, true, true);
            }
          }
        }
      }
    });

    //get all email collections — deferred to post-frame so the first frame
    // renders immediately without triggering a synchronous BehaviorSubject
    // replay cascade (listen() → setState → invoke → setState chain).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectionService?.invoke(GetCollectionsServiceCommand("email"));
    });
    super.initState();
  }

  void _refreshEmails() {
    if (collection == null) return;

    if (mounted) {
      setState(() {
        emails = [];
        _currentOffset = 0;
        _hasMore = true;
        _isLoadingMore = false;
      });
    }

    _loadMoreEmails();

    // Also trigger folder fetch to get names
    GetEmailFoldersService.instance.invoke(
      EmailFolderServiceCommand(collection!.id),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    // Check if we are ~70% through the list
    if (currentScroll >= (maxScroll * 0.7) && !_isLoadingMore && _hasMore) {
      _loadMoreEmails();
    }
  }

  void _listenToScannerStatus(Collection? c) {
    _scannerSub?.cancel();
    _scannerSub = null;
    if (c == null) {
      if (mounted) setState(() => isScanning = false);
      return;
    }

    // Set to false initially until we get the actual scanner status
    if (mounted) setState(() => isScanning = false);

    // Robustly wait for the scanner to be registered
    final mgr = ScannerManager.getInstance();
    mgr.getScannerAsync(c).then((scanner) {
      if (!mounted) return;
      // Ensure we are still interested in this same collection
      if (EmailPage.selectedCollection.value?.id != c.id) return;

      _scannerSub = scanner.isScanning.listen((scanning) {
        if (mounted) {
          setState(() {
            isScanning = scanning;
          });
        }
      });
    });
  }

  Future<void> _loadMoreEmails() async {
    if (!_hasMore || _isLoadingMore || collection == null) return;
    setState(() => _isLoadingMore = true);

    final nextOffset = _currentOffset + _pageSize;
    final nextPage = await EmailRepository(
      DatabaseManager.instance.database!,
    ).emails(
      collection!.id,
      folderId: EmailPage.selectedFolder.value,
      search: searchController.text,
      sortColumn: sortColumn,
      sortAsc: sortAsc,
      limit: _pageSize,
      offset: nextOffset,
    );

    if (mounted) {
      setState(() {
        _currentOffset = nextOffset;
        emails = [...emails, ...nextPage];
        count = emails.length;
        _hasMore = nextPage.length >= _pageSize;
        _isLoadingMore = false;
      });
    }
  }

  @override
  void dispose() {
    _emailsSub?.cancel();
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    _selectedFolderSub?.cancel();
    _folderSub?.cancel();
    _scannerSub?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (collections.isEmpty) {
      return const NewEmailPage();
    }
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title:
            isSearching
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
        bottom: (isScanning || _isLoadingMore)
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2.0),
                child: LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                ),
              )
            : null,
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
            tooltip: 'Refresh Current Folder',
            onPressed: () {
              if (collection != null &&
                  EmailPage.selectedFolder.value != null) {
                final folderId = EmailPage.selectedFolder.value!;
                logger.s(
                  "Refreshing $selectedFolderName folder for ${collection!.name}",
                );

                ScannerManager.getInstance()
                    .getScanner(collection!)
                    ?.start(collection!, folderId, true, true);
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
            onPressed:
                emails.any((e) => e.isSelected == true)
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
                        _refreshEmails();
                        return true;
                      }
                      if (n is EmailSelectedNotification) {
                        logger.i("Email selected: ${n.email.subject}");
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
                    child:
                        emails.isEmpty && (isScanning || _isLoadingMore)
                            ? (isScanning
                                ? _buildScanningPlaceholder()
                                : const Center(
                                  child: CircularProgressIndicator(),
                                ))
                            : EmailTable(
                              emails: emails,
                              scrollController: _scrollController,
                              sortColumn: sortColumn,
                              sortAsc: sortAsc,
                              onLoadMore: _loadMoreEmails,
                            ),
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
                    _drawerWidth = (_drawerWidth - details.delta.dx).clamp(
                      250.0,
                      900.0,
                    );
                    // Update expansion state based on 500px threshold
                    isSidebarExpanded = _drawerWidth > 500.0;
                  });
                },
                child: Container(
                  width: 10,
                  color: Colors.transparent,
                  child: Center(
                    child: Container(width: 1, color: Colors.grey.shade300),
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
                onClose:
                    () => setState(() {
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
          BreadCrumbItem(content: Text(folderName), onTap: () {}),
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
      builder:
          (context) => AlertDialog(
            title: const Text('Delete Emails'),
            content: Text(
              'Are you sure you want to delete ${selectedItems.length} selected messages?\nThese will be deleted locally and on the server.',
            ),
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
                child: const Text(
                  'Delete',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
    );
  }

  Future<void> _deleteSelectedEmails(List<Email> items) async {
    try {
      final ids = items.map((e) => e.id).toList();

      // 1. Remote Delete (if applicable)
      if (collection != null) {
        final scanner = ScannerManager.getInstance().getScanner(collection!);
        if (scanner != null) {
          final groupedByFolder = <String, List<int>>{};

          for (var item in items) {
            if (item.uid != null) {
              // Priority: item's folder, then current view's folder, finally fallback to INBOX safely
              final fId =
                  item.folderId ?? EmailPage.selectedFolder.value ?? 'INBOX';
              groupedByFolder.putIfAbsent(fId, () => []).add(item.uid!);
            }
          }

          for (var entry in groupedByFolder.entries) {
            scanner.moveToTrash(collection!, entry.key, entry.value);
          }
        }
      }

      // 2. Local Delete
      await EmailRepository(
        DatabaseManager.instance.appDatabase!,
      ).deleteEmails(ids);

      _refreshEmails();
      if (mounted) {
        setState(() {
          selectedEmail = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${items.length} messages deleted and moved to Trash on server',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error deleting emails: $e')));
      }
    }
  }

  Widget _buildScanningPlaceholder() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Scanning ${collection?.name ?? "emails"}...',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            'This may take a minute for large accounts.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
