// Copyright 2019 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/outlook_configure_view.dart';
import 'package:mydatastudio/oauth/microsoft_auth.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_connection_tester.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/email_account_setup_tab.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/email_source_catalog.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

class NewEmailPage extends StatefulWidget {
  const NewEmailPage({super.key});

  @override
  State<NewEmailPage> createState() => _NewEmailPage();
}

class _NewEmailPage extends State<NewEmailPage> {
  final GetCollectionsService _collectionsService =
      GetCollectionsService.instance;
  StreamSubscription<List<Collection>>? _collectionsServiceSub;
  List<Collection> collections = [];
  EmailSource? _selected;
  String? _initialEmail;

  @override
  void initState() {
    _collectionsServiceSub = _collectionsService.sink.listen((value) {
      setState(() {
        collections = value;
      });
    });

    super.initState();
  }

  @override
  void dispose() {
    _collectionsServiceSub?.cancel();
    super.dispose();
  }

  void _open(EmailSource source, String? email) {
    setState(() {
      _selected = source;
      _initialEmail = email;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return Scaffold(
      body:
          selected == null
              ? ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: EmailSourceCatalog(
                        accounts: collections,
                        onSelected: _open,
                      ),
                    ),
                  ),
                ],
              )
              : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _selected = null),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('All sources'),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: switch (selected.form) {
                        EmailSourceForm.imap => _ImapAccountTab(
                          provider: selected.providers.first,
                          email: _initialEmail,
                        ),
                        EmailSourceForm.outlook => const _OutlookTab(),
                        EmailSourceForm.pstFile => const _OutlookPstTab(),
                      },
                    ),
                  ],
                ),
              ),
    );
  }
}

// =============================================================================
// Outlook PST Tab — browser for a local .pst file
// =============================================================================

class _OutlookPstTab extends StatefulWidget {
  const _OutlookPstTab();

  @override
  State<_OutlookPstTab> createState() => _OutlookPstTabState();
}

