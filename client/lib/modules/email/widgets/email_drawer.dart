import 'dart:async';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
import 'package:mydatatools/modules/email/services/get_email_folders_service.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

class EmailDrawer extends StatefulWidget {
  const EmailDrawer({super.key});

  @override
  State<EmailDrawer> createState() => _EmailDrawer();
}

class _EmailDrawer extends State<EmailDrawer> {
  final AppLogger logger = AppLogger(null);
  final GetCollectionsService _collectionsService =
      GetCollectionsService.instance;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;
  StreamSubscription? _selectedFolderSub;

  List<Collection> collections = [];
  Collection? collection;
  String? selectedFolderId;

  @override
  void initState() {
    _collectionsServiceSub = _collectionsService.sink.listen((value) {
      if (mounted) {
        setState(() {
          collections = value.where((c) => c.type == 'email').toList();
        });
      }
    });

    _selectedCollectionSub = EmailPage.selectedCollection.listen((value) {
      if (mounted) {
        setState(() {
          collection = value;
        });
      }
    });

    _selectedFolderSub = EmailPage.selectedFolder.listen((value) {
      if (mounted) {
        setState(() {
          selectedFolderId = value;
        });
      }
    });

    // Deferred to post-frame: prevents the BehaviorSubject from replaying
    // its last value synchronously in initState(), which cascades setState()
    // calls before the first frame can render.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectionsService.invoke(GetCollectionsServiceCommand("email"));
    });
    super.initState();
  }

  @override
  void dispose() {
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    _selectedFolderSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 1. Grouping
    final Map<String, List<Collection>> grouped = {};
    for (var c in collections) {
      final groupName = _getGroupName(c);
      grouped.putIfAbsent(groupName, () => []).add(c);
    }

    // 2. Sort groups by their defined order
    final sortedGroupNames =
        grouped.keys.toList()..sort((a, b) {
          final orderA = _getGroupOrder(grouped[a]!.first.scanner);
          final orderB = _getGroupOrder(grouped[b]!.first.scanner);
          return orderA.compareTo(orderB);
        });

    // 3. Flatten into a list with headers for the ListView
    final List<dynamic> flatList = [];
    for (final groupName in sortedGroupNames) {
      flatList.add(groupName);

      final groupItems = grouped[groupName]!;
      // Sort within the group alphabetically
      groupItems.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      flatList.addAll(groupItems);
    }

    return SizedBox.expand(
      child: Container(
        height: double.infinity,
        color: Colors.white,
        padding: const EdgeInsets.all(8),
        child: Scaffold(
          backgroundColor: Colors.white,
          floatingActionButton: FloatingActionButton(
            tooltip: "Add Email",
            backgroundColor: Colors.white,
            elevation: 2,
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: Colors.grey, width: 1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.add, color: Colors.grey),
            onPressed: () {
              GoRouter.of(context).go("/email/add");
            },
          ),
          body: Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8.0),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    "SOURCES",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      color: Colors.grey,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: flatList.length,
                  itemBuilder: (context, index) {
                    final item = flatList[index];

                    if (item is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                        child: Text(
                          item.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: 0.1,
                            ),
                            letterSpacing: 1.0,
                          ),
                        ),
                      );
                    }

                    final col = item as Collection;
                    return _AccountExpansionTile(
                      collection: col,
                      isSelected: collection?.id == col.id,
                      selectedFolderId: selectedFolderId,
                      onAccountTap: () {
                        EmailPage.selectedCollection.add(col);
                        EmailPage.selectedFolder.add(null);
                        context.go('/email');
                      },
                      onFolderTap: (folderId) {
                        EmailPage.selectedCollection.add(col);
                        EmailPage.selectedFolder.add(folderId);
                        context.go('/email');
                      },
                      onDelete:
                          () => _showDeleteConfirmationDialog(context, col),
                      onSync: () async {
                        if (col.scanner ==
                            AppConstants.scannerEmailOutlookPst) {
                          // For PST we run one-time import isolate
                          final writerPort =
                              await DatabaseManager.instance.writerPort;
                          final serverUrl = MainApp.llmServiceUrl.value;
                          final appDataDir =
                              MainApp.appDataDirectory.valueOrNull;

                          if (serverUrl != null && appDataDir != null) {
                            final pstIsolate = OutlookPstScannerIsolate(
                              token: RootIsolateToken.instance,
                              dbWriterPort: writerPort,
                              appDir: appDataDir,
                              serverUrl: serverUrl,
                            );
                            ScannerManager.getInstance().pstScanners[col.id] =
                                pstIsolate;
                            await pstIsolate.start(col, force: true);
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Cannot start PST sync: services or directory not ready',
                                  ),
                                ),
                              );
                            }
                          }
                        } else {
                          ScannerManager.getInstance()
                              .getScanner(col)
                              ?.start(col, null, true, true);
                        }
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getGroupName(Collection c) {
    switch (c.scanner) {
      case AppConstants.scannerEmailGmail:
        return 'Gmail';
      case AppConstants.scannerEmailYahoo:
        return 'Yahoo';
      case AppConstants.scannerEmailOutlook:
        return 'Outlook';
      default:
        return 'Other';
    }
  }

  int _getGroupOrder(String scanner) {
    switch (scanner) {
      case AppConstants.scannerEmailGmail:
        return 0;
      case AppConstants.scannerEmailYahoo:
        return 1;
      case AppConstants.scannerEmailOutlook:
        return 2;
      default:
        return 3;
    }
  }

  void _showDeleteConfirmationDialog(
    BuildContext context,
    Collection collection,
  ) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Delete'),
          content: Text(
            'Are you sure you want to delete the account "${collection.name}" and all of its emails from this application?\n\nThis will NOT delete any emails from the actual server.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                Navigator.of(context).pop();

                // 1. Show progress in the header
                EmailPage.isDeleting.add(true);

                try {
                  // 2. Stop any running scanner for this collection
                  ScannerManager.getInstance().stopScanner(collection.id);

                  // 3. Cancel the reactive folder watch for this account so
                  //    the orphaned subscription can't keep firing on the main
                  //    thread after the account data is gone.
                  GetEmailFoldersService.instance.disposeCollection(
                    collection.id,
                  );

                  // 4. Send delete command to background isolate
                  final writer = DatabaseManager.instance.writerIsolateClient;
                  if (writer != null) {
                    await writer.send({
                      'type': 'delete_collection',
                      'id': collection.id,
                    });
                  } else {
                    // Fallback to repository if writer is unavailable
                    await CollectionRepository().deleteCollection(
                      collection.id,
                    );
                  }

                  // 5. Refresh and cleanup
                  _collectionsService.invoke(
                    GetCollectionsServiceCommand("email"),
                  );
                  if (EmailPage.selectedCollection.value?.id == collection.id) {
                    EmailPage.selectedCollection.add(null);
                  }
                } finally {
                  // 6. Hide progress
                  EmailPage.isDeleting.add(false);
                }
              },
            ),
          ],
        );
      },
    );
  }
}

