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
    final isExpanded = _expandedSection == section;
    return GestureDetector(
      onTap: () => setState(() => _expandedSection = section),
      child: Container(
        margin: const EdgeInsets.symmetric(
          vertical: 0.5,
        ), // Tiny separator space
        decoration: BoxDecoration(
          color:
              isExpanded
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.zero,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color:
                  isExpanded
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: isExpanded ? FontWeight.bold : FontWeight.w500,
                  fontSize: 14,
                  color:
                      isExpanded
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurface,
                ),
              ),
            ),
            Icon(
              isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              size: 18,
              color:
                  isExpanded
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubHeader(ThemeData theme, String title) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      ),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
          fontSize: 9,
        ),
      ),
    );
  }

  Widget _buildCollectionTile(
    BuildContext context,
    ThemeData theme,
    Collection col,
  ) {
    final isSelected = collection?.id == col.id;
    final subTitle = _getSubtitle(col);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 1.0),
      child: ListTile(
        dense: true,
        selected: isSelected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.3,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          _getDisplayName(col),
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle:
            subTitle != null
                ? Text(
                  subTitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.grey,
                    fontSize: 11,
                  ),
                )
                : null,
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (String value) {
            if (value == 'sync') {
              ScannerManager.getInstance()
                  .getScanner(col)
                  ?.start(col, col.path, true, true);
            } else if (value == 'delete') {
              _showDeleteConfirmationDialog(context, col);
            }
          },
          itemBuilder:
              (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(value: 'sync', child: Text('Sync')),
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
                  // Capture context-dependent objects before async gap
                  final router = GoRouter.of(context);
                  final messenger = ScaffoldMessenger.of(context);

                  // Delete the collection and all related metadata (files, folders, etc.)
                  await CollectionRepository().deleteCollection(collection.id);

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
