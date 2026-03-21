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
                  Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      children: [
                        SizedBox(
                          width: 225,
                          height: 48,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.email),
                            label: const Text("Login with Yahoo"),
                            onPressed: () async {
                              await handleYahooMail(context, collections);
                              if (context.mounted) {
                                GoRouter.of(context).go("/email");
                                GoRouter.of(context).refresh();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  const _OutlookPstTab(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> handleYahooMail(BuildContext context, List<Collection> collections) async {
    // TODO: Implement actual Yahoo OAuth
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Yahoo Mail login not yet implemented')),
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
            _GmailAuthState.error   => _buildError(),
            _GmailAuthState.idle    => _buildIdle(),
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
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.5),
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
          const Text('Connecting to Gmail…', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
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
          const Text('Gmail Connected!', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          if (_connectedEmail != null) Text(_connectedEmail!, style: const TextStyle(color: Colors.grey)),
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
          const Text('Connection Failed', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          if (_errorMessage != null) Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
          ),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _connectGmail, child: const Text('Try Again')),
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
      if (_form.control('title').value == null || (_form.control('title').value as String).isEmpty) {
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
      final collection = Collection(
        id: collectionId,
        name: title,
        path: filePath, 
        type: 'email',
        scanner: AppConstants.scannerEmailOutlookPst,
        scanStatus: 'pending',
        needsReAuth: false,
      );

      await CollectionRepository().addCollection(collection);

      // Start the one-time scan isolate immediately
      final writerPort = await DatabaseManager.instance.writerPort;
      final serverUrl = MainApp.llmServiceUrl.value;
      if (serverUrl == null) throw Exception('LLM Service url is not configured');

      final pstIsolate = OutlookPstScannerIsolate(
        token: RootIsolateToken.instance,
        dbWriterPort: writerPort,
        appDir: appDataDir,
        serverUrl: serverUrl,
      );
      await pstIsolate.start(collection);

      // Refresh collections
      GetCollectionsService.instance.invoke(GetCollectionsServiceCommand('email'));


      if (!mounted) return;
      GoRouter.of(context).go('/email');
      
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to import PST: $e')),
      );
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(36),
            child: ReactiveForm(
              formGroup: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.archive_outlined, size: 72, color: Colors.orange),
                  const SizedBox(height: 24),
                  const Text(
                    'Outlook PST Archive',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Select an Outlook PST data file to import all emails, folders, and attachments.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.5),
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
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _isImporting
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
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

