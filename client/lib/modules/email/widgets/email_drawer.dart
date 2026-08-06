import 'dart:async';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer/email_folder_tile_widget.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer/email_folder_tree.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/services/get_email_folders_service.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer/accordion_header_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_drawer/collection_tile_widget.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:mydatastudio/widgets/accessible_tap.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

enum _EmailAccordionSection { gmail, yahoo, outlook, other }

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

  _EmailAccordionSection? _expandedSection = _EmailAccordionSection.gmail;

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
          // Auto-expand the section containing the selected account
          if (value != null) {
            _expandedSection = _sectionFor(value.scanner);
          }
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

  _EmailAccordionSection _sectionFor(String scanner) {
    switch (scanner) {
      case AppConstants.scannerEmailGmail:
        return _EmailAccordionSection.gmail;
      case AppConstants.scannerEmailYahoo:
        return _EmailAccordionSection.yahoo;
      case AppConstants.scannerEmailOutlook:
      case AppConstants.scannerEmailOutlookPst:
        return _EmailAccordionSection.outlook;
      default:
        return _EmailAccordionSection.other;
    }
  }

  String _getDisplayName(Collection c) {
    final name = c.name;
    // If name contains an email in parens, show just the email
    final match = RegExp(r'\(([^)]+)\)').firstMatch(name);
    if (match != null) {
      return match.group(1) ?? name;
    }
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final gmailAccounts =
        collections
            .where((c) => c.scanner == AppConstants.scannerEmailGmail)
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final yahooAccounts =
        collections
            .where((c) => c.scanner == AppConstants.scannerEmailYahoo)
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final outlookAccounts =
        collections
            .where(
              (c) =>
                  c.scanner == AppConstants.scannerEmailOutlook ||
                  c.scanner == AppConstants.scannerEmailOutlookPst,
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final otherAccounts =
        collections
            .where(
              (c) =>
                  c.scanner != AppConstants.scannerEmailGmail &&
                  c.scanner != AppConstants.scannerEmailYahoo &&
                  c.scanner != AppConstants.scannerEmailOutlook &&
                  c.scanner != AppConstants.scannerEmailOutlookPst,
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    return SizedBox.expand(
      child: Container(
        color: Colors.transparent,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: FloatingActionButton.small(
            tooltip: "Add Email Account",
            onPressed: () => GoRouter.of(context).go("/email/add"),
            backgroundColor: theme.colorScheme.surfaceContainerHigh,
            foregroundColor: theme.colorScheme.onSurface,
            shape: const CircleBorder(),
            child: const Icon(Icons.add, size: 20),
          ),
          floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
          body: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader("SOURCES"),
                      if (gmailAccounts.isNotEmpty) ...[
                        AccordionHeaderWidget(
                          title: 'Gmail',
                          icon: Icons.email_outlined,
                          isExpanded:
                              _expandedSection == _EmailAccordionSection.gmail,
                          onTap:
                              () => setState(() {
                                _expandedSection =
                                    _expandedSection ==
                                            _EmailAccordionSection.gmail
                                        ? null
                                        : _EmailAccordionSection.gmail;
                              }),
                        ),
                        if (_expandedSection == _EmailAccordionSection.gmail)
                          Padding(
                            padding: const EdgeInsets.only(left: 16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:
                                  gmailAccounts
                                      .map(
                                        (c) => _buildAccountSection(
                                          context,
                                          theme,
                                          c,
                                        ),
                                      )
                                      .toList(),
                            ),
                          ),
                      ],
                      if (yahooAccounts.isNotEmpty) ...[
                        AccordionHeaderWidget(
                          title: 'Yahoo',
                          icon: Icons.mail_outlined,
                          isExpanded:
                              _expandedSection == _EmailAccordionSection.yahoo,
                          onTap:
                              () => setState(() {
                                _expandedSection =
                                    _expandedSection ==
                                            _EmailAccordionSection.yahoo
                                        ? null
                                        : _EmailAccordionSection.yahoo;
                              }),
                        ),
                        if (_expandedSection == _EmailAccordionSection.yahoo)
                          Padding(
                            padding: const EdgeInsets.only(left: 16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:
                                  yahooAccounts
                                      .map(
                                        (c) => _buildAccountSection(
                                          context,
                                          theme,
                                          c,
                                        ),
                                      )
                                      .toList(),
                            ),
                          ),
                      ],
                      if (outlookAccounts.isNotEmpty) ...[
                        AccordionHeaderWidget(
                          title: 'Outlook',
                          icon: Icons.inbox_outlined,
                          isExpanded:
                              _expandedSection ==
                              _EmailAccordionSection.outlook,
                          onTap:
                              () => setState(() {
                                _expandedSection =
                                    _expandedSection ==
                                            _EmailAccordionSection.outlook
                                        ? null
                                        : _EmailAccordionSection.outlook;
                              }),
                        ),
                        if (_expandedSection == _EmailAccordionSection.outlook)
                          Padding(
                            padding: const EdgeInsets.only(left: 16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:
                                  outlookAccounts
                                      .map(
                                        (c) => _buildAccountSection(
                                          context,
                                          theme,
                                          c,
                                        ),
                                      )
                                      .toList(),
                            ),
                          ),
                      ],
                      if (otherAccounts.isNotEmpty) ...[
                        AccordionHeaderWidget(
                          title: 'Other',
                          icon: Icons.alternate_email,
                          isExpanded:
                              _expandedSection == _EmailAccordionSection.other,
                          onTap:
                              () => setState(() {
                                _expandedSection =
                                    _expandedSection ==
                                            _EmailAccordionSection.other
                                        ? null
                                        : _EmailAccordionSection.other;
                              }),
                        ),
                        if (_expandedSection == _EmailAccordionSection.other)
                          Padding(
                            padding: const EdgeInsets.only(left: 16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children:
                                  otherAccounts
                                      .map(
                                        (c) => _buildAccountSection(
                                          context,
                                          theme,
                                          c,
                                        ),
                                      )
                                      .toList(),
                            ),
                          ),
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
      padding: EdgeInsets.only(
        left: leftPadding,
        right: 16.0,
        top: 12,
        bottom: 12,
      ),
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

  Widget _buildAccountSection(
    BuildContext context,
    ThemeData theme,
    Collection col,
  ) {
    final isAccountSelected = collection?.id == col.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CollectionTileWidget(
          collection: col,
          isSelected: isAccountSelected,
          displayName: _getDisplayName(col),
          onTap: () {
            EmailPage.selectedCollection.add(col);
            EmailPage.selectedFolder.add(null);
            context.go('/email');
          },
          // A PST is an immutable, one-shot import — never re-synced. Hide Sync
          // for it; re-importing means delete the collection and re-add the file.
          showSync: col.scanner != AppConstants.scannerEmailOutlookPst,
          onSync: () => _syncAccount(context, col),
          onDelete: () => _showDeleteConfirmationDialog(context, col),
        ),
        if (isAccountSelected)
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: _EmailFolderList(
              collection: col,
              selectedFolderId: selectedFolderId,
              onFolderTap: (folderId) {
                EmailPage.selectedCollection.add(col);
                EmailPage.selectedFolder.add(folderId);
                context.go('/email');
              },
            ),
          ),
      ],
    );
  }

  Future<void> _syncAccount(BuildContext context, Collection col) async {
    // Live email providers (Gmail/Outlook/Yahoo) re-sync from the server. PST
    // archives are imported once and never re-synced, so the Sync action is
    // hidden for them (see CollectionTileWidget.showSync) and never reaches here.
    ScannerManager.getInstance().getScanner(col)?.start(col, null, true, true);
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
            'Are you sure you want to delete the account "${collection.name}" and all of its emails from this application?\n\nThis will NOT delete any emails from the actual server.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () async {
                Navigator.of(dialogContext).pop();

                EmailPage.isDeleting.add(true);

                try {
                  ScannerManager.getInstance().stopScanner(collection.id);

                  GetEmailFoldersService.instance.disposeCollection(
                    collection.id,
                  );

                  await CollectionRepository().deleteCollection(collection.id);

                  _collectionsService.invoke(
                    GetCollectionsServiceCommand("email"),
                  );
                  if (EmailPage.selectedCollection.value?.id == collection.id) {
                    EmailPage.selectedCollection.add(null);
                  }
                } finally {
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

class _EmailFolderList extends StatefulWidget {
  final Collection collection;
  final String? selectedFolderId;
  final Function(String?) onFolderTap;

  const _EmailFolderList({
    required this.collection,
    required this.selectedFolderId,
    required this.onFolderTap,
  });

  @override
  State<_EmailFolderList> createState() => _EmailFolderListState();
}

class _EmailFolderListState extends State<_EmailFolderList> {
  StreamSubscription? _folderSub;
  List<EmailFolder> folders = [];
  bool _showAllFolders = false;

  @override
  void initState() {
    super.initState();
    _folderSub = GetEmailFoldersService.instance.sink.listen((value) {
      if (mounted) {
        final myFolders =
            value.where((f) => f.collectionId == widget.collection.id).toList();
        if (myFolders.isNotEmpty) {
          setState(() {
            folders = myFolders;
          });
        }
      }
    });

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

    // A PST is a static archive, and its folder tree comes straight from the
    // file — so it routinely contains folders holding nothing at all (stock
    // Deleted Items/Outbox that were never used, containers whose mail lives in
    // subfolders). Hiding those keeps the sidebar to folders worth clicking.
    //
    // Scoped to PST on purpose: `messages_total` is NOT NULL and only Gmail
    // populates it, so every Outlook/Yahoo folder currently stores 0. Applying
    // this filter to live accounts would empty their sidebars.
    //
    // The second condition guards the same hazard for PSTs imported *before*
    // the scanner started writing counts: those rows are all 0 too, and there
    // is no schema migration to backfill them. If nothing in this collection
    // has a count, the counts are absent rather than genuinely zero — so show
    // everything, which is the pre-existing behaviour, instead of blanking the
    // sidebar of an archive that has mail in it. Re-importing the PST populates
    // the counts and the filter starts applying on its own.
    final hasFolderCounts = folders.any((f) => (f.messagesTotal ?? 0) > 0);
    final hideEmptyFolders =
        widget.collection.scanner == AppConstants.scannerEmailOutlookPst &&
        hasFolderCounts;
    bool isEmpty(EmailFolder f) =>
        hideEmptyFolders && (f.messagesTotal ?? 0) == 0;

    EmailFolder? inbox;
    EmailFolder? sent;
    EmailFolder? drafts;
    EmailFolder? trash;
    EmailFolder? spam;
    final List<EmailFolder> otherFolders = [];

    for (var f in folders) {
      if (isEmpty(f)) continue;
      final normalizedId = f.id.toUpperCase();
      final normalizedName = f.name.toUpperCase();

      if (normalizedId == 'INBOX' || normalizedName == 'INBOX') {
        inbox = f;
      } else if (normalizedId == 'SENT' || normalizedName == 'SENT') {
        sent = f;
      } else if (normalizedId == 'DRAFT' ||
          normalizedId == 'DRAFTS' ||
          normalizedName == 'DRAFT' ||
          normalizedName == 'DRAFTS') {
        drafts = f;
      } else if (normalizedId == 'TRASH' ||
          normalizedId == 'DELETED' ||
          normalizedName == 'TRASH' ||
          normalizedName == 'DELETED' ||
          normalizedName == 'DELETED ITEMS') {
        trash = f;
      } else if (normalizedId == 'SPAM' ||
          normalizedId == 'JUNK' ||
          normalizedName == 'SPAM' ||
          normalizedName == 'JUNK') {
        spam = f;
      } else {
        // Filter out internal Gmail system categories/labels that shouldn't show up as folders
        if (normalizedId == 'UNREAD' ||
            normalizedId == 'STARRED' ||
            normalizedId == 'IMPORTANT' ||
            normalizedId == 'CHAT' ||
            normalizedId.startsWith('CATEGORY_')) {
          continue;
        }
        otherFolders.add(f);
      }
    }

    otherFolders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    final nestedFolders = buildEmailFolderTree(otherFolders);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (inbox != null)
          EmailFolderTileWidget(
            folder: inbox,
            label: 'Inbox',
            icon: Icons.inbox,
            isSelected: widget.selectedFolderId == inbox.id,
            onTap: () => widget.onFolderTap(inbox!.id),
          ),
        if (sent != null)
          EmailFolderTileWidget(
            folder: sent,
            label: 'Sent',
            icon: Icons.send,
            isSelected: widget.selectedFolderId == sent.id,
            onTap: () => widget.onFolderTap(sent!.id),
          ),
        if (drafts != null)
          EmailFolderTileWidget(
            folder: drafts,
            label: 'Drafts',
            icon: Icons.drafts_outlined,
            isSelected: widget.selectedFolderId == drafts.id,
            onTap: () => widget.onFolderTap(drafts!.id),
          ),
        if (trash != null)
          EmailFolderTileWidget(
            folder: trash,
            label: 'Trash',
            icon: Icons.delete_outline,
            isSelected: widget.selectedFolderId == trash.id,
            onTap: () => widget.onFolderTap(trash!.id),
          ),
        if (spam != null)
          EmailFolderTileWidget(
            folder: spam,
            label: 'Spam',
            icon: Icons.report_outlined,
            isSelected: widget.selectedFolderId == spam.id,
            onTap: () => widget.onFolderTap(spam!.id),
          ),
        if (otherFolders.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 8.0),
            child: AccessibleTap(
              expanded: _showAllFolders,
              label: 'All Folders',
              onPressed:
                  () => setState(() => _showAllFolders = !_showAllFolders),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 40.0,
                  top: 8.0,
                  bottom: 8.0,
                  right: 8.0,
                ),
                child: Row(
                  children: [
                    Icon(
                      _showAllFolders
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'All Folders',
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_showAllFolders)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children:
                  nestedFolders
                      .map(
                        (entry) => EmailFolderTileWidget(
                          folder: entry.folder,
                          label: entry.folder.name,
                          indent: 72.0 + entry.depth * 12.0,
                          fontSize: 12.0,
                          isSelected:
                              widget.selectedFolderId == entry.folder.id,
                          onTap: () => widget.onFolderTap(entry.folder.id),
                        ),
                      )
                      .toList(),
            ),
        ],
      ],
    );
  }
}
