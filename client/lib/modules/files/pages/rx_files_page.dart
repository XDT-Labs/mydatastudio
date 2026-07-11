import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/image_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pdf_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/stl_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/video_file_preview.dart';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/file_asset.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/modules/files/notifications/file_notification.dart';
import 'package:mydatastudio/modules/files/notifications/path_changed_notification.dart';
import 'package:mydatastudio/modules/files/notifications/sort_changed_notification.dart';
import 'package:mydatastudio/modules/files/pages/new_file_collection_page.dart';
import 'package:mydatastudio/modules/files/services/get_files_and_folders_service.dart';
import 'package:mydatastudio/modules/files/widgets/file_table.dart';
import 'package:mydatastudio/modules/files/widgets/file_details_drawer.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/app_constants.dart';

import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' as io;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:rxdart/rxdart.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';

class RxFilesPage extends StatefulWidget {
  const RxFilesPage({super.key});

  static PublishSubject selectedCollection = PublishSubject();
  static PublishSubject selectedPath = PublishSubject();
  static BehaviorSubject<String> sortColumn = BehaviorSubject.seeded("name");
  static BehaviorSubject<bool> sortDirection = BehaviorSubject.seeded(true);

  //String sortColumn, bool direction

  @override
  State<RxFilesPage> createState() => _RxFilesPage();
}

/// A single entry in the folder navigation trail.
class _BreadcrumbEntry {
  final String name;
  final String path;
  const _BreadcrumbEntry({required this.name, required this.path});
}

class _RxFilesPage extends State<RxFilesPage> {
  AppLogger logger = AppLogger(null);
  GetFileAndFoldersService? _filesAndFoldersService;
  GetCollectionsService? _collectionService;
  StreamSubscription<List<FileAsset>>? _fileServiceSub;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  StreamSubscription? _selectedCollectionSub;

  List<FileAsset> filesAndFolders = [];
  List<Collection> collections = [];
  Collection? collection;
  String? path;

  // ── Pagination ──────────────────────────────────────────────
  int _fileOffset = 0;
  bool _hasMoreFiles = true;
  bool _isLoadingMore = false;
  bool _isServiceLoading = false;
  bool isScanning = false;
  StreamSubscription? _scannerSub;
  StreamSubscription? _serviceLoadingSub;
  final ScrollController _scrollController = ScrollController();

  /// Navigation trail — empty means we are at the collection root.
  List<_BreadcrumbEntry> _breadcrumbTrail = [];
  String sortColumn = "name";
  bool sortAsc = true;
  List<FileAsset> selectedItems = [];
  FileAsset? selectedAsset;
  FileAsset? _lastSelectedAsset;
  bool _showLightbox = false;

