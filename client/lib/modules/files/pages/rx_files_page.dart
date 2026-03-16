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
import 'package:mydatatools/modules/files/services/delete_file_service.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' as io;
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:rxdart/rxdart.dart';

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
  String sortColumn = "name";
  bool sortAsc = true;
  List<FileAsset> selectedItems = [];
  FileAsset? selectedAsset;
  double _drawerWidth = 300;

  @override
  void initState() {
    _collectionService = GetCollectionsService.instance;

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

        _filesAndFoldersService!.invoke(
          GetFileAndFoldersServiceCommand(value, value.path),
        );
      }
      setState(() {
        collection = value;
        path = value?.path;
        selectedItems = []; // reset selection on collection change
        selectedAsset = null; // close details drawer on collection change
      });
    });

    _collectionService!.invoke(GetCollectionsServiceCommand(null)); //load all
    super.initState();
  }

  @override
  void dispose() {
    _fileServiceSub?.cancel();
    _collectionsServiceSub?.cancel();
    _selectedCollectionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    //final size = MediaQuery.of(context).size;

    if (collections.isEmpty) {
      return const NewFileCollectionPage();
    }

    if (collection == null) {
      return Container();
    }
    //parse path into a breadcrumb

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: getBreadcrumb(collection!, path ?? collection!.path),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(height: 1.0, color: Colors.grey.shade300),
        ),
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
            icon: const Icon(Icons.download, color: Colors.black, weight: 200),
            tooltip: 'Download File(s)',
            onPressed: selectedItems.isEmpty ? null : () => _downloadSelectedFiles(context),
          ),
          IconButton(
            // TODO: disable is no files are checked
            icon: const Icon(Icons.refresh, color: Colors.black, weight: 100),
            tooltip: 'Refresh',
            onPressed: () {
              //reset date
              // collectionRepository.updateLastScanDate(collection, null);
              //refresh path
              if (collection != null) {
                logger.s("refresh file list");
                _filesAndFoldersService!.invoke(
                  GetFileAndFoldersServiceCommand(collection!, path ?? collection!.path),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.black, weight: 300),
            tooltip: 'Delete File(s)',
            onPressed: selectedItems.isEmpty ? null : () => _showBulkDeleteConfirmationDialog(context),
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
                      NotificationListener<FiledNotification>(
                        child: FileTable(data: filesAndFolders),
                        onNotification: (FiledNotification n) {
                          if (n is PathChangedNotification) {
                            if (n.asset.path != collection?.path) {
                              //make sure path changed before triggering reload
                              setState(() {
                                path = n.asset.path;
                                selectedItems = []; // reset selection on path change
                                selectedAsset = null; // close drawer when drilling into folder
                              });
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
                                path ?? collection!.path,
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
                      StreamBuilder<bool>(
                        stream: _filesAndFoldersService?.isLoading,
                        builder: (context, snapshot) {
                          if (snapshot.data == true) {
                            return Container(
                              color: Colors.white.withOpacity(0.3),
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }
                          return const SizedBox.shrink();
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
                      width: _drawerWidth,
                      onClose: () => setState(() => selectedAsset = null),
                      onExpand: () => setState(() {
                        _drawerWidth = _drawerWidth >= 700.0 ? 300.0 : 700.0;
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
    List<String> pathParts = path.split(":").last.split('/');
    List<String> collectionParts = collection.path.split('/');
    List<String> parts = [];
    for (var i = 0; i < pathParts.length; ++i) {
      var p = pathParts[i];
      var cp = (collectionParts.length > i) ? collectionParts[i] : "";
      if (p != cp) {
        parts.add(pathParts[i]);
      }
    }

    List<String> workingPath = [];

    return BreadCrumb(
      items: <BreadCrumbItem>[
        BreadCrumbItem(
          content: const Icon(Icons.home, color: Colors.black),
          onTap: () {
            //return null, to unselect a collection and have app go back to pick collection (home) page
            //return dummy FileCollection
            setState(() {
              path = collection.path;
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, path!),
            );
          },
        ),
        BreadCrumbItem(
          content: Text(collection.name),
          onTap: () {
            //go back to root of collection
            setState(() {
              path = collection.path;
              selectedAsset = null;
            });
            _filesAndFoldersService!.invoke(
              GetFileAndFoldersServiceCommand(collection, path!),
            );
          },
        ),
        ...parts.where((e) => e != '').map((e) {
          workingPath.add(e);
          String p = '${collection.path}/${workingPath.join("/")}';
          return BreadCrumbItem(
            content: Text(e),
            onTap: () {
              //drill into sub folder path
              setState(() {
                path = p;
                selectedAsset = null;
              });
              _filesAndFoldersService!.invoke(
                GetFileAndFoldersServiceCommand(collection, path!),
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
                Text('Are you sure you want to delete ${selectedItems.length} items?'),
                const SizedBox(height: 8),
                const Text('This will permanently remove these files from your computer and the database.', style: TextStyle(color: Colors.red)),
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
          final ioFile = io.File(item.path);
          if (await ioFile.exists()) {
            await ioFile.delete();
          }
          final db = DatabaseManager.instance.database;
          if (db != null) {
            await DeleteFileService.instance.invoke(DeleteFileServiceCommand(item, db));
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
          path ?? collection!.path,
          refreshOnly: true,
        ),
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted $deletedCount files${errorCount > 0 ? ' ($errorCount errors)' : ''}')),
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
              final token =
                  await GoogleDriveAuthService.getValidAccessToken(collection!);
              final response = await http.get(
                Uri.parse(item.downloadUrl!),
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
            final sourceFile = io.File(item.path);
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
        SnackBar(content: Text('Copied $copiedCount files to $selectedDirectory${errorCount > 0 ? ' ($errorCount errors)' : ''}')),
      );
    }
  }
}
