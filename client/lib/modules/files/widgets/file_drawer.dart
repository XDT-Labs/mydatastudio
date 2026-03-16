import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class FileDrawer extends StatefulWidget {
  const FileDrawer({super.key});

  @override
  State<FileDrawer> createState() => _FileDrawer();
}

class _FileDrawer extends State<FileDrawer> {
  GetCollectionsService? _collectionService;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;

  List<Collection> collections = [];
  Collection? collection;

  @override
  void initState() {
    _collectionService = GetCollectionsService.instance;

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      if (mounted) {
        setState(() {
          collections = value;
        });
      }
    });



    _selectedCollectionSub = RxFilesPage.selectedCollection.listen((value) {
      if (mounted) {
        setState(() {
          collection = value;
        });
      }
    });

    _collectionService!.invoke(GetCollectionsServiceCommand(null));

    super.initState();
  }

  @override
  void dispose() {
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    super.dispose();
  }

  String _getDisplayName(Collection c) {
    if (c.scanner == AppConstants.scannerFileGDrive) {
      final parts = c.name.split(' (');
      if (parts.length > 1) {
        // Extract the email inside the parentheses
        return parts[1].replaceAll(')', '');
      }
    }
    return c.name;
  }

  String? _getSubtitle(Collection c) {
    // Removed subtitles for Local and Google Drive as requested
    return null;
  }

  String _getGroupName(Collection c) {
    switch (c.scanner) {
      case AppConstants.scannerFileLocal:
        return 'Local';
      case AppConstants.scannerFileGDrive:
        return 'Google Drive';
      case AppConstants.scannerFileDropbox:
        return 'Dropbox';
      case AppConstants.scannerFileOneDrive:
        return 'OneDrive';
      default:
        return 'Other';
    }
  }

  int _getGroupOrder(String scanner) {
    switch (scanner) {
      case AppConstants.scannerFileLocal:
        return 0;
      case AppConstants.scannerFileGDrive:
        return 1;
      case AppConstants.scannerFileDropbox:
        return 2;
      case AppConstants.scannerFileOneDrive:
        return 3;
      default:
        return 4;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 1. Filter
    final List<Collection> filesC = collections.where((element) => element.type == 'file').toList();

    // 2. Grouping
    final Map<String, List<Collection>> grouped = {};
    for (var c in filesC) {
      final groupName = _getGroupName(c);
      grouped.putIfAbsent(groupName, () => []).add(c);
    }

    // 3. Sort groups by their defined order
    final sortedGroupNames = grouped.keys.toList()
      ..sort((a, b) {
        final orderA = _getGroupOrder(grouped[a]!.first.scanner);
        final orderB = _getGroupOrder(grouped[b]!.first.scanner);
        return orderA.compareTo(orderB);
      });

    // 4. Flatten into a list with headers for the ListView
    final List<dynamic> flatList = [];
    for (final groupName in sortedGroupNames) {
      flatList.add(groupName); // Add the group header
      
      final groupItems = grouped[groupName]!;
      // Sort within the group alphabetically by display name
      groupItems.sort((a, b) {
        final nameA = _getDisplayName(a).toLowerCase();
        final nameB = _getDisplayName(b).toLowerCase();
        int cmp = nameA.compareTo(nameB);
        if (cmp == 0) {
          // If display names are identical, fall back to the full name
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        return cmp;
      });
      flatList.addAll(groupItems);
    }

    return SizedBox.expand(
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.all(8),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton(
            backgroundColor: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: Colors.grey, width: 1),
              borderRadius: BorderRadius.circular(16),
            ),
            tooltip: "Add Source",
            onPressed: () {
              GoRouter.of(context).go("/files/add");
            },
            child: const Icon(Icons.add, color: Colors.grey),
          ),
          body: Column(
            children: [
              const SizedBox(height: 8),
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
              StreamBuilder<bool>(
                stream: _collectionService!.isLoading,
                builder: (context, snapshot) {
                  if (snapshot.data == true) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: flatList.length,
                  itemBuilder: (context, index) {
                    final item = flatList[index];

                    if (item is String) {
                      // Render Group Header
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                        child: Text(
                          item.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary.withOpacity(0.8),
                            letterSpacing: 1.0,
                          ),
                        ),
                      );
                    }

                    // Render Collection Tile
                    final col = item as Collection;
                    final isSelected = collection?.id == col.id;
                    final subTitle = _getSubtitle(col);
                    
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1.0),
                      child: ListTile(
                        dense: subTitle != null,
                        selected: isSelected,
                        selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.3),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        title: Text(
                          _getDisplayName(col),
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: subTitle != null 
                          ? Text(
                              subTitle,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.grey,
                                fontSize: 11,
                              ),
                            ) 
                          : null,
                        trailing: PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert),
                          onSelected: (String value) {
                            if (value == 'sync') {
                              ScannerManager.getInstance()
                                  .getScanner(col)
                                  ?.start(
                                    col,
                                    col.path,
                                    true,
                                    true,
                                  );
                            } else if (value == 'settings') {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Settings coming soon'),
                                ),
                              );
                            } else if (value == 'delete') {
                              _showDeleteConfirmationDialog(
                                context,
                                col,
                              );
                            }
                          },
                          itemBuilder:
                              (BuildContext context) => <PopupMenuEntry<String>>[
                                const PopupMenuItem<String>(
                                  value: 'sync',
                                  child: Text('Sync'),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'settings',
                                  enabled: false,
                                  child: Text('Settings'),
                                ),
                                const PopupMenuItem<String>(
                                  value: 'delete',
                                  child: Text('Delete'),
                                ),
                              ],
                        ),
                        onTap: () {
                          RxFilesPage.selectedCollection.add(col);
                          RxFilesPage.selectedPath.add(col.path);
                          GoRouter.of(context).go('/files');
                        },
                      ),
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
            'Are you sure you want to delete the collection "${collection.name}" and all of its metadata from this application? This action cannot be undone.\n\nNote: Original files on your disk will NOT be deleted.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                Navigator.of(context).pop();

                final db = DatabaseManager.instance.database;
                if (db != null) {
                  // Delete the collection and all related metadata (files, folders, etc.)
                  await CollectionRepository().deleteCollection(collection.id);

                  // Reload collections list
                  GetCollectionsService.instance.invoke(
                    GetCollectionsServiceCommand(null),
                  );

                  // If the deleted collection was the current one, go home
                  if (this.collection?.id == collection.id) {
                    GoRouter.of(context).go('/files');
                    // We might need to refresh the page state or selected collection here
                    // RxFilesPage.selectedCollection.add(null); // Would need to handle null in UI if allowed
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Collection "${collection.name}" deleted'),
                    ),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }
}
