import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_configure_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_error_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_idle_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_loading_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_success_view.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/sync_estimate_dialog.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';

/// Sign-in form shared by every OAuth cloud drive (Google Drive, Dropbox, OneDrive...):
/// credentials check -> sign in -> content policy and estimate -> collection.
/// Provider differences live in [CloudAccountBranding] and the two callbacks.

enum _AuthState { idle, checking, loading, success, error, configure }

class CloudAccountForm extends StatefulWidget {
  const CloudAccountForm({
    super.key,
    required this.branding,
    required this.isConfigured,
    required this.connect,
  });

  factory CloudAccountForm.googleDrive() => CloudAccountForm(
    branding: CloudAccountBranding.googleDrive,
    isConfigured: () async {
      final provider = LoginProviders.googleDrive;
      return (await provider.clientId()).isNotEmpty &&
          (await provider.clientSecret()).isNotEmpty;
    },
    connect: LoginProviderExtension.handleGoogleDrive,
  );

  factory CloudAccountForm.dropbox() => CloudAccountForm(
    branding: CloudAccountBranding.dropbox,
    // PKCE-only: just the app key, no secret.
    isConfigured:
        () async => (await LoginProviders.dropbox.clientId()).isNotEmpty,
    connect: LoginProviderExtension.handleDropbox,
  );

  factory CloudAccountForm.oneDrive() => CloudAccountForm(
    branding: CloudAccountBranding.oneDrive,
    // PKCE-only: just the Entra application (client) ID, no secret.
    isConfigured:
        () async => (await LoginProviders.oneDrive.clientId()).isNotEmpty,
    connect: LoginProviderExtension.handleOneDrive,
  );

  final CloudAccountBranding branding;

  /// Whether the OAuth app credentials are already set up.
  final Future<bool> Function() isConfigured;

  /// Runs sign-in and creates the collection (`handleGoogleDrive` /
  /// `handleDropbox` / `handleOneDrive`); null when cancelled or failed.
  final Future<Collection?> Function(
    BuildContext context, {
    ContentPolicy? contentPolicy,
    bool? keepDeletedFiles,
    Future<bool> Function(CloudFileApi api)? confirmSync,
  })
  connect;

  @override
  State<CloudAccountForm> createState() => _CloudAccountFormState();
}

class _CloudAccountFormState extends State<CloudAccountForm> {
  _AuthState _authState = _AuthState.loading;
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
      _authState = _AuthState.checking;
    });

    final configured = await widget.isConfigured();

    if (!mounted) return;

    if (!configured) {
      setState(() {
        _authState = _AuthState.configure;
      });
    } else {
      setState(() {
        _authState = _AuthState.idle;
      });
    }
  }

  Future<void> _connect() async {
    setState(() {
      _authState = _AuthState.loading;
      _errorMessage = null;
    });

    try {
      final collection = await widget.connect(
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
          _authState = _AuthState.error;
          _errorMessage = 'Sign-in was cancelled or failed. Please try again.';
        });
        return;
      }

      ScannerManager.getInstance().startScanner(collection);

      final nameMatch = RegExp(r'\((.+?)\)').firstMatch(collection.name);
      setState(() {
        _authState = _AuthState.success;
        _connectedEmail = nameMatch?.group(1);
      });

      await Future.delayed(const Duration(milliseconds: 900));
      if (!mounted) return;
      GoRouter.of(context).go('/files');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _authState = _AuthState.error;
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
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
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
            _AuthState.checking => const Center(
              key: ValueKey('checking'),
              child: Padding(
                padding: EdgeInsets.all(48),
                child: CircularProgressIndicator(),
              ),
            ),
            _AuthState.loading => _cardContainer(
              key: const ValueKey('loading'),
              child: GoogleDriveLoadingView(branding: widget.branding),
            ),
            _AuthState.success => _cardContainer(
              key: const ValueKey('success'),
              child: GoogleDriveSuccessView(
                connectedEmail: _connectedEmail,
                branding: widget.branding,
              ),
            ),
            _AuthState.error => _cardContainer(
              key: const ValueKey('error'),
              child: GoogleDriveErrorView(
                errorMessage: _errorMessage,
                onRetry: _connect,
              ),
            ),
            _AuthState.configure => _cardContainer(
              key: const ValueKey('configure'),
              child: GoogleDriveConfigureView(
                branding: widget.branding,
                onConfigured: _checkConfiguration,
              ),
            ),
            _AuthState.idle => _cardContainer(
              key: const ValueKey('idle'),
              child: GoogleDriveIdleView(
                branding: widget.branding,
                onConnect: _connect,
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
