import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/found_folders_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_error_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_loading_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_success_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_configure_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/local_files_tab_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/sync_estimate_dialog.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

typedef ExistingCollectionPaths = Future<Set<String>> Function();

Future<Set<String>> _loadExistingCollectionPaths() async {
  final all =
      await CollectionRepository(
        DatabaseManager.instance.database!,
      ).collections();
  return all.map((c) => c.path).whereType<String>().toSet();
}

/// "Add files" page: auto-detected sync folders, cloud accounts, and a manual
/// folder picker for anything else.
class NewFileCollectionPage extends StatefulWidget {
  const NewFileCollectionPage({super.key, this.detector, this.existingPaths});

  /// Injectable for tests; defaults to a real [SyncFolderDetector].
  final SyncFolderDetector? detector;

  /// Paths already used by a collection (hidden from "Found on this Mac").
  final ExistingCollectionPaths? existingPaths;

  @override
  State<NewFileCollectionPage> createState() => _NewFileCollectionPage();
}

class _NewFileCollectionPage extends State<NewFileCollectionPage> {
  String? name;
  String? path;

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _path = TextEditingController();

  late final Future<List<DetectedSyncFolder>> _found = _findFolders();

  Future<List<DetectedSyncFolder>> _findFolders() async {
    try {
      final detected = (widget.detector ?? SyncFolderDetector()).detect();
      final existing =
          (await (widget.existingPaths ?? _loadExistingCollectionPaths)())
              .map(_normalize)
              .toList();
      return detected.where((f) {
        final path = _normalize(f.path);
        return !existing.any((e) => path == e || p.isWithin(e, path));
      }).toList();
    } catch (e, st) {
      AppLogger(
        null,
      ).e('Sync folder detection failed', error: e, stackTrace: st);
      return const [];
    }
  }

  static String _normalize(String path) {
    final n = p.normalize(path);
    return n.length > 1 && n.endsWith('/') ? n.substring(0, n.length - 1) : n;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionHeader('Found on this Mac'),
                FutureBuilder<List<DetectedSyncFolder>>(
                  future: _found,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: LinearProgressIndicator(),
                      );
                    }
                    return FoundFoldersSection(
                      folders: snap.data ?? const [],
                      onAdd: _addDetected,
                    );
                  },
                ),
                const SizedBox(height: 32),
                const _SectionHeader('Connect an account'),
                const _GoogleDriveTab(),
                const SizedBox(height: 32),
                const _SectionHeader('Other'),
                _buildLocalFilesTab(context),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLocalFilesTab(BuildContext context) {
    return LocalFilesTabView(
      formKey: _formKey,
      nameController: _name,
      pathController: _path,
      onBrowse: () => _browse(),
      onSave: () => _save(context),
      onCancel: () => GoRouter.of(context).go('/files'),
    );
  }

  void _addDetected(DetectedSyncFolder folder) {
    _createLocalCollection(folder.displayName, folder.path);
    GoRouter.of(context).go('/files');
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      _name.text = result.split('/').last;
      _path.text = result;
      setState(() {
        name = result.split('/').last;
        path = result;
      });
    }
  }

  /// Single creation path for a local file collection, shared by the manual
  /// picker and the auto-detected "Add" action.
  void _createLocalCollection(String name, String selectedPath) {
    final fc = Collection(
      id: const Uuid().v4().toString(),
      name: name,
      path: selectedPath,
      localCopyPath: selectedPath,
      type: 'file',
      scanner: AppConstants.scannerFileLocal,
      scanStatus: 'pending',
      needsReAuth: false,
    );

    CollectionRepository(
      DatabaseManager.instance.database!,
    ).addCollection(fc).then((_) {
      GetCollectionsService.instance.invoke(GetCollectionsServiceCommand(null));
      ScannerManager.getInstance().startScanner(fc);
      RxFilesPage.selectedCollection.add(fc);
    });
  }

  void _save(BuildContext context) {
    // validate() both answers the question and paints the errors, which is
    // what the old markAllAsTouched() branch existed to do.
    if (_formKey.currentState?.validate() ?? false) {
      _createLocalCollection(_name.text, _path.text);
      GoRouter.of(context).go('/files');
    }
  }
}

