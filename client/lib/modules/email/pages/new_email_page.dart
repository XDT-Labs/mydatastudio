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
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:mydatatools/modules/email/pages/email_page.dart';
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
            length: 3,
            child: Scaffold(
              appBar: AppBar(
                toolbarHeight: 0,
                bottom: const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.email), text: 'Gmail'),
                    Tab(icon: Icon(Icons.email), text: 'Yahoo Mail'),
                    Tab(icon: Icon(Icons.email), text: 'Outlook PST'),
                  ],
                ),
              ),
              body: TabBarView(
                children: [
                  const _GmailTab(),
                  const _YahooTab(),
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

  static const Color _googleBlue = Color(0xFF4285F4);

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
    return _buildCard(
      key: const ValueKey('idle'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.email, size: 72, color: _googleBlue),
          const SizedBox(height: 24),
          const Text(
            'Connect Gmail',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Sign in with your Google account to scan and backup your emails '
            'directly to this app.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 28),
          _buildGoogleSignInButton(),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return _buildCard(
      key: const ValueKey('loading'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 20),
          const Text(
            'Connecting to Gmail…',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return _buildCard(
      key: const ValueKey('success'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 64),
          const SizedBox(height: 20),
          const Text(
            'Gmail Connected!',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_connectedEmail != null)
            Text(_connectedEmail!, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return _buildCard(
      key: const ValueKey('error'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error, color: Colors.red, size: 64),
          const SizedBox(height: 20),
          const Text(
            'Connection Failed',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _connectGmail,
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child, required Key key}) {
    return Card(
      key: key,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(36), child: child),
    );
  }

  Widget _buildGoogleSignInButton() {
    return ElevatedButton.icon(
      onPressed: _connectGmail,
      icon: const FaIcon(FontAwesomeIcons.google, size: 18, color: _googleBlue),
      label: const Text('Sign in with Google'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Colors.grey.shade300),
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
      final serverUrl = MainApp.llmServiceUrl.value;
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

  static const Color _yahooPurple = Color(0xFF6001D2);

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
        downloadAttachments: true,
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: _buildCard(
        key: const ValueKey('idle'),
        child: ReactiveForm(
          formGroup: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Icon(Icons.email, size: 64, color: _yahooPurple),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text(
                  'Connect Yahoo Mail',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Setup Instructions',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildStep(
                      1,
                      'Log in to your Yahoo Account Security settings.',
                    ),
                    _buildStep(2, 'Click "Generate app password".'),
                    _buildStep(
                      3,
                      'Select "Other App", name it "MyDataTools", and click Generate.',
                    ),
                    _buildStep(
                      4,
                      'Copy the 16-character code and paste it below.',
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: TextButton.icon(
                        onPressed: _launchYahooSecurity,
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('Open Yahoo Security Settings'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Email Address',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              ReactiveTextField<String>(
                formControlName: 'email',
                decoration: InputDecoration(
                  hintText: 'yourname@yahoo.com',
                  prefixIcon: const Icon(Icons.alternate_email),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'App Password',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              ReactiveTextField<String>(
                formControlName: 'appPassword',
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'Enter 16-character app password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                validationMessages: {
                  'required': (error) => 'App password is required',
                  'minLength':
                      (error) => 'App password should be 16 characters',
                },
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _connectYahoo,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _yahooPurple,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text(
                    'Connect Yahoo Account',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep(int number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number. ',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: _yahooPurple,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoading() {
    return _buildCard(
      key: const ValueKey('loading'),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: _yahooPurple),
          SizedBox(height: 20),
          Text(
            'Verifying connection…',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess() {
    return _buildCard(
      key: const ValueKey('success'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 64),
          const SizedBox(height: 20),
          const Text(
            'Account Connected!',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_connectedEmail != null)
            Text(_connectedEmail!, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _buildError() {
    return _buildCard(
      key: const ValueKey('error'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error, color: Colors.red, size: 64),
          const SizedBox(height: 20),
          const Text(
            'Setup Failed',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => setState(() => _authState = _YahooAuthState.idle),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({required Widget child, required Key key}) {
    return Card(
      key: key,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    );
  }
}
