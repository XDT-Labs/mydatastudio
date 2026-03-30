// Copyright 2019 The Flutter team. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/login_providers.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:go_router/go_router.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_idle_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_loading_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_success_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_error_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_idle_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_loading_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_success_view.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_error_view.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
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

  @override
  Widget build(BuildContext context) {
    //final textTheme = Theme.of(context).textTheme;
    //final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: SizedBox.expand(
          child: DefaultTabController(
            length: 4,
            child: Scaffold(
              appBar: AppBar(
                toolbarHeight: 0,
                bottom: const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.email), text: 'Gmail'),
                    Tab(icon: Icon(Icons.email), text: 'Yahoo Mail'),
                    Tab(icon: Icon(Icons.email), text: 'Outlook'),
                    Tab(icon: Icon(Icons.email), text: 'Outlook PST'),
                  ],
                ),
              ),
              body: TabBarView(
                children: [
                  const _GmailTab(),
                  const _YahooTab(),
                  const _OutlookTab(),
                  const _OutlookPstTab(),
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
// Gmail Tab — stateful OAuth flow mirroring Google Drive
// =============================================================================

enum _GmailAuthState { idle, loading, success, error }

class _GmailTab extends StatefulWidget {
  const _GmailTab();

  @override
  State<_GmailTab> createState() => _GmailTabState();
}

class _GmailTabState extends State<_GmailTab> {
  _GmailAuthState _authState = _GmailAuthState.idle;
  String? _errorMessage;
  String? _connectedEmail;

  Future<void> _connectGmail() async {
    setState(() {
      _authState = _GmailAuthState.loading;
      _errorMessage = null;
    });

    try {
      final collection = await LoginProviderExtension.handleGoogleMail(context);

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _GmailAuthState.error;
          _errorMessage = 'Sign-in was cancelled or failed. Please try again.';
        });
        return;
      }

      setState(() {
        _authState = _GmailAuthState.success;
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
        _authState = _GmailAuthState.error;
        _errorMessage = e.toString();
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
          child: switch (_authState) {
            _GmailAuthState.loading => _buildLoading(),
            _GmailAuthState.success => _buildSuccess(),
            _GmailAuthState.error => _buildError(),
            _GmailAuthState.idle => _buildIdle(),
          },
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return _cardContainer(
      key: const ValueKey('idle'),
      child: GmailIdleView(onConnect: _connectGmail),
    );
  }

  Widget _buildLoading() {
    return _cardContainer(
      key: const ValueKey('loading'),
      child: const GmailLoadingView(),
    );
  }

  Widget _buildSuccess() {
    return _cardContainer(
      key: const ValueKey('success'),
      child: GmailSuccessView(connectedEmail: _connectedEmail),
    );
  }

  Widget _buildError() {
    return _cardContainer(
      key: const ValueKey('error'),
      child: GmailErrorView(
        errorMessage: _errorMessage,
        onRetry: _connectGmail,
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

// =============================================================================
// Outlook PST Tab — browser for a local .pst file
// =============================================================================

class _OutlookPstTab extends StatefulWidget {
  const _OutlookPstTab();

  @override
  State<_OutlookPstTab> createState() => _OutlookPstTabState();
}

class _OutlookPstTabState extends State<_OutlookPstTab> {
  final _form = FormGroup({
    'title': FormControl<String>(validators: [Validators.required]),
    'file': FormControl<String>(validators: [Validators.required]),
  });

  bool _isImporting = false;

  Future<void> _browse() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pst'],
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      final filePath = result.files.single.path!;
      _form.control('file').value = filePath;

      // Auto-populate title if empty
      if (_form.control('title').value == null ||
          (_form.control('title').value as String).isEmpty) {
        _form.control('title').value = p.basenameWithoutExtension(filePath);
      }
    }
  }

  Future<void> _import() async {
    if (!_form.valid) {
      _form.markAllAsTouched();
      return;
    }

    setState(() => _isImporting = true);

    try {
      final filePath = _form.control('file').value as String;
      final title = _form.control('title').value as String;

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

      await CollectionRepository().addCollection(collection);

      // Start the one-time scan isolate immediately
      final writerPort = await DatabaseManager.instance.writerPort;
      final serverUrl = MainApp.llmServiceUrl.valueOrNull;
      if (serverUrl == null) {
        throw Exception('LLM Service url is not configured');
      }

      final pstIsolate = OutlookPstScannerIsolate(
        token: RootIsolateToken.instance,
        dbWriterPort: writerPort,
        appDir: appDataDir,
        serverUrl: serverUrl,
      );
      await pstIsolate.start(collection);

      // Refresh collections
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand('email'),
      );

      if (!mounted) return;
      GoRouter.of(context).go('/email');
    } catch (e) {
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
            child: ReactiveForm(
              formGroup: _form,
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
                  ReactiveTextField<String>(
                    formControlName: 'title',
                    decoration: const InputDecoration(
                      labelText: 'Collection Title',
                      hintText: 'e.g., My Old Emails',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ReactiveTextField<String>(
                    formControlName: 'file',
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'PST File Path',
                      hintText: 'No file selected',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
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
// Yahoo Tab — stateful OAuth flow
// =============================================================================

enum _YahooAuthState { idle, loading, success, error }

class _YahooTab extends StatefulWidget {
  const _YahooTab();

  @override
  State<_YahooTab> createState() => _YahooTabState();
}

class _YahooTabState extends State<_YahooTab> {
  _YahooAuthState _authState = _YahooAuthState.idle;
  String? _errorMessage;
  String? _connectedEmail;

  final _form = FormGroup({
    'email': FormControl<String>(
      validators: [Validators.required, Validators.email],
    ),
    'appPassword': FormControl<String>(
      validators: [Validators.required, Validators.minLength(16)],
    ),
  });

  Future<void> _connectYahoo() async {
    if (!_form.valid) {
      _form.markAllAsTouched();
      return;
    }

    setState(() {
      _authState = _YahooAuthState.loading;
      _errorMessage = null;
    });

    try {
      final email = _form.control('email').value as String;
      final appPassword = _form.control('appPassword').value as String;

      // Create collection manually (App Password approach)
      final collectionId = const Uuid().v4();
      final appDataDir = MainApp.appDataDirectory.valueOrNull;
      final extractionRoot =
          appDataDir != null
              ? p.join(appDataDir, 'files', 'email', collectionId)
              : null;
      final c = Collection(
        id: collectionId,
        name: email,
        path: email, // Root path for IMAP scanner
        localCopyPath: extractionRoot,
        type: 'email',
        scanner: AppConstants.scannerEmailYahoo,
        scanStatus: 'idle',
        oauthService: 'yahoo_app_password',
        accessToken: appPassword, // Store app password in accessToken field
        userId: email,
        needsReAuth: false,
        downloadLocalCopy: true,
      );

      GetCollectionsService.instance.addCollection(c);
      ScannerManager.getInstance().startScanner(c);

      if (!mounted) return;

      setState(() {
        _authState = _YahooAuthState.success;
        _connectedEmail = email;
      });

      EmailPage.selectedCollection.add(c);

      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      GoRouter.of(context).go('/email');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authState = _YahooAuthState.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _launchYahooSecurity() async {
    final url = Uri.parse('https://login.yahoo.com/account/security');
    if (!await launchUrl(url)) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Could not open browser')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: switch (_authState) {
            _YahooAuthState.loading => _buildLoading(),
            _YahooAuthState.success => _buildSuccess(),
            _YahooAuthState.error => _buildError(),
            _YahooAuthState.idle => _buildIdle(),
          },
        ),
      ),
    );
  }

  Widget _buildIdle() {
    return _cardContainer(
      key: const ValueKey('idle'),
      child: YahooIdleView(
        form: _form,
        onConnect: _connectYahoo,
        onLaunchSecurity: _launchYahooSecurity,
      ),
    );
  }

  Widget _buildLoading() {
    return _cardContainer(
      key: const ValueKey('loading'),
      child: const YahooLoadingView(),
    );
  }

  Widget _buildSuccess() {
    return _cardContainer(
      key: const ValueKey('success'),
      child: YahooSuccessView(connectedEmail: _connectedEmail),
    );
  }

  Widget _buildError() {
    return _cardContainer(
      key: const ValueKey('error'),
      child: YahooErrorView(
        errorMessage: _errorMessage,
        onRetry: () => setState(() => _authState = _YahooAuthState.idle),
      ),
    );
  }

  Widget _cardContainer({required Widget child, required Key key}) {
    return Card(
      key: key,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    );
  }
}

// =============================================================================
// Outlook Tab — stateful OAuth flow
// =============================================================================

enum _OutlookAuthState { idle, loading, success, error }

class _OutlookTab extends StatefulWidget {
  const _OutlookTab();

  @override
  State<_OutlookTab> createState() => _OutlookTabState();
}

class _OutlookTabState extends State<_OutlookTab> {
  _OutlookAuthState _authState = _OutlookAuthState.idle;
  String? _errorMessage;
  String? _connectedEmail;

  Future<void> _connectOutlook() async {
    setState(() {
      _authState = _OutlookAuthState.loading;
      _errorMessage = null;
    });

    try {
      final collection = await LoginProviderExtension.handleOutlookMail(context);

      if (!mounted) return;

      if (collection == null) {
        setState(() {
          _authState = _OutlookAuthState.error;
          _errorMessage = 'Sign-in was cancelled or failed. Please try again.';
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
        _errorMessage = e.toString();
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
          child: switch (_authState) {
            _OutlookAuthState.loading => _buildLoading(),
            _OutlookAuthState.success => _buildSuccess(),
            _OutlookAuthState.error => _buildError(),
            _OutlookAuthState.idle => _buildIdle(),
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
            onPressed: () => setState(() => _authState = _OutlookAuthState.idle),
            child: const Text('Try Again'),
          ),
        ],
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
