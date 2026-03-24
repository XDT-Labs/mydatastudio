import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/pages/rx_files_page.dart';
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
                _buildComingSoonTab('Dropbox'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Local Files tab (unchanged)
  // ---------------------------------------------------------------------------

  Widget _buildLocalFilesTab(BuildContext context) {
    return Center(
      child: SizedBox(
        width: MediaQuery.of(context).size.width / 2,
        child: ReactiveForm(
          formGroup: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Select folder to add.",
                style: TextStyle(fontWeight: FontWeight.normal, fontSize: 16),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ReactiveTextField(
                      formControlName: 'name',
                      decoration: const InputDecoration(
                        hintText: 'Name of folder',
                        labelText: 'Name *',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ReactiveTextField(
                      formControlName: 'path',
                      readOnly: true,
                      decoration: const InputDecoration(
                        icon: Icon(Icons.folder_open),
                        hintText: 'Click Browse to select a folder',
                        labelText: 'Folder *',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      String? result =
                          await FilePicker.platform.getDirectoryPath();
                      if (result != null) {
                        form.control('name').value = result.split("/").last;
                        form.control('path').value = result;

                        setState(() {
                          name = result.split("/").last;
                          path = result;
                        });
                      }
                    },
                    icon: const Icon(Icons.search),
                    label: const Text("Browse"),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => GoRouter.of(context).go('/files'),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () {
                      if (form.valid) {
                        final selectedPath = form.control('path').value as String;
                        Collection fc = Collection(
                          id: const Uuid().v4().toString(),
                          name: form.control('name').value,
                          path: selectedPath,
                          localCopyPath: selectedPath, // absolute root for relative-path resolution
                          type: "file",
                          scanner: AppConstants.scannerFileLocal,
                          scanStatus: "pending",
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
                    },
                    child: const Text('Add Folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Coming soon tab (Dropbox, OneDrive, etc.)
  // ---------------------------------------------------------------------------

  Widget _buildComingSoonTab(String provider) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_shared,
            size: 64,
            color: Colors.grey.shade300,
          ),
          const SizedBox(height: 16),
          Text(
            "$provider Coming Soon",
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "We're working on integrating this source.",
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
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

  // Google brand colours
  static const Color _googleBlue = Color(0xFF4285F4);

  Future<void> _connectGoogleDrive() async {
    setState(() {
      _authState = _DriveAuthState.loading;
      _errorMessage = null;
    });

    try {
      // handleGoogleDrive() runs the desktop OAuth flow, creates the Collection,
      // persists it to the DB, and fires GetCollectionsService to refresh the sidebar.
      // It returns null on failure (and shows its own SnackBar), so we treat
      // null as a user-visible failure.
      final collection = await LoginProviderExtension.handleGoogleDrive(context);

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _DriveAuthState.error;
          _errorMessage =
              'Sign-in was cancelled or failed. Please try again.';
        });
        return;
      }

      // Start the initial scan immediately after adding the collection
      ScannerManager.getInstance()
          .getScanner(collection)
          ?.start(collection, collection.path, true, true);

      // Extract readable email from Collection name: "Google Drive (user@example.com)"
      final nameMatch = RegExp(r'\((.+?)\)').firstMatch(collection.name);
      setState(() {
        _authState = _DriveAuthState.success;
        _connectedEmail = nameMatch?.group(1);
      });

      // Brief success flash then navigate to the file list
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
            _DriveAuthState.loading => _buildLoading(),
            _DriveAuthState.success => _buildSuccess(),
            _DriveAuthState.error   => _buildError(),
            _DriveAuthState.idle    => _buildIdle(),
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Idle — connect card
  // ---------------------------------------------------------------------------

  Widget _buildIdle() {
    return _buildCard(
      key: const ValueKey('idle'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Google Drive multicolour logo substitute (M icon in brand colours)
          _buildDriveLogo(),
          const SizedBox(height: 24),
          const Text(
            'Connect Google Drive',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in with your Google account to scan and browse your Drive '
            'files directly from this app.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          // Scope notice
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Requires full Drive access to list, download, and delete files.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => GoRouter.of(context).go('/files'),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildGoogleSignInButton(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  Widget _buildLoading() {
    return _buildCard(
      key: const ValueKey('loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDriveLogo(),
          const SizedBox(height: 28),
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          const Text(
            'Connecting to Google Drive…',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Text(
            'A browser window may open for sign-in.',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Success
  // ---------------------------------------------------------------------------

  Widget _buildSuccess() {
    return _buildCard(
      key: const ValueKey('success'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Color(0xFF0F9D58),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, color: Colors.white, size: 36),
          ),
          const SizedBox(height: 20),
          const Text(
            'Google Drive Connected!',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_connectedEmail != null) ...[
            const SizedBox(height: 6),
            Text(
              _connectedEmail!,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            'Scanning your Drive in the background…',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Error
  // ---------------------------------------------------------------------------

  Widget _buildError() {
    return _buildCard(
      key: const ValueKey('error'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: Color(0xFFDB4437),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.error_outline,
                color: Colors.white, size: 36),
          ),
          const SizedBox(height: 20),
          const Text(
            'Connection Failed',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_errorMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(
                _errorMessage!,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.red.shade700,
                  height: 1.4,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => GoRouter.of(context).go('/files'),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _connectGoogleDrive,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Try Again'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _googleBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared helpers
  // ---------------------------------------------------------------------------

  Widget _buildCard({required Widget child, required Key key}) {
    return Card(
      key: key,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(36),
        child: child,
      ),
    );
  }

  /// Google Drive logo from assets.
  Widget _buildDriveLogo() {
    return Image.asset(
      'assets/images/google-drive.png',
      height: 72,
    );
  }

  Widget _buildGoogleSignInButton() {
    return ElevatedButton(
      onPressed: _connectGoogleDrive,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 2,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Google 'G' lettermark using brand colours
          _buildGoogleG(),
          const SizedBox(width: 10),
          const Text(
            'Sign in with Google',
            style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
          ),
        ],
      ),
    );
  }

  /// A Google 'G' from FontAwesome.
  Widget _buildGoogleG() {
    return const FaIcon(
      FontAwesomeIcons.google,
      size: 18,
      color: _googleBlue,
    );
  }
}


