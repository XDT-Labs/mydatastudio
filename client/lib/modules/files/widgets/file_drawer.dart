import 'dart:async';

import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/accordion_header_widget.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/collection_tile_widget.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/section_sub_header_widget.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum AccordionSection { files, email, social }

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

  AccordionSection _expandedSection = AccordionSection.files;

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

    final List<Collection> gmailEmails =
        filtered
            .where((c) => c.scanner == AppConstants.scannerEmailGmail)
            .toList();
    final List<Collection> yahooEmails =
        filtered
            .where((c) => c.scanner == AppConstants.scannerEmailYahoo)
            .toList();
    final List<Collection> pstEmails =
        filtered
            .where((c) => c.scanner == AppConstants.scannerEmailOutlookPst)
            .toList();

    final List<Collection> facebookSocial =
        filtered
            .where((c) => c.scanner.toLowerCase().contains('facebook'))
            .toList();
    final List<Collection> twitterSocial =
        filtered
            .where((c) => c.scanner.toLowerCase().contains('twitter'))
            .toList();
    final List<Collection> tiktokSocial =
        filtered
            .where((c) => c.scanner.toLowerCase().contains('tiktok'))
            .toList();

    return SizedBox.expand(
      child: Container(
        color: Colors.white,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton(
            tooltip: "Add Source",
            onPressed: () => GoRouter.of(context).go("/files/add"),
            child: const Icon(Icons.add),
          ),
          body: Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 12),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    "SOURCES",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                      color: Colors.grey,
                      letterSpacing: 1.5,
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
              const SizedBox(height: 4),
              Expanded(
                child: Column(
                  children: [
                    // --- FILES ---
                    _buildAccordionHeader(
                      theme,
                      AccordionSection.files,
                      "Files",
                      Icons.folder_outlined,
                    ),
                    if (_expandedSection == AccordionSection.files)
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSubHeader(theme, "Local Sources"),
                              ...localFiles.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "Google Drive"),
                              ...gdriveFiles.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "DropBox (future)"),
                              ...dropboxFiles.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              if (onedriveFiles.isNotEmpty) ...[
                                _buildSubHeader(theme, "OneDrive"),
                                ...onedriveFiles.map(
                                  (c) =>
                                      _buildCollectionTile(context, theme, c),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                    // --- EMAIL ATTACHMENTS ---
                    _buildAccordionHeader(
                      theme,
                      AccordionSection.email,
                      "Email Attachments",
                      Icons.email_outlined,
                    ),
                    if (_expandedSection == AccordionSection.email)
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSubHeader(theme, "GMail"),
                              ...gmailEmails.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "Yahoo Mail"),
                              ...yahooEmails.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "PST Backups"),
                              ...pstEmails.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                            ],
                          ),
                        ),
                      ),

                    // --- SOCIAL MEDIA ---
                    _buildAccordionHeader(
                      theme,
                      AccordionSection.social,
                      "Social Media",
                      Icons.share_outlined,
                    ),
                    if (_expandedSection == AccordionSection.social)
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildSubHeader(theme, "Facebook"),
                              ...facebookSocial.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "Twitter"),
                              ...twitterSocial.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                              _buildSubHeader(theme, "Tiktok"),
                              ...tiktokSocial.map(
                                (c) => _buildCollectionTile(context, theme, c),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
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
      onTap: () => setState(() => _expandedSection = section),
    );
  }

  Widget _buildSubHeader(ThemeData theme, String title) {
    return SectionSubHeaderWidget(title: title);
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