class _OutlookPstTabState extends State<_OutlookPstTab> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _file = TextEditingController();

  bool _isImporting = false;

  @override
  void dispose() {
    _title.dispose();
    _file.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pst'],
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      final filePath = result.files.single.path!;
      _file.text = filePath;

      // Auto-populate title if empty
      if (_title.text.isEmpty) {
        _title.text = p.basenameWithoutExtension(filePath);
      }
    }
  }

  Future<void> _import() async {
    // validate() both answers the question and paints the errors, which is
    // what the old markAllAsTouched() call existed to do.
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _isImporting = true);

    // Tracks how far setup got, so the catch below only rolls back a collection
    // whose import never started — never one that is already running.
    Collection? persistedCollection;
    bool importStarted = false;

    try {
      final filePath = _file.text;
      final title = _title.text;

      final appDataDir = MainApp.appDataDirectory.valueOrNull;
      if (appDataDir == null) throw Exception('App data directory not ready');

      // Create collection for PST
      final collectionId = const Uuid().v4();
      final extractionRoot = p.join(appDataDir, 'files', 'email', collectionId);
      final collection = Collection(
        id: collectionId,
        name: title,
        path: filePath,
        localCopyPath: extractionRoot,
        type: 'email',
        scanner: AppConstants.scannerEmailOutlookPst,
        scanStatus: 'pending',
        needsReAuth: false,
      );

      await CollectionRepository(
        DatabaseManager.instance.database!,
      ).addCollection(collection);
      persistedCollection = collection;

      // Start the one-time scan isolate immediately. PST is a one-shot import
      // with no re-sync, so force: true is required — this is the only place the
      // archive is ever parsed.
      final serverUrl = MainApp.llmServiceUrl.valueOrNull;
      if (serverUrl == null) {
        throw Exception('LLM Service url is not configured');
      }

      final pstIsolate = OutlookPstScannerIsolate(
        token: RootIsolateToken.instance,
        appDir: appDataDir,
        dbDir: DatabaseManager.instance.databaseDirectoryPath!,
        serverUrl: serverUrl,
        serverToken: MainApp.llmServiceToken.valueOrNull,
      );
      await pstIsolate.start(collection, force: true);
      // Registered only once the isolate is actually running. Registering
      // first left a scanner entry pointing at nothing whenever the spawn
      // threw, with the collection stuck on 'pending' beside it.
      //
      // Held by the manager, not this page: the import outlives the setup
      // screen (it can run for many minutes on a multi-gigabyte archive) and
      // deleting the collection needs something to stop.
      ScannerManager.getInstance().pstScanners[collection.id] = pstIsolate;
      importStarted = true;

      // Refresh collections
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand('email'),
      );

      // Select the collection being imported, otherwise the email page falls
      // back to whichever email collection happens to be first and the user
      // watches the wrong mailbox.
      EmailPage.selectedCollection.add(collection);

      if (!mounted) return;
      GoRouter.of(context).go('/email');
    } catch (e) {
      // Roll back the half-built import. Left behind, the collection sits in
      // the email list on 'pending' forever with no scanner behind it, and the
      // user has to delete it by hand.
      if (!importStarted && persistedCollection != null) {
        ScannerManager.getInstance().pstScanners.remove(persistedCollection.id);
        try {
          await CollectionRepository(
            DatabaseManager.instance.database!,
          ).deleteCollection(persistedCollection.id);
        } catch (cleanupError) {
          debugPrint(
            'Failed to roll back collection after PST import error: '
            '$cleanupError',
          );
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to import PST: $e')));
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: Form(
              key: _formKey,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.archive_outlined,
                    size: 72,
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Outlook PST Archive',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select an Outlook PST data file to import all emails, folders, and attachments.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextFormField(
                    controller: _title,
                    validator:
                        (value) =>
                            (value == null || value.isEmpty)
                                ? 'Collection title is required'
                                : null,
                    decoration: const InputDecoration(
                      labelText: 'Collection Title',
                      hintText: 'e.g., My Old Emails',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _file,
                    readOnly: true,
                    validator:
                        (value) =>
                            (value == null || value.isEmpty)
                                ? 'Select a PST file'
                                : null,
                    decoration: InputDecoration(
                      labelText: 'PST File Path',
                      hintText: 'No file selected',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        tooltip: 'Browse for file',
                        onPressed: _isImporting ? null : _browse,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isImporting ? null : _import,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange.shade700,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child:
                          _isImporting
                              ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                              : const Text('Import PST File'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Email account (IMAP) form — provider detection, then the provider's own flow
// =============================================================================

class _ImapAccountTab extends StatelessWidget {
  const _ImapAccountTab({required this.provider, this.email});

  final EmailProvider provider;
  final String? email;

  Future<void> _save(Collection collection) async {
    // Same persistence + scanner start the old Yahoo flow used.
    GetCollectionsService.instance.addCollection(collection);
    ScannerManager.getInstance().startScanner(collection);
    EmailPage.selectedCollection.add(collection);
  }

  Future<void> _openUrl(Uri url) async {
    if (!await launchUrl(url)) throw Exception('Could not open $url');
  }

  @override
  Widget build(BuildContext context) {
    return EmailAccountSetupTab(
      connectionTester: const EnoughMailImapConnectionTester(),
      appDataDirectory: () => MainApp.appDataDirectory.valueOrNull,
      onAccountCreated: _save,
      onDone: (context) => GoRouter.of(context).go('/email'),
      oauthBuilder: (_, _) => const _OutlookTab(),
      onOpenUrl: _openUrl,
      initialProvider: provider,
      initialEmail: email,
    );
  }
}

// =============================================================================
// Outlook Tab — stateful OAuth flow
// =============================================================================

enum _OutlookAuthState { idle, loading, success, error, configure }

class _OutlookTab extends StatefulWidget {
  const _OutlookTab();

  @override
  State<_OutlookTab> createState() => _OutlookTabState();
}

class _OutlookTabState extends State<_OutlookTab> {
  _OutlookAuthState _authState = _OutlookAuthState.loading;
  String? _errorMessage;
  String? _connectedEmail;

  @override
  void initState() {
    super.initState();
    _checkConfiguration();
  }

  Future<void> _checkConfiguration() async {
    setState(() {
      _authState = _OutlookAuthState.loading;
    });

    // Microsoft is a public client: only a client ID is needed (the one the
    // user entered, else the one bundled with this build). No secret.
    final clientId = await LoginProviders.outlook.clientId();

    if (!mounted) return;

    if (clientId.isEmpty) {
      setState(() {
        _authState = _OutlookAuthState.configure;
      });
    } else {
      setState(() {
        _authState = _OutlookAuthState.idle;
      });
    }
  }

  Future<void> _connectOutlook() async {
    setState(() {
      _authState = _OutlookAuthState.loading;
      _errorMessage = null;
    });

    try {
      Object? signInError;
      final collection = await LoginProviderExtension.handleOutlookMail(
        context,
        onError: (e) => signInError = e,
      );

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _OutlookAuthState.error;
          _errorMessage =
              signInError == null
                  ? 'Sign-in was cancelled or failed. Please try again.'
                  : _describeOutlookError(signInError!);
        });
        return;
      }

      setState(() {
        _authState = _OutlookAuthState.success;
        _connectedEmail = collection.name;
      });

      EmailPage.selectedCollection.add(collection);
      ScannerManager.getInstance().startScanner(collection);

      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      GoRouter.of(context).go('/email');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authState = _OutlookAuthState.error;
        _errorMessage = _describeOutlookError(e);
      });
    }
  }

  /// Plain-language guidance for known Microsoft 365 problems (admin consent
  /// required, IMAP disabled); the raw error otherwise.
  String _describeOutlookError(Object error) {
    final raw = error.toString();
    return classifyMicrosoftAuthError(raw).message ?? raw;
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: switch (_authState) {
            _OutlookAuthState.loading => _buildLoading(),
            _OutlookAuthState.success => _buildSuccess(),
            _OutlookAuthState.error => _buildError(),
            _OutlookAuthState.idle => _buildIdle(),
            _OutlookAuthState.configure => _buildConfigure(),
          },
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return _cardContainer(
      key: const ValueKey('idle'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.email, size: 72, color: Color(0xFF0078D4)),
          const SizedBox(height: 24),
          const Text(
            'Connect Outlook',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in with your Microsoft account to scan and backup your emails '
            'directly to this app.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          ElevatedButton.icon(
            onPressed: _connectOutlook,
            icon: const Icon(Icons.login, size: 24),
            label: const Text('Sign in with Microsoft'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0078D4),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed:
                () => setState(() => _authState = _OutlookAuthState.configure),
            child: const Text('Use my own Microsoft app (Client ID)'),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return _cardContainer(
      key: const ValueKey('loading'),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 24),
          Text('Connecting to Microsoft...'),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return _cardContainer(
      key: const ValueKey('success'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Successfully Connected!',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Connected as $_connectedEmail',
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return _cardContainer(
      key: const ValueKey('error'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Connection Failed',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _errorMessage ?? 'Unknown error occurred.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed:
                () => setState(() => _authState = _OutlookAuthState.idle),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigure() {
    return _cardContainer(
      key: const ValueKey('configure'),
      child: OutlookConfigureView(onConfigured: _checkConfiguration),
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
