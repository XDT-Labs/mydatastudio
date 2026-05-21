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
import 'package:mydatatools/modules/email/widgets/scanning_placeholder_widget.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:moment_dart/moment_dart.dart';
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

  final ScrollController _scrollController = ScrollController();
  static const int _pageSize = 100;
  int _currentOffset = 0;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  Email? selectedEmail;
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
        _needsFolderAutoSelect = true;
        EmailPage.selectedCollection.add(emailCollections.first);
      }
    });

    _selectedCollectionSub = EmailPage.selectedCollection.listen((value) {
      if (value != null && collection != value) {
        setState(() {
          collection = value;
          EmailPage.selectedFolder.add(null);
          selectedFolderName = null;
          selectedEmail = null;
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

    GetEmailFoldersService.instance.invoke(
      EmailFolderServiceCommand(collection!.id),
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;

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

    if (collection == null) {
      return Container();
    }

    final theme = Theme.of(context);
    final bool showDetail = selectedEmail != null;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isScanning || _isLoadingMore)
            LinearProgressIndicator(
              minHeight: 2,
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
              child: showDetail
                  ? _buildDetailHeader(theme)
                  : _buildListHeader(theme),
            ),
          ),
          Expanded(
            child: showDetail
                ? _buildEmailDetailArea()
                : _buildEmailListArea(),
          ),
        ],
      ),
    );
  }

  Widget _buildListHeader(ThemeData theme) {
    final hasSelected = emails.any((e) => e.isSelected == true);
    return Row(
      children: [
        Expanded(child: _getBreadcrumb(theme)),
        IconButton(
          icon: Icon(
            Icons.refresh,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
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
          disabledColor: theme.colorScheme.error.withValues(alpha: 0.3),
          tooltip: 'Delete Selected Messages',
          onPressed: hasSelected
              ? () => _showBulkDeleteConfirmation(context)
              : null,
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
    if (emails.isEmpty && (isScanning || _isLoadingMore)) {
      return isScanning
          ? _buildScanningPlaceholder()
          : const Center(child: CircularProgressIndicator());
    }

    return NotificationListener<Notification>(
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
        return false;
      },
      child: EmailTable(
        emails: emails,
        scrollController: _scrollController,
        sortColumn: sortColumn,
        sortAsc: sortAsc,
        onLoadMore: _loadMoreEmails,
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
                color: isRootActive
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
      builder: (context) => AlertDialog(
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

      await EmailRepository(DatabaseManager.instance.database!).deleteEmails(ids);

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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting emails: $e')),
        );
      }
    }
  }

  Widget _buildScanningPlaceholder() {
    return ScanningPlaceholderWidget(collectionName: collection?.name);
  }
}
