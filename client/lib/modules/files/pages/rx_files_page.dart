import 'dart:async';

import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/modules/files/notifications/file_notification.dart';
import 'package:mydatatools/modules/files/notifications/path_changed_notification.dart';
import 'package:mydatatools/modules/files/notifications/sort_changed_notification.dart';
import 'package:mydatatools/modules/files/pages/new_file_collection_page.dart';
import 'package:mydatatools/modules/files/services/get_files_and_folders_service.dart';
import 'package:mydatatools/modules/files/widgets/file_table.dart';
import 'package:mydatatools/modules/files/widgets/file_details_drawer.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:mydatatools/database_manager.dart';

import 'package:mydatatools/helpers/file_path_resolver.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' as io;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:rxdart/rxdart.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';

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
  double _drawerWidth = 300;

  @override
  void initState() {
    _collectionService = GetCollectionsService.instance;
    _attachScrollListener();

    _collectionsServiceSub = _collectionService!.sink.listen((value) {
      setState(() {
        collections = value;
      });
      if (value.isNotEmpty) {
        //select default collection
        RxFilesPage.selectedCollection.add(value.first);
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
      }
      setState(() {
        collection = value;
        path = ''; // relative root
        _breadcrumbTrail = []; // reset trail on collection change
        selectedItems = []; // reset selection on collection change
        selectedAsset = null; // close details drawer on collection change
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
    print('RxFilesPage.build: collections.length = ${collections.length}, collection = $collection');
    if (collections.isEmpty) {
      return const NewFileCollectionPage();
    }

    if (collection == null) {
      return Container();
    }
    //parse path into a breadcrumb

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: getBreadcrumb(collection!, path ?? collection!.path),
        bottom:
            (_isLoadingMore || _isServiceLoading || isScanning)
                ? const PreferredSize(
                  preferredSize: Size.fromHeight(2.0),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                  ),
                )
                : null,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add, color: Colors.black, weight: 200),
            tooltip: 'Upload file',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('todo: add file to current folder'),
                ),
              );
            },
          ),
          IconButton(
            // TODO: disable is no files are checked
            icon: const Icon(Icons.refresh, color: Colors.black, weight: 100),
            tooltip: 'Refresh',
            onPressed: () async {
              if (collection != null) {
                logger.s("Refreshing folder $path");

                // Get absolute path for scanning
                final absPath = FilePathResolver.absoluteFromPath(
                  path ?? '',
                  collection!,
                );

                // Start a scan for this specific folder (non-recursive)
                final mgr = ScannerManager.getInstance();
                final scanner = await mgr.getScannerAsync(collection!);
                await scanner.start(collection!, absPath, false, true);

                // Also refresh the UI from the database
                _filesAndFoldersService!.invoke(
                  GetFileAndFoldersServiceCommand(collection!, path ?? ''),
                );
              }
            },
          ),
          const VerticalDivider(
            color: Colors.grey,
            thickness: 1,
            indent: 10,
            endIndent: 10,
          ),
          IconButton(
            icon: const Icon(Icons.download, color: Colors.black, weight: 200),
            tooltip: 'Download File(s)',
            onPressed:
                selectedItems.isEmpty
                    ? null
                    : () => _downloadSelectedFiles(context),
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.black, weight: 300),
            tooltip: 'Delete File(s)',
            onPressed:
                selectedItems.isEmpty
                    ? null
                    : () => _showBulkDeleteConfirmationDialog(context),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                Expanded(
                  flex: 3,
                  child: Stack(
                    children: [
                      if (filesAndFolders.isEmpty &&
                          (_isLoadingMore || _isServiceLoading))
                        const Center(child: CircularProgressIndicator())
                      else if (filesAndFolders.isEmpty && isScanning)
                        _buildScanningPlaceholder()
                      else
                        NotificationListener<FiledNotification>(
                          child: FileTable(
                            data: filesAndFolders,
                            collection: collection,
                            scrollController: _scrollController,
                          ),
                          onNotification: (FiledNotification n) {
                            if (n is PathChangedNotification) {
                              if (n.asset.path != path) {
                                //make sure path changed before triggering reload
                                setState(() {
                                  path = n.asset.path;
                                  // Push this folder onto the breadcrumb trail
                                  _breadcrumbTrail = [
                                    ..._breadcrumbTrail,
                                    _BreadcrumbEntry(
                                      name: n.asset.name,
                                      path: n.asset.path,
                                    ),
                                  ];
                                  selectedItems =
                                      []; // reset selection on path change
                                  selectedAsset =
                                      null; // close drawer when drilling into folder
                                });
                                // Reset pagination before loading the new path.
                                _fileOffset = 0;
                                _hasMoreFiles = true;
                                _filesAndFoldersService!.invoke(
                                  GetFileAndFoldersServiceCommand(
                                    collection!,
                                    n.asset.path,
                                  ),
                                );
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
                              });
                              return true;
                            }
                            if (n is FileSelectedNotification) {
                              setState(() {
                                selectedAsset = n.asset;
                              });
                              return true;
                            }
                            return false;
                          },
                        ),
                    ],
                  ),
                ),
                if (selectedAsset != null) ...[
                  // ─── Drag handle ───────────────────────────
                  MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: (details) {
                        setState(() {
                          _drawerWidth = (_drawerWidth - details.delta.dx)
                              .clamp(200.0, 700.0);
                        });
                      },
                      child: Container(
                        width: 6,
                        color: Colors.transparent,
                        child: Center(
                          child: Container(
                            width: 2,
                            color: Colors.grey.shade300,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ─── Drawer ────────────────────────────────
                  SizedBox(
                    width: _drawerWidth,
                    child: FileDetailsDrawer(
                      asset: selectedAsset!,
                      collection: collection!,
                      width: _drawerWidth,
                      onClose: () => setState(() => selectedAsset = null),
                      onExpand:
                          () => setState(() {
                            _drawerWidth =
                                _drawerWidth >= 700.0 ? 300.0 : 700.0;
                          }),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  BreadCrumb getBreadcrumb(Collection collection, String path) {
    return BreadCrumb(
      items: <BreadCrumbItem>[
        BreadCrumbItem(
          content: const Icon(Icons.home, color: Colors.black),
          onTap: () {
            setState(() {
              this.path = '';
              _breadcrumbTrail = [];
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, ''),
            );
          },
        ),
        BreadCrumbItem(
          content: Text(collection.name),
          onTap: () {
            setState(() {
              this.path = '';
              _breadcrumbTrail = [];
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, ''),
            );
          },
        ),
        // One item per folder the user has drilled into
        ..._breadcrumbTrail.asMap().entries.map((entry) {
          final index = entry.key;
          final crumb = entry.value;
          return BreadCrumbItem(
            content: Text(crumb.name),
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
            },
          );
        }),
      ],
      divider: const Icon(Icons.chevron_right, color: Colors.black),
      overflow: const WrapOverflow(
        keepLastDivider: false,
        direction: Axis.horizontal,
      ),
    );
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
          final absPath = FilePathResolver.absolute(item, collection!);
          final ioFile = io.File(absPath);
          if (await ioFile.exists()) {
            await ioFile.delete();
          }
          // Delete from database via writer isolate to avoid SQLITE_BUSY
          final writer = DatabaseManager.instance.writerIsolateClient;
          if (writer != null) {
            await writer.send({'type': 'delete_file', 'file': item});
          }
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
            'This may take a minute for large accounts.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
