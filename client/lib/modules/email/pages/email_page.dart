import 'dart:async';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatastudio/modules/email/notifications/email_selection_changed_notification.dart';
import 'package:mydatastudio/modules/email/notifications/email_sort_changed_notification.dart';
import 'package:mydatastudio/modules/email/pages/new_email_page.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/email/services/get_email_folders_service.dart';
import 'package:mydatastudio/modules/email/services/get_emails_service.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatastudio/modules/email/widgets/email_details.dart';
import 'package:mydatastudio/modules/email/widgets/email_table.dart';
import 'package:mydatastudio/modules/email/widgets/scanning_placeholder_widget.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:moment_dart/moment_dart.dart';
import 'package:rxdart/rxdart.dart';

/// Whether an import progress update should make the email list re-query.
///
/// The import writes to the database from its own isolate and nothing notifies
/// the page, so without a refresh the list sits empty until the user happens to
/// click the collection in the sidebar. Refreshing on *every* update is the
/// other failure: it fires every fifty messages for the length of a
/// multi-gigabyte import.
///
/// Hence the conditions, in order of precedence:
///   * a finished import always refreshes — that is the authoritative one, and
///     it is what reveals the imported messages;
///   * an update for some other collection is ignored;
///   * otherwise, at most one refresh per [minInterval].
///
/// The list itself is not rendered during an import — the progress placeholder
/// stands in its place — so these mid-import refreshes exist to keep the
/// sidebar's folder tree filling in as folders are discovered. That is also
/// why there is no guard for an open message or a full page: both once
/// protected a list the user can no longer be looking at, while suppressing
/// the folder updates that are now the point.
///
/// Kept free of widget state so the policy can be exercised on its own.
bool shouldRefreshForImport({
  required PstImportProgress? progress,
  required String? currentCollectionId,
  required DateTime now,
  required DateTime? lastRefresh,
  Duration minInterval = const Duration(seconds: 2),
}) {
  if (progress == null) return false;
  if (progress.collectionId != currentCollectionId) return false;
  if (progress.done) return true;
  if (lastRefresh != null && now.difference(lastRefresh) < minInterval) {
    return false;
  }
  return true;
}

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
  StreamSubscription? _pstProgressSub;

  List<Collection> collections = [];
  Collection? collection;
  bool isScanning = false;
  String? selectedFolderName;
  int count = 0;
  List<Email> emails = [];
  String sortColumn = 'date';
  bool sortAsc = false;

  final ScrollController _scrollController = ScrollController();
  static const int _pageSize = 100;
  int _currentOffset = 0;
  bool _isLoadingMore = false;
  bool _hasMore = true;

  /// Bumped by every [_refreshEmails]; an in-flight page fetch carrying an
  /// older value has been superseded and must discard its rows.
  int _loadGeneration = 0;

  /// When the import last pushed new messages into the list, so a long import
  /// doesn't re-query on every progress tick.
  DateTime? _lastImportRefresh;
  Email? selectedEmail;
  PstImportProgress? pstProgress;
  final TextEditingController searchController = TextEditingController();
  bool _needsFolderAutoSelect = false;

  @override
  void initState() {
    _scrollController.addListener(_onScroll);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _collectionService = GetCollectionsService.instance;

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      final emailCollections = value.where((c) => c.type == 'email').toList();
      setState(() {
        collections = emailCollections;
      });
      if (emailCollections.isNotEmpty) {
        if (EmailPage.selectedCollection.value == null) {
          _needsFolderAutoSelect = true;
          EmailPage.selectedCollection.add(emailCollections.first);
        } else if (EmailPage.selectedFolder.value == null) {
          _needsFolderAutoSelect = true;
        }
      }
    });

    _selectedCollectionSub = EmailPage.selectedCollection.listen((value) {
      if (value != null && collection != value) {
        setState(() {
          collection = value;
          EmailPage.selectedFolder.add(null);
          selectedFolderName = null;
          selectedEmail = null;
          _needsFolderAutoSelect = true;
        });
        _refreshEmails();
        _listenToScannerStatus(value);
      }
    });

    _emailsSub = GetEmailsService.instance.sink.listen((_) {
      if (mounted) {
        _refreshEmails();
      }
    });

    _selectedFolderSub = EmailPage.selectedFolder.listen((value) {
      if (mounted) {
        // Picking a folder is a request to see that folder's messages, so the
        // open message has to close — the detail view covers the whole pane,
        // and leaving it up made clicking a folder in the drawer look dead.
        setState(() {
          selectedEmail = null;
          if (value == null) selectedFolderName = null;
        });
        _refreshEmails();
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
                  .firstOrNull ??
              folders.first;
          EmailPage.selectedFolder.add(inbox.id);
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
          }
        }
      }
    });

    // A PST import is started from the setup page and keeps running after it
    // navigates here, so this page is where it has to be reported.
    _pstProgressSub = OutlookPstScannerIsolate.importProgress.listen((value) {
      if (!mounted) return;
      setState(() => pstProgress = value);
      _refreshForImport(value);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectionService?.invoke(GetCollectionsServiceCommand("email"));
    });
    super.initState();
  }

  void _refreshEmails() {
    if (collection == null) return;

    // Invalidates any page request already in flight. Without this, a fetch
    // issued before the reset lands afterwards and appends its rows to the
    // freshly emptied list — duplicating messages, or showing the previous
    // folder's. Rare when a refresh only followed a click; routine now that an
    // import refreshes on its own while a scroll may be paging.
    _loadGeneration++;

    if (mounted) {
      setState(() {
        emails = [];
        _currentOffset = 0;
        _hasMore = true;
        _isLoadingMore = false;
      });
    }

    _loadMoreEmails();

    GetEmailFoldersService.instance.invoke(
      EmailFolderServiceCommand(collection!.id),
    );
  }

  /// Pulls in what the import has written so far, per
  /// [shouldRefreshForImport].
  void _refreshForImport(PstImportProgress? progress) {
    final now = DateTime.now();
    if (!shouldRefreshForImport(
      progress: progress,
      currentCollectionId: collection?.id,
      now: now,
      lastRefresh: _lastImportRefresh,
    )) {
      return;
    }

    // Cleared on the final refresh so the next import isn't throttled by the
    // last one's clock.
    _lastImportRefresh = (progress?.done ?? false) ? null : now;
    _refreshEmails();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

    if (currentScroll >= (maxScroll * 0.7) && !_isLoadingMore && _hasMore) {
      _loadMoreEmails();
    }
  }

  /// Index of the open message in the currently loaded page, or -1.
  ///
  /// Matched by id rather than identity: `_refreshEmails` rebuilds the list from
  /// the database, so the open message is a different instance afterwards.
  int get _selectedIndex {
    final email = selectedEmail;
    if (email == null) return -1;
    return emails.indexWhere((e) => e.id == email.id);
  }

  bool get _canShowPrevious => _selectedIndex > 0;

  /// True while there is a next message, counting ones not yet paged in.
  bool get _canShowNext {
    final index = _selectedIndex;
    if (index < 0) return false;
    return index < emails.length - 1 || _hasMore;
  }

  void _showPrevious() {
    final index = _selectedIndex;
    if (index <= 0) return;
    setState(() => selectedEmail = emails[index - 1]);
  }

  Future<void> _showNext() async {
    var index = _selectedIndex;
    if (index < 0) return;

    // Reading past the end of the loaded page is the common case for a large
    // folder — page the next batch in rather than dead-ending on message 100.
    if (index >= emails.length - 1) {
      if (!_hasMore) return;
      await _loadMoreEmails();
      if (!mounted) return;
      index = _selectedIndex;
      if (index < 0 || index >= emails.length - 1) return;
    }

    setState(() => selectedEmail = emails[index + 1]);
  }

  /// Left/right arrows step through messages while one is open.
  ///
  /// Registered globally rather than via a focused [Focus] widget because the
  /// message body is a platform WebView: once the user clicks into it, a
  /// focus-scoped handler stops seeing key events.
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (!mounted || selectedEmail == null) return false;

    // A global handler would otherwise eat the arrow keys someone is using to
    // move the caret in a search or chat field.
    if (FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _showPrevious();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _showNext();
      return true;
    }
    return false;
  }

  void _listenToScannerStatus(Collection? c) {
    _scannerSub?.cancel();
    _scannerSub = null;
    if (c == null) {
      if (mounted) setState(() => isScanning = false);
      return;
    }

    if (mounted) setState(() => isScanning = false);

    final mgr = ScannerManager.getInstance();
    mgr.getScannerAsync(c).then((scanner) {
      if (!mounted) return;
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

    final generation = _loadGeneration;

    // _currentOffset is the offset of the page about to be fetched, not the one
    // already loaded. It used to be the latter, and the first page of every
    // folder was therefore fetched at offset 0 + _pageSize — silently skipping
    // the first 100 emails. Any folder holding 100 or fewer looked completely
    // empty; only the two folders in the PST archive with more than 100 showed
    // anything at all, starting at their 101st message.
    final nextOffset = _currentOffset;
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

    if (!mounted) return;
    // A refresh landed while this page was being fetched, so these rows belong
    // to a list that no longer exists. Appending them would duplicate messages.
    if (generation != _loadGeneration) return;

    setState(() {
      // Advance by what actually came back, so a short page can't leave a gap.
      _currentOffset = nextOffset + nextPage.length;
      emails = [...emails, ...nextPage];
      count = emails.length;
      _hasMore = nextPage.length >= _pageSize;
      _isLoadingMore = false;
    });
  }

  @override
  void dispose() {
    _emailsSub?.cancel();
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    _selectedFolderSub?.cancel();
    _folderSub?.cancel();
    _scannerSub?.cancel();
    _pstProgressSub?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
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

    if (collection == null) {
      return Container();
    }

    final theme = Theme.of(context);
    final bool showDetail = selectedEmail != null;
    final importing = _activeImport;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (importing != null || isScanning || _isLoadingMore)
            LinearProgressIndicator(
              minHeight: 2,
              // Null value keeps the bar indeterminate — which is what an
              // archive whose size the parser couldn't read has to fall back
              // to, and what an ordinary folder scan has always used.
              value: importing?.fraction,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.3,
                  ),
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child:
                  showDetail
                      ? _buildDetailHeader(theme)
                      : _buildListHeader(theme),
            ),
          ),
          Expanded(
            child: showDetail ? _buildEmailDetailArea() : _buildEmailListArea(),
          ),
        ],
      ),
    );
  }

  /// The running PST import, but only when it is the collection on screen.
  ///
  /// Null once it finishes, so the progress bar disappears on its own.
  ///
  /// An import is reported in exactly two places: the bar along the top, and
  /// the placeholder that stands in for the empty list. A third indicator used
  /// to sit between them — a banner with its own spinner and counts — which
  /// meant one operation announced itself three times over.
  PstImportProgress? get _activeImport {
    final progress = pstProgress;
    if (progress == null || progress.done) return null;
    if (progress.collectionId != collection?.id) return null;
    return progress;
  }

  /// The line under the import spinner.
  ///
  /// Reads the archive's own totals rather than the loaded page, because the
  /// list is not on screen during an import. The parser announces its message
  /// total before it emits anything else, but a large archive on a network
  /// volume can spend ten or twenty seconds counting first — hence the
  /// fallback, which is all there is to say until then.
  String _importDetail(PstImportProgress progress) {
    if (progress.totalMessages <= 0) {
      return 'Reading the archive. Large files can take several minutes.';
    }
    return 'Read ${progress.examined} of ${progress.totalMessages} messages';
  }

  Widget _buildListHeader(ThemeData theme) {
    final hasSelected = emails.any((e) => e.isSelected == true);
    // A PST is an immutable archive imported once — there is nothing to refresh,
    // so the folder-refresh control (and its divider) are hidden for PST
    // collections. Re-importing means deleting the collection and re-adding the
    // file. See OutlookPstScannerIsolate.
    final isPst = collection?.scanner == AppConstants.scannerEmailOutlookPst;
    return Row(
      children: [
        Expanded(child: _getBreadcrumb(theme)),
        if (!isPst) ...[
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: theme.colorScheme.onSurfaceVariant,
              size: 20,
            ),
            tooltip: 'Refresh Current Folder',
            onPressed: () {
              if (collection != null && EmailPage.selectedFolder.value != null) {
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
          const SizedBox(width: 8),
          Container(
            height: 20,
            width: 1,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(width: 8),
        ],
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          color: theme.colorScheme.error,
          disabledColor: theme.colorScheme.error.withValues(alpha: 0.3),
          tooltip: 'Delete Selected Messages',
          onPressed:
              hasSelected ? () => _showBulkDeleteConfirmation(context) : null,
        ),
      ],
    );
  }

  Widget _buildDetailHeader(ThemeData theme) {
    final email = selectedEmail!;
    final from = email.from.split('<')[0].trim();

    return Row(
      children: [
        IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
          tooltip: 'Back',
          onPressed: () => setState(() => selectedEmail = null),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                from.isNotEmpty ? from : email.from,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                email.subject ?? '(no subject)',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Text(
          _formatEmailDate(email.date),
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          height: 20,
          width: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 16),
          color: theme.colorScheme.onSurfaceVariant,
          tooltip: 'Previous Message (←)',
          onPressed: _canShowPrevious ? _showPrevious : null,
        ),
        IconButton(
          icon: const Icon(Icons.arrow_forward_ios, size: 16),
          color: theme.colorScheme.onSurfaceVariant,
          tooltip: 'Next Message (→)',
          onPressed: _canShowNext ? _showNext : null,
        ),
        const SizedBox(width: 8),
        Container(
          height: 20,
          width: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 20),
          color: theme.colorScheme.error,
          tooltip: 'Delete Message',
          onPressed: () {
            setState(() => selectedEmail = null);
            _deleteSelectedEmails([email]);
          },
        ),
      ],
    );
  }

  Widget _buildEmailListArea() {
    final importing = _activeImport;
    if (importing != null) {
      // Held for the whole import, not just while the list is empty. Gating
      // this on `emails.isEmpty` meant the auto-refresh replaced it with the
      // table seconds after the first messages landed — so on a three-minute
      // import the count was legible for about two seconds and the rest of the
      // run had no progress reading at all. The list is revealed by the final
      // refresh when the import finishes.
      return ScanningPlaceholderWidget(
        collectionName: importing.collectionName,
        progress: importing.fraction,
        message: 'Importing ${importing.collectionName}…',
        detail: _importDetail(importing),
      );
    }

    if (emails.isEmpty && (isScanning || _isLoadingMore)) {
      return isScanning
          ? _buildScanningPlaceholder()
          : const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
            setState(() => selectedEmail = n.email);
            return true;
          }
          if (n is EmailSelectionChangedNotification) {
            // Checkbox state lives on the Email objects the table mutates in
            // place; this rebuild is what re-evaluates the delete button.
            setState(() {});
            return true;
          }
          return false;
        },
        child: EmailTable(
          emails: emails,
          scrollController: _scrollController,
          sortColumn: sortColumn,
          sortAsc: sortAsc,
          onLoadMore: _loadMoreEmails,
        ),
      ),
    );
  }

  Widget _buildEmailDetailArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(
              context,
            ).colorScheme.outlineVariant.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: EmailDetails(email: selectedEmail!),
        ),
      ),
    );
  }

  BreadCrumb _getBreadcrumb(ThemeData theme) {
    final isRootActive = selectedFolderName == null;
    return BreadCrumb(
      items: <BreadCrumbItem>[
        BreadCrumbItem(
          content: Icon(
            Icons.home_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
          onTap: () {},
        ),
        if (collection != null)
          BreadCrumbItem(
            content: Text(
              collection!.name,
              style: TextStyle(
                color:
                    isRootActive
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                fontWeight: isRootActive ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
            ),
            onTap: () => EmailPage.selectedFolder.add(null),
          ),
        if (selectedFolderName != null)
          BreadCrumbItem(
            content: Text(
              selectedFolderName!,
              style: TextStyle(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            onTap: () {},
          ),
      ],
      divider: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
        size: 16,
      ),
      overflow: const WrapOverflow(
        keepLastDivider: false,
        direction: Axis.horizontal,
      ),
    );
  }

  String _formatEmailDate(DateTime date) {
    final moment = Moment(date.toLocal());
    final isToday =
        moment.format('yyyy-MM-dd') == Moment.now().format('yyyy-MM-dd');
    return isToday ? moment.format('h:mm A') : moment.format('M/DD/YYYY');
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

      if (collection != null) {
        final scanner = ScannerManager.getInstance().getScanner(collection!);
        if (scanner != null) {
          final groupedByFolder = <String, List<int>>{};

          for (var item in items) {
            if (item.uid != null) {
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

      await EmailRepository(
        DatabaseManager.instance.database!,
      ).deleteEmails(ids);

      _refreshEmails();
      if (mounted) {
        setState(() {
          selectedEmail = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${items.length} message${items.length == 1 ? '' : 's'} deleted',
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
    return ScanningPlaceholderWidget(collectionName: collection?.name);
  }
}
