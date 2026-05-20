import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/accordion_header_widget.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/collection_tile_widget.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum AccordionSection { localFiles, cloudDrives, email, social }

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

    // Deferred to post-frame so FileDrawer renders its skeleton immediately
    // rather than triggering a BehaviorSubject replay cascade in initState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectionService!.invoke(GetCollectionsServiceCommand(null));
    });
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

  AccordionSection? _expandedSection = AccordionSection.localFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final List<Collection> filtered =
        collections
            .where(
              (element) =>
                  element.type == 'file' ||
                  element.type == 'email' ||
                  element.type == 'social' ||
                  element.type == 'album',
            )
            .toList();

    // Grouping logic for the requested hierarchy
    final List<Collection> localFiles =
        filtered
            .where((c) => c.scanner == AppConstants.scannerFileLocal)
            .toList();
    final List<Collection> gdriveFiles =
        filtered
            .where((c) => c.scanner == AppConstants.scannerFileGDrive)
            .toList();
    final List<Collection> dropboxFiles =
        filtered
            .where((c) => c.scanner == AppConstants.scannerFileDropbox)
            .toList();
    final List<Collection> onedriveFiles =
        filtered
            .where((c) => c.scanner == AppConstants.scannerFileOneDrive)
            .toList();



    return SizedBox.expand(
      child: Container(
        color: Colors.transparent,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.small(
            tooltip: "Add Source",
            onPressed: () => GoRouter.of(context).go("/files/add"),
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            foregroundColor: theme.colorScheme.onSurface,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, size: 20),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: Column(
            children: [
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
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader("SOURCES"),
                      _buildAccordionHeader(
                        theme,
                        AccordionSection.localFiles,
                        "Local Files",
                        Icons.folder_outlined,
                      ),
                      if (_expandedSection == AccordionSection.localFiles)
                        Padding(
                          padding: const EdgeInsets.only(left: 16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: localFiles.map(
                              (c) => _buildCollectionTile(context, theme, c),
                            ).toList(),
                          ),
                        ),
                      _buildAccordionHeader(
                        theme,
                        AccordionSection.cloudDrives,
                        "Cloud Drives",
                        Icons.cloud_outlined,
                      ),
                      if (_expandedSection == AccordionSection.cloudDrives) ...[
                        _buildSectionHeader("GOOGLE DRIVE", leftPadding: 32.0),
                        Padding(
                          padding: const EdgeInsets.only(left: 24.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: gdriveFiles.map(
                              (c) => _buildCollectionTile(context, theme, c),
                            ).toList(),
                          ),
                        ),
                        _buildSectionHeader("DROPBOX (FUTURE)", leftPadding: 32.0),
                        Padding(
                          padding: const EdgeInsets.only(left: 24.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: dropboxFiles.map(
                              (c) => _buildCollectionTile(context, theme, c),
                            ).toList(),
                          ),
                        ),
                        if (onedriveFiles.isNotEmpty) ...[
                          _buildSectionHeader("ONEDRIVE", leftPadding: 32.0),
                          Padding(
                            padding: const EdgeInsets.only(left: 24.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: onedriveFiles.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ).toList(),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, {double leftPadding = 16.0}) {
    return Padding(
      padding: EdgeInsets.only(left: leftPadding, right: 16.0, top: 12, bottom: 12),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 11,
            color: Colors.grey,
            letterSpacing: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildAccordionHeader(
    ThemeData theme,
    AccordionSection section,
    String title,
    IconData icon,
  ) {
    return AccordionHeaderWidget(
      title: title,
      icon: icon,
      isExpanded: _expandedSection == section,
      onTap: () => setState(() {
        if (_expandedSection == section) {
          _expandedSection = null;
        } else {
          _expandedSection = section;
        }
      }),
    );
  }



  Widget _buildCollectionTile(
    BuildContext context,
    ThemeData theme,
    Collection col,
  ) {
    return CollectionTileWidget(
      collection: col,
      isSelected: collection?.id == col.id,
      displayName: _getDisplayName(col),
      subtitle: _getSubtitle(col),
      onTap: () {
        RxFilesPage.selectedCollection.add(col);
        RxFilesPage.selectedPath.add(col.path);
        GoRouter.of(context).go('/files');
      },
      onSync: () => ScannerManager.getInstance()
          .getScanner(col)
          ?.start(col, col.path, true, true),
      onDelete: () => _showDeleteConfirmationDialog(context, col),
    );
  }

  void _showDeleteConfirmationDialog(
    BuildContext context,
    Collection collection,
  ) {
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Confirm Delete'),
          content: Text(
            'Are you sure you want to delete the collection "${collection.name}" and all of its metadata from this application? This action cannot be undone.\n\nNote: Original files on your disk will NOT be deleted.',
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
                final db = DatabaseManager.instance.database;
                if (db != null) {
                  // Capture context-dependent objects before async gap and pop
                  final router = GoRouter.of(context);
                  final messenger = ScaffoldMessenger.of(context);

                  Navigator.of(dialogContext).pop();

                  // Delete the collection and all related metadata (files, folders, etc.)
                  await CollectionRepository(DatabaseManager.instance.database!).deleteCollection(collection.id);

                  // Reload collections list
                  GetCollectionsService.instance.invoke(
                    GetCollectionsServiceCommand(null),
                  );

                  // If the deleted collection was the current one, go home
                  if (this.collection?.id == collection.id) {
                    router.go('/files');
                  }

                  messenger.showSnackBar(
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
