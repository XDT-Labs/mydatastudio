import 'dart:async';

import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
import 'package:mydatatools/modules/email/services/get_email_folders_service.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class EmailDrawer extends StatefulWidget {
  const EmailDrawer({super.key});

  @override
  State<EmailDrawer> createState() => _EmailDrawer();
}

class _EmailDrawer extends State<EmailDrawer> {
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

    _collectionsService.invoke(GetCollectionsServiceCommand("email"));
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
    return SizedBox.expand(
      child: Container(
        height: double.infinity,
        color: Colors.transparent,
        padding: const EdgeInsets.all(8),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton(
            tooltip: "Add Email",
            backgroundColor: Colors.transparent,
            elevation: 0,
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
                padding: EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    "ACCOUNTS",
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
                  itemCount: collections.length,
                  itemBuilder: (context, index) {
                    final col = collections[index];
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
                      onDelete: () => _showDeleteConfirmationDialog(context, col),
                      onSync: () {
                        ScannerManager.getInstance()
                            .getScanner(col)
                            ?.start(col, null, true, true);
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

  void _showDeleteConfirmationDialog(BuildContext context, Collection collection) {
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
                await CollectionRepository().deleteCollection(collection.id);
                // Also need to delete folders/emails explicitly if the repository doesn't handles cascade in drift
                // For now assuming the repo handles it or we'll add it.
                _collectionsService.invoke(GetCollectionsServiceCommand("email"));
                if (EmailPage.selectedCollection.value?.id == collection.id) {
                   EmailPage.selectedCollection.add(null);
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
        final myFolders = value.where((f) => f.collectionId == widget.collection.id).toList();
        if (myFolders.isNotEmpty) {
           setState(() {
            folders = myFolders;
          });
        }
      }
    });
    GetEmailFoldersService.instance.invoke(EmailFolderServiceCommand(widget.collection.id));
  }

  @override
  void dispose() {
    _folderSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return ExpansionTile(
      initiallyExpanded: widget.isSelected,
      leading: Icon(
        widget.collection.scanner == AppConstants.scannerEmailGmail 
          ? Icons.mail 
          : Icons.email_outlined,
        color: widget.isSelected ? theme.colorScheme.primary : null,
      ),
      title: Text(
        widget.collection.name,
        style: TextStyle(
          fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
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
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'sync', child: Text('Sync Account')),
              const PopupMenuItem(value: 'delete', child: Text('Delete Account')),
            ],
          ),
        ],
      ),
      children: [
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 48),
          title: const Text("All Inboxes"),
          selected: widget.isSelected && widget.selectedFolderId == null,
          onTap: widget.onAccountTap,
        ),
        ...folders.map((f) => ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 48),
          title: Text(f.name),
          trailing: (f.messagesUnread ?? 0) > 0 
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  f.messagesUnread.toString(),
                  style: TextStyle(fontSize: 10, color: theme.colorScheme.onPrimaryContainer),
                ),
              )
            : null,
          selected: widget.isSelected && widget.selectedFolderId == f.id,
          onTap: () => widget.onFolderTap(f.id),
        )),
      ],
    );
  }
}