class _AccountExpansionTile extends StatefulWidget {
  final Collection collection;
  final bool isSelected;
  final String? selectedFolderId;
  final VoidCallback onAccountTap;
  final Function(String?) onFolderTap;
  final VoidCallback onSync;
  final VoidCallback onDelete;

  const _AccountExpansionTile({
    required this.collection,
    required this.isSelected,
    required this.selectedFolderId,
    required this.onAccountTap,
    required this.onFolderTap,
    required this.onSync,
    required this.onDelete,
  });

  @override
  State<_AccountExpansionTile> createState() => _AccountExpansionTileState();
}

class _AccountExpansionTileState extends State<_AccountExpansionTile> {
  StreamSubscription? _folderSub;
  List<EmailFolder> folders = [];

  @override
  void initState() {
    super.initState();
    _folderSub = GetEmailFoldersService.instance.sink.listen((value) {
      if (mounted) {
        // Filter folders for this specific collection
        final myFolders =
            value.where((f) => f.collectionId == widget.collection.id).toList();
        if (myFolders.isNotEmpty) {
          setState(() {
            folders = myFolders;
          });
        }
      }
    });
    // Deferred to post-frame: each visible account tile calls invoke() when
    // mounted. Without deferral, N accounts fire N simultaneous DB queries
    // whose BehaviorSubject callbacks all cascade setState() before the first
    // frame can paint, causing the OS spinner on source click.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        GetEmailFoldersService.instance.invoke(
          EmailFolderServiceCommand(widget.collection.id),
        );
      }
    });
  }

  @override
  void dispose() {
    _folderSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Find Inbox and Sent folders
    EmailFolder? inbox;
    EmailFolder? sent;
    final List<EmailFolder> otherFolders = [];

    for (var f in folders) {
      final normalizedId = f.id.toUpperCase();
      final normalizedName = f.name.toUpperCase();

      if (normalizedId == 'INBOX' || normalizedName == 'INBOX') {
        inbox = f;
      } else if (normalizedId == 'SENT' || normalizedName == 'SENT') {
        sent = f;
      } else {
        otherFolders.add(f);
      }
    }

    // Sort other folders alphabetically
    otherFolders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    return ExpansionTile(
      initiallyExpanded: widget.isSelected,
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      title: Text(
        widget.collection.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (val) {
              if (val == 'sync') widget.onSync();
              if (val == 'delete') widget.onDelete();
            },
            itemBuilder:
                (context) => [
                  const PopupMenuItem(
                    value: 'sync',
                    child: Text('Sync Account'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete Account'),
                  ),
                ],
          ),
        ],
      ),
      children: [
        if (inbox != null)
          _buildFolderTile(context, inbox, "Inbox", Icons.inbox),
        if (sent != null) _buildFolderTile(context, sent, "Sent", Icons.send),

        if (otherFolders.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.only(left: 48.0, right: 16.0),
              title: const Text("All Folders", style: TextStyle(fontSize: 13)),
              leading: const Icon(Icons.folder_outlined, size: 20),
              dense: true,
              children:
                  otherFolders
                      .map(
                        (f) => _buildFolderTile(
                          context,
                          f,
                          f.name,
                          null,
                          indent: 32,
                        ),
                      )
                      .toList(),
            ),
          ),
      ],
    );
  }

  Widget _buildFolderTile(
    BuildContext context,
    EmailFolder f,
    String label,
    IconData? icon, {
    double indent = 48.0,
  }) {
    final theme = Theme.of(context);
    final isSelected = widget.isSelected && widget.selectedFolderId == f.id;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 8.0),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: indent - 8.0),
        leading:
            icon != null
                ? Icon(
                  icon,
                  size: 18,
                  color: isSelected ? theme.colorScheme.primary : null,
                )
                : null,
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing:
            (f.messagesUnread ?? 0) > 0
                ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    f.messagesUnread.toString(),
                    style: TextStyle(
                      fontSize: 10,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                )
                : null,
        selected: isSelected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.3,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: () => widget.onFolderTap(f.id),
      ),
    );
  }
}