// =============================================================================
// Google Drive Tab — lives in its own StatefulWidget to keep auth state local
// =============================================================================

enum _DriveAuthState { idle, checking, loading, success, error, configure }

class _GoogleDriveTab extends StatefulWidget {
  const _GoogleDriveTab();

  @override
  State<_GoogleDriveTab> createState() => _GoogleDriveTabState();
}

class _GoogleDriveTabState extends State<_GoogleDriveTab> {
  _DriveAuthState _authState = _DriveAuthState.loading;
  String? _errorMessage;
  String? _connectedEmail;
  ContentPolicy _policy = ContentPolicy.everything;
  bool _keepDeletedFiles = false;

  @override
  void initState() {
    super.initState();
    _checkConfiguration();
  }

  Future<void> _checkConfiguration() async {
    setState(() {
      _authState = _DriveAuthState.checking;
    });

    final clientId = await LoginProviders.googleDrive.clientId();
    final clientSecret = await LoginProviders.googleDrive.clientSecret();

    if (!mounted) return;

    if (clientId.isEmpty || clientSecret.isEmpty) {
      setState(() {
        _authState = _DriveAuthState.configure;
      });
    } else {
      setState(() {
        _authState = _DriveAuthState.idle;
      });
    }
  }

  Future<void> _connectGoogleDrive() async {
    setState(() {
      _authState = _DriveAuthState.loading;
      _errorMessage = null;
    });

    try {
      final collection = await LoginProviderExtension.handleGoogleDrive(
        context,
        contentPolicy: _policy,
        confirmSync:
            (api) async =>
                await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => SyncEstimateDialog(api: api, policy: _policy),
                ) ??
                false,
        keepDeletedFiles: _keepDeletedFiles,
      );

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _DriveAuthState.error;
          _errorMessage = 'Sign-in was cancelled or failed. Please try again.';
        });
        return;
      }

      ScannerManager.getInstance().startScanner(collection);

      final nameMatch = RegExp(r'\((.+?)\)').firstMatch(collection.name);
      setState(() {
        _authState = _DriveAuthState.success;
        _connectedEmail = nameMatch?.group(1);
      });

      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      GoRouter.of(context).go('/files');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authState = _DriveAuthState.error;
        final raw = e.toString();
        _errorMessage =
            raw.startsWith('Exception:')
                ? raw.replaceFirst('Exception:', '').trim()
                : raw;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder:
              (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.04),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
          child: switch (_authState) {
            _DriveAuthState.checking => const Center(
              key: ValueKey('checking'),
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            ),
            _DriveAuthState.loading => _cardContainer(
              key: const ValueKey('loading'),
              child: const GoogleDriveLoadingView(),
            ),
            _DriveAuthState.success => _cardContainer(
              key: const ValueKey('success'),
              child: GoogleDriveSuccessView(connectedEmail: _connectedEmail),
            ),
            _DriveAuthState.error => _cardContainer(
              key: const ValueKey('error'),
              child: GoogleDriveErrorView(
                errorMessage: _errorMessage,
                onRetry: _connectGoogleDrive,
              ),
            ),
            _DriveAuthState.configure => _cardContainer(
              key: const ValueKey('configure'),
              child: GoogleDriveConfigureView(
                onConfigured: _checkConfiguration,
              ),
            ),
            _DriveAuthState.idle => _cardContainer(
              key: const ValueKey('idle'),
              child: GoogleDriveIdleView(
                onConnect: _connectGoogleDrive,
                policy: _policy,
                onPolicyChanged: (value) => setState(() => _policy = value),
                keepDeletedFiles: _keepDeletedFiles,
                onKeepDeletedFilesChanged: (value) {
                  setState(() {
                    _keepDeletedFiles = value;
                  });
                },
              ),
            ),
          },
        ),
      ),
    );
  }

  Widget _cardContainer({required Widget child, required Key key}) {
    return Card(
      key: key,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(36), child: child),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}
