import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/coming_soon_tab_view.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_error_view.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_loading_view.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/google_drive_success_view.dart';
import 'package:mydatatools/modules/files/widgets/file_collection_setup/local_files_tab_view.dart';
import 'package:mydatatools/oauth/login_providers.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:uuid/uuid.dart';

class NewFileCollectionPage extends StatefulWidget {
  const NewFileCollectionPage({super.key});

  @override
  State<NewFileCollectionPage> createState() => _NewFileCollectionPage();
}

class _NewFileCollectionPage extends State<NewFileCollectionPage> {
  String? name;
  String? path;

  final form = FormGroup({
    'name': FormControl<String>(validators: [Validators.required]),
    'path': FormControl<String>(validators: [Validators.required]),
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'Local Files'),
              Tab(text: 'Google Drive'),
              Tab(text: 'Dropbox'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildLocalFilesTab(context),
                const _GoogleDriveTab(),
                const ComingSoonTabView(provider: 'Dropbox'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalFilesTab(BuildContext context) {
    return LocalFilesTabView(
      form: form,
      onBrowse: () => _browse(),
      onSave: () => _save(context),
      onCancel: () => GoRouter.of(context).go('/files'),
    );
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      form.control('name').value = result.split('/').last;
      form.control('path').value = result;
      setState(() {
        name = result.split('/').last;
        path = result;
      });
    }
  }

  void _save(BuildContext context) {
    if (form.valid) {
      final selectedPath = form.control('path').value as String;
      final fc = Collection(
        id: const Uuid().v4().toString(),
        name: form.control('name').value,
        path: selectedPath,
        localCopyPath: selectedPath,
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
        scanStatus: 'pending',
        needsReAuth: false,
      );

      CollectionRepository().addCollection(fc).then((value) {
        if (value != null) {
          GetCollectionsService.instance.invoke(
            GetCollectionsServiceCommand(null),
          );
          ScannerManager.getInstance()
              .getScanner(value)
              ?.start(value, value.path, true, true);
          RxFilesPage.selectedCollection.add(value);
        }
      });

      GoRouter.of(context).go('/files');
    } else {
      form.markAllAsTouched();
    }
  }
}

// =============================================================================
// Google Drive Tab — lives in its own StatefulWidget to keep auth state local
// =============================================================================

enum _DriveAuthState { idle, loading, success, error }

class _GoogleDriveTab extends StatefulWidget {
  const _GoogleDriveTab();

  @override
  State<_GoogleDriveTab> createState() => _GoogleDriveTabState();
}

class _GoogleDriveTabState extends State<_GoogleDriveTab> {
  _DriveAuthState _authState = _DriveAuthState.idle;
  String? _errorMessage;
  String? _connectedEmail;
  bool _saveLocalCopy = true;

  Future<void> _connectGoogleDrive() async {
    setState(() {
      _authState = _DriveAuthState.loading;
      _errorMessage = null;
    });

    try {
      final collection = await LoginProviderExtension.handleGoogleDrive(
        context,
        downloadLocalCopy: _saveLocalCopy,
      );

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _DriveAuthState.error;
          _errorMessage = 'Sign-in was cancelled or failed. Please try again.';
        });
        return;
      }

      ScannerManager.getInstance()
          .getScanner(collection)
          ?.start(collection, collection.path, true, true);

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
        _errorMessage = raw.startsWith('Exception:')
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
          transitionBuilder: (child, animation) => FadeTransition(
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
            _DriveAuthState.idle => _cardContainer(
                key: const ValueKey('idle'),
                child: GoogleDriveIdleView(
                  onConnect: _connectGoogleDrive,
                  saveLocalCopy: _saveLocalCopy,
                  onSaveLocalCopyChanged: (value) {
                    setState(() {
                      _saveLocalCopy = value ?? true;
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