  @override
  void initState() {
    _collectionService = GetCollectionsService.instance;
    _attachScrollListener();

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      setState(() {
        collections = value;
      });
      if (value.isNotEmpty) {
        // Find first local file collection to select by default, or fallback to first collection
        final defaultCollection = value.firstWhere(
          (c) => c.type == 'file' && c.scanner == AppConstants.scannerFileLocal,
          orElse: () => value.first,
        );
        RxFilesPage.selectedCollection.add(defaultCollection);
      }
    });

    _selectedCollectionSub = RxFilesPage.selectedCollection.listen((value) {
      if (value != null && collection != value) {
        //create new sub for objects in this collection
        _filesAndFoldersService = GetFileAndFoldersService.instance;
        //close old subscription
        if (_fileServiceSub != null) _fileServiceSub?.cancel();
        //listen for changes while visible
        _fileServiceSub = _filesAndFoldersService!.sink.listen((value) {
          setState(() {
            filesAndFolders = _mergeAndSortRowData(value, sortColumn, sortAsc);
          });
        });

        _listenToScannerStatus(value);
        _serviceLoadingSub?.cancel();
        _serviceLoadingSub = _filesAndFoldersService!.isLoading.listen((
          loading,
        ) {
          if (mounted) {
            setState(() {
              _isServiceLoading = loading;
            });
          }
        });

        // Reset pagination on collection change, then load first page.
        _fileOffset = 0;
        _hasMoreFiles = true;
        _filesAndFoldersService!.invoke(
          // '' = relative root path (stored as empty string in DB)
          GetFileAndFoldersServiceCommand(value, ''),
        );
        _triggerShallowScan(value, '');
      }
      setState(() {
        collection = value;
        path = ''; // relative root
        _breadcrumbTrail = []; // reset trail on collection change
        selectedItems = []; // reset selection on collection change
        selectedAsset = null; // close details drawer on collection change
        _showLightbox = false;
      });
    });

    // Deferred to post-frame to prevent the BehaviorSubject sink from
    // replaying its last value synchronously inside initState(), which would
    // cascade setState() calls before the first frame renders.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _collectionService!.invoke(GetCollectionsServiceCommand(null));
    });
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _fileServiceSub?.cancel();
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    _scannerSub?.cancel();
    _serviceLoadingSub?.cancel();
    super.dispose();
  }

  void _listenToScannerStatus(Collection? c) {
    _scannerSub?.cancel();
    _scannerSub = null;
    if (c == null) {
      if (mounted) setState(() => isScanning = false);
      return;
    }

    if (mounted) setState(() => isScanning = false);

    bool wasScanning = false;
    final mgr = ScannerManager.getInstance();
    mgr.getScannerAsync(c).then((scanner) {
      if (!mounted) return;
      if (collection?.id != c.id) return;

      _scannerSub = scanner.isScanning.listen((scanning) {
        if (mounted) {
          setState(() {
            isScanning = scanning;
          });
          if (wasScanning && !scanning) {
            // Scanner finished, trigger a silent refresh to show newly found files
            if (collection != null) {
              _filesAndFoldersService?.invoke(
                GetFileAndFoldersServiceCommand(
                  collection!,
                  path ?? '',
                  refreshOnly: true,
                ),
              );
            }
          }
          wasScanning = scanning;
        }
      });
    });
  }

  void _triggerShallowScan(Collection col, String targetPath) {
    if (col.type != 'file') {
      return;
    }
    final absPath = FilePathResolver.absoluteFromPath(targetPath, col);
    ScannerManager.getInstance()
        .getScannerAsync(col)
        .then((scanner) {
          if (scanner.isScanning.value && col.scanner != AppConstants.scannerFileGDrive) {
            return;
          }
          scanner.start(col, absPath, false, true).then((_) {
            if (mounted && collection?.id == col.id && path == targetPath) {
              _filesAndFoldersService?.invoke(
                GetFileAndFoldersServiceCommand(
                  col,
                  targetPath,
                  refreshOnly: true,
                ),
              );
            }
          });
        })
        .catchError((e) {
          logger.e("Error triggering shallow scan: $e");
        });
  }

  /// Loads the next page of files for the current collection and path.
  void _loadMoreFiles() {
    if (_isLoadingMore || !_hasMoreFiles) return;
    final col = collection;
    final currentPath = path;
    if (col == null || currentPath == null) return;
    _isLoadingMore = true;
    _fileOffset += kFilesPageSize;
    _filesAndFoldersService!
        .invoke(
          GetFileAndFoldersServiceCommand(
            col,
            currentPath,
            offset: _fileOffset,
          ),
        )
        .then((results) {
          if (!mounted) return;
          setState(() {
            _isLoadingMore = false;
            if (results.length < kFilesPageSize) _hasMoreFiles = false;
          });
        });
  }

  /// Wires the scroll controller to trigger load-more at 80% scroll depth.
  void _attachScrollListener() {
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.pixels >= pos.maxScrollExtent * 0.8) {
        _loadMoreFiles();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (selectedAsset == null) {
      _showLightbox = false;
    }
    final theme = Theme.of(context);
    print(
      'RxFilesPage.build: collections.length = ${collections.length}, collection = $collection',
    );
    if (collections.isEmpty) {
      return const NewFileCollectionPage();
    }

    if (collection == null) {
      return Container();
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.space) {
              if (selectedAsset != null && !_isTextInputFocused()) {
                setState(() {
                  _showLightbox = !_showLightbox;
                });
                return KeyEventResult.handled;
              }
            } else if (event.logicalKey == LogicalKeyboardKey.escape) {
              if (_showLightbox) {
                setState(() {
                  _showLightbox = false;
                });
                return KeyEventResult.handled;
              } else if (selectedAsset != null) {
                setState(() {
                  selectedAsset = null;
                });
                return KeyEventResult.handled;
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            // ─── Main Content (Column: header bar + body row) ──
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isLoadingMore || _isServiceLoading || isScanning)
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
                    child: Row(
                      children: [
                        Expanded(
                          child: getBreadcrumb(
                            theme,
                            collection!,
                            path ?? collection!.path,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.add_box_outlined,
                            color: theme.colorScheme.onSurfaceVariant,
                            size: 20,
                          ),
                          tooltip: 'Upload file',
                          onPressed: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'todo: add file to current folder',
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(
                            Icons.refresh,
                            color: theme.colorScheme.onSurfaceVariant,
                            size: 20,
                          ),
                          tooltip: 'Refresh',
                          onPressed: () async {
                            if (collection != null) {
                              logger.s("Refreshing folder $path");
                              final absPath = FilePathResolver.absoluteFromPath(
                                path ?? '',
                                collection!,
                              );
                              final mgr = ScannerManager.getInstance();
                              final scanner = await mgr.getScannerAsync(
                                collection!,
                              );
                              await scanner.start(
                                collection!,
                                absPath,
                                false,
                                true,
                              );
                              _filesAndFoldersService!.invoke(
                                GetFileAndFoldersServiceCommand(
                                  collection!,
                                  path ?? '',
                                ),
                              );
                            }
                          },
                        ),
                        const SizedBox(width: 8),
                        Container(
                          height: 20,
                          width: 1,
                          color: theme.colorScheme.outlineVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.download_outlined, size: 20),
                          color: theme.colorScheme.onSurfaceVariant,
                          disabledColor: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.3),
                          tooltip: 'Download File(s)',
                          onPressed:
                              selectedItems.isEmpty
                                  ? null
                                  : () => _downloadSelectedFiles(context),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          color: theme.colorScheme.error,
                          disabledColor: theme.colorScheme.error.withValues(
                            alpha: 0.3,
                          ),
                          tooltip: 'Delete File(s)',
                          onPressed:
                              selectedItems.isEmpty
                                  ? null
                                  : () => _showBulkDeleteConfirmationDialog(
                                    context,
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
                // ─── Body Row: table + optional details panel ──
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // File table fills all remaining horizontal space
                        Expanded(child: _buildFileTableArea()),
                        // Details panel animates in alongside the table
                        _buildDetailsPanel(theme),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            // ─── Lightbox fullscreen overlay (on top of everything) ──
            _buildLightboxOverlay(theme),
          ],
        ),
      ),
    );
  }

  /// Builds the file table area with loading/scanning/empty states.
  Widget _buildFileTableArea() {
    if (filesAndFolders.isEmpty && (_isLoadingMore || _isServiceLoading)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (filesAndFolders.isEmpty && isScanning) {
      return _buildScanningPlaceholder();
    }
    return NotificationListener<FiledNotification>(
      onNotification: (FiledNotification n) {
        io.stderr.writeln(
          "DEBUG: Received notification of type: ${n.runtimeType}",
        );
        if (n is PathChangedNotification) {
          io.stderr.writeln(
            "DEBUG: n.asset.path = ${n.asset.path}, current path = $path",
          );
          if (n.asset.path != path) {
            setState(() {
              path = n.asset.path;
              _breadcrumbTrail = [
                ..._breadcrumbTrail,
                _BreadcrumbEntry(name: n.asset.name, path: n.asset.path),
              ];
              selectedItems = [];
              selectedAsset = null;
              _showLightbox = false;
            });
            _fileOffset = 0;
            _hasMoreFiles = true;
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection!, n.asset.path),
            );
            _triggerShallowScan(collection!, n.asset.path);
            return true;
          }
        }
        if (n is SortChangedNotification) {
          sortColumn = n.sortColumn;
          sortAsc = n.sortAsc;
          setState(() {
            filesAndFolders = _mergeAndSortRowData(
              filesAndFolders,
              sortColumn,
              sortAsc,
            );
          });
          return true;
        }
        if (n is FileDeletedNotification) {
          _filesAndFoldersService!.invoke(
            GetFileAndFoldersServiceCommand(
              collection!,
              path ?? '',
              refreshOnly: true,
            ),
          );
          return true;
        }
        if (n is SelectionChangedNotification) {
          setState(() {
            selectedItems = n.selectedItems;
            if (selectedItems.length > 1) {
              selectedAsset = null;
            }
          });
          return true;
        }
        if (n is FileSelectedNotification) {
          setState(() {
            selectedAsset = n.asset;
            _lastSelectedAsset = n.asset;
            _showLightbox = false;
          });
          return true;
        }
        return false;
      },
      child: FileTable(
        data: filesAndFolders,
        collection: collection,
        scrollController: _scrollController,
      ),
    );
  }

  /// Builds the inline file-details card that sits to the right of the table.
  /// Animates in/out smoothly without overlaying the table.
  Widget _buildDetailsPanel(ThemeData theme) {
    final asset = selectedAsset ?? _lastSelectedAsset;
    final isVisible = selectedAsset != null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topRight,
      child:
          isVisible
              ? Padding(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 0,
                  top: 0,
                  bottom: 0,
                ),
                child: SizedBox(
                  width: 300,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.2,
                        ),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                          spreadRadius: 0,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: FileDetailsDrawer(
                      asset: asset!,
                      collection: collection!,
                      width: 300,
                      onClose:
                          () => setState(() {
                            selectedAsset = null;
                            _showLightbox = false;
                          }),
                      onNavigateToFile: (file) async {
                        // Resolve the target collection — may differ from the
                        // current one since findSimilarImages searches all
                        // collections.
                        var targetCollection = collection!;
                        if (file.collectionId != collection!.id) {
                          final found = await DatabaseManager.instance.repository
                              ?.getCollection(file.collectionId);
                          if (!mounted) return;
                          if (found == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Could not find collection for this file'),
                              ),
                            );
                            return;
                          }
                          targetCollection = found;
                        }
                        setState(() {
                          collection = targetCollection;
                          path = file.parent;
                          selectedAsset = file;
                          _lastSelectedAsset = file;
                          _showLightbox = false;
                          _breadcrumbTrail = _trailFromFolderPath(file.parent);
                        });
                        _fileOffset = 0;
                        _hasMoreFiles = true;
                        _filesAndFoldersService!.invoke(
                          GetFileAndFoldersServiceCommand(
                            targetCollection,
                            file.parent,
                          ),
                        );
                      },
                      onDeleteFile: (file) {
                        if (selectedAsset?.id == file.id) {
                          setState(() {
                            selectedAsset = null;
                            _showLightbox = false;
                          });
                        }
                        _filesAndFoldersService!.invoke(
                          GetFileAndFoldersServiceCommand(
                            collection!,
                            path ?? '',
                            refreshOnly: true,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              )
              : const SizedBox.shrink(),
    );
  }

  BreadCrumb getBreadcrumb(
    ThemeData theme,
    Collection collection,
    String path,
  ) {
    final isCollectionActive = _breadcrumbTrail.isEmpty;
    return BreadCrumb(
      items: <BreadCrumbItem>[
        BreadCrumbItem(
          content: Icon(
            Icons.home_outlined,
            color: theme.colorScheme.onSurfaceVariant,
            size: 20,
          ),
          onTap: () {
            setState(() {
              this.path = '';
              _breadcrumbTrail = [];
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, ''),
            );
            _triggerShallowScan(collection, '');
          },
        ),
        BreadCrumbItem(
          content: Text(
            collection.name,
            style: TextStyle(
              color:
                  isCollectionActive
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
              fontWeight:
                  isCollectionActive ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          onTap: () {
            setState(() {
              this.path = '';
              _breadcrumbTrail = [];
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, ''),
            );
            _triggerShallowScan(collection, '');
          },
        ),
        // One item per folder the user has drilled into
        ..._breadcrumbTrail.asMap().entries.map((entry) {
          final index = entry.key;
          final crumb = entry.value;
          final isLast = index == _breadcrumbTrail.length - 1;
          return BreadCrumbItem(
            content: Text(
              crumb.name,
              style: TextStyle(
                color:
                    isLast
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
                fontSize: 14,
              ),
            ),
            onTap: () {
              // Navigate to this level and trim everything after it
              setState(() {
                this.path = crumb.path;
                _breadcrumbTrail = _breadcrumbTrail.sublist(0, index + 1);
                selectedAsset = null;
              });
              _filesAndFoldersService!.invoke(
                GetFileAndFoldersServiceCommand(collection, crumb.path),
              );
              _triggerShallowScan(collection, crumb.path);
            },
          );
        }),
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

  /// Builds a breadcrumb trail from a relative folder path.
  /// e.g. 'Photos/2024/vacation' → [Photos, Photos/2024, Photos/2024/vacation]
  List<_BreadcrumbEntry> _trailFromFolderPath(String folderPath) {
    if (folderPath.isEmpty) return [];
    final parts = folderPath.split('/').where((s) => s.isNotEmpty).toList();
    final trail = <_BreadcrumbEntry>[];
    for (int i = 0; i < parts.length; i++) {
      trail.add(_BreadcrumbEntry(
        name: parts[i],
        path: parts.sublist(0, i + 1).join('/'),
      ));
    }
    return trail;
  }

  List<FileAsset> _mergeAndSortRowData(
    List<FileAsset> fileAssets,
    String sortColumn,
    bool sortAsc,
  ) {
    fileAssets.sort((a, b) {
      if (a is File && b is Folder) {
        return 1;
      } else if (a is Folder && b is File) {
        return -1;
      } else {
        if (sortAsc) {
          if (a is File && b is File && sortColumn == "size") {
            return a.size.compareTo(b.size);
          } else if (sortColumn == "date_created") {
            return a.dateCreated.compareTo(b.dateCreated);
          } else {
            return a.name.compareTo(b.name);
          }
        } else {
          if (a is File && b is File && sortColumn == "size") {
            return b.size.compareTo(a.size);
          } else if (sortColumn == "date_created") {
            return b.dateCreated.compareTo(a.dateCreated);
          } else {
            return b.name.compareTo(a.name);
          }
        }
      }
    });

    return fileAssets;
  }

  Future<void> _showBulkDeleteConfirmationDialog(BuildContext context) async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Delete Multiple Files'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  'Are you sure you want to delete ${selectedItems.length} items?',
                ),
                const SizedBox(height: 8),
                const Text(
                  'This will permanently remove these files from your computer and the database.',
                  style: TextStyle(color: Colors.red),
                ),
              ],
            ),
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
                await _deleteSelectedFiles(context);
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteSelectedFiles(BuildContext context) async {
    final itemsToDelete = List<FileAsset>.from(selectedItems);
    int deletedCount = 0;
    int errorCount = 0;

    for (var item in itemsToDelete) {
      if (item is File) {
        try {
          // Reconstruct absolute path for filesystem delete.
          final absPath = item.localPath ?? FilePathResolver.absolute(item, collection!);
          final ioFile = io.File(absPath);
          if (await ioFile.exists()) {
            await ioFile.delete();
          }
          // Delete from database
          await FileDesktopRepository(
            DatabaseManager.instance.database!,
          ).delete(item);
          deletedCount++;
        } catch (e) {
          logger.e("Error deleting ${item.path}: $e");
          errorCount++;
        }
      }
    }

    if (context.mounted) {
      setState(() {
        selectedItems = [];
      });
      // Refresh list
      _filesAndFoldersService!.invoke(
        GetFileAndFoldersServiceCommand(
          collection!,
          path ?? '',
          refreshOnly: true,
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $deletedCount files${errorCount > 0 ? ' ($errorCount errors)' : ''}',
          ),
        ),
      );
    }
  }

  Future<void> _downloadSelectedFiles(BuildContext context) async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

    if (selectedDirectory == null) return;

    int copiedCount = 0;
    int errorCount = 0;

    for (var item in selectedItems) {
      if (item is File) {
        try {
          final fileName = item.name;
          final destinationPath = p.join(selectedDirectory, fileName);

          if (item.path.startsWith('gdrive://')) {
            if (item.downloadUrl != null && collection != null) {
              final token = await GoogleDriveAuthService.getValidAccessToken(
                collection!,
              );
              final uri = Uri.parse(item.downloadUrl!);
              final queryParams = Map<String, String>.from(uri.queryParameters);
              queryParams.remove('authuser');
              final cleanUri = uri.replace(queryParameters: queryParams);

              final response = await http.get(
                cleanUri,
                headers: {'Authorization': 'Bearer $token'},
              );
              if (response.statusCode == 200) {
                await io.File(destinationPath).writeAsBytes(response.bodyBytes);
                copiedCount++;
              } else {
                throw Exception('Download failed: ${response.statusCode}');
              }
            }
          } else {
            // Reconstruct absolute path for local files.
            final absPath = FilePathResolver.absolute(item, collection!);
            final sourceFile = io.File(absPath);
            await sourceFile.copy(destinationPath);
            copiedCount++;
          }
        } catch (e) {
          logger.e("Error copying ${item.path}: $e");
          errorCount++;
        }
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Copied $copiedCount files to $selectedDirectory${errorCount > 0 ? ' ($errorCount errors)' : ''}',
          ),
        ),
      );
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
            'Scanning ${collection?.name ?? "files"}...',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            'This may take a minute for large folders.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  bool _isTextInputFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null) return false;
    final context = primaryFocus.context;
    if (context == null) return false;

    bool isInput = false;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        isInput = true;
        return false;
      }
      return true;
    });
    return isInput || context.widget is EditableText;
  }

  bool _isImage(File file) {
    if (file.contentType.startsWith('image/')) return true;
    final ext = p.extension(file.name).toLowerCase();
    return [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tif',
      '.psd',
    ].contains(ext);
  }

  bool _isPdf(File file) {
    if (file.contentType == 'application/pdf' ||
        file.contentType == 'application/x-pdf')
      return true;
    return p.extension(file.name).toLowerCase() == '.pdf';
  }

  bool _isText(File file) {
    final ext = p.extension(file.name).toLowerCase();
    const textExts = [
      '.txt',
      '.html',
      '.xml',
      '.xsl',
      '.xslt',
      '.md',
      '.markdown',
      '.json',
      '.yaml',
      '.yml',
      '.dart',
      '.py',
      '.js',
      '.css',
    ];
    return textExts.contains(ext) || file.contentType.startsWith('text/');
  }

  String _resolvedPath(File file) =>
      FilePathResolver.absolute(file, collection!);

  Future<List<int>?> _getGDriveFileBytes(File file) async {
    try {
      final token = await GoogleDriveAuthService.getValidAccessToken(
        collection!,
      );

      Uri uri;
      if (file.path.startsWith('gdrive://')) {
        final fileId = file.path.replaceFirst('gdrive://', '');
        uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
        );
      } else if (file.downloadUrl != null) {
        uri = Uri.parse(file.downloadUrl!);
        final queryParams = Map<String, String>.from(uri.queryParameters);
        queryParams.remove('authuser');
        uri = uri.replace(queryParameters: queryParams);
      } else {
        return null;
      }

      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('Error downloading GDrive file for preview: $e');
    }
    return null;
  }

  Future<String> _loadTextContent(File file) async {
    try {
      if (file.path.startsWith('gdrive://')) {
        final bytes = await _getGDriveFileBytes(file);
        if (bytes != null) {
          return utf8.decode(bytes);
        }
      } else {
        final ioFile = io.File(_resolvedPath(file));
        if (await ioFile.exists()) {
          return await ioFile.readAsString();
        }
      }
    } catch (e) {
      debugPrint('Error loading lightbox text preview: $e');
    }
    return 'Could not load file content.';
  }

  Widget _buildLightboxOverlay(ThemeData theme) {
    if (!_showLightbox || _lastSelectedAsset == null) {
      return const SizedBox.shrink();
    }

    final asset = _lastSelectedAsset!;
    final ext = p.extension(asset.name).toLowerCase();

    Widget content;
    if (asset is File) {
      if (_isPdf(asset)) {
        content = PdfPreviewWidget(
          filePath:
              asset.path.startsWith('gdrive://')
                  ? asset.path
                  : _resolvedPath(asset),
          previewHeight: double.infinity,
        );
      } else if (ext == '.stl') {
        content = StlPreviewWidget(
          file: asset,
          previewHeight: double.infinity,
          resolvedPath: _resolvedPath(asset),
          onDownloadGDrive:
              asset.path.startsWith('gdrive://')
                  ? () => _getGDriveFileBytes(asset)
                  : null,
        );
      } else if (asset.contentType.startsWith('video/') ||
          ['.mp4', '.mov', '.avi', '.mkv', '.m4v', '.webm'].contains(ext)) {
        content = VideoFilePreview(
          path: _resolvedPath(asset),
          height: double.infinity,
          isGDrive: asset.path.startsWith('gdrive://'),
          onDownloadGDrive: () => _getGDriveFileBytes(asset),
        );
      } else if (_isImage(asset) || asset.path.startsWith('gdrive://')) {
        content = ImagePreviewWidget(
          file: asset,
          resolvedPath: _resolvedPath(asset),
          showOriginal: true,
        );
      } else if (_isText(asset)) {
        content = Container(
          color: Colors.grey.shade900,
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: FutureBuilder<String>(
              future: _loadTextContent(asset),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return const Text(
                    'Error loading preview',
                    style: TextStyle(color: Colors.white),
                  );
                }
                if (ext == '.md' || ext == '.markdown') {
                  return MarkdownBody(
                    data: snapshot.data!,
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: const TextStyle(color: Colors.white70),
                      h1: const TextStyle(color: Colors.white),
                      h2: const TextStyle(color: Colors.white),
                      code: const TextStyle(
                        backgroundColor: Colors.black38,
                        color: Colors.amberAccent,
                      ),
                    ),
                  );
                }
                return Text(
                  snapshot.data!,
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 13,
                    color: Colors.white70,
                  ),
                );
              },
            ),
          ),
        );
      } else {
        content = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              size: 80,
              color: Colors.white54,
            ),
            const SizedBox(height: 16),
            Text(
              asset.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Preview not supported for this file type in Lightroom.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        );
      }
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.folder_outlined, size: 80, color: Colors.amber),
          const SizedBox(height: 16),
          Text(
            asset.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        // Blur & Black Dim Backdrop
        GestureDetector(
          onTap: () => setState(() => _showLightbox = false),
          child: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(
                color: Colors.black.withValues(alpha: 0.85),
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
        ),
        // Content Area
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.transparent,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: InteractiveViewer(maxScale: 4.0, child: content),
              ),
            ),
          ),
        ),
        // Close Button (Top-Right)
        Positioned(
          top: 24,
          right: 24,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 24),
              tooltip: 'Close Preview (Esc)',
              onPressed: () => setState(() => _showLightbox = false),
            ),
          ),
        ),
      ],
    );
  }
}
