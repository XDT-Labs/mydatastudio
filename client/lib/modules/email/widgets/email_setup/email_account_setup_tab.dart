import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_collection_factory.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_connection_tester.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_error_view.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_idle_view.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_loading_view.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_success_view.dart';

enum _SetupState { idle, loading, success, error, oauth }

/// One add-account flow for every IMAP mailbox: detects the provider from the
/// address, asks for what that provider needs, proves the login works, then
/// hands the collection to [onAccountCreated].
///
/// Side effects (saving, starting the scanner, OAuth, navigation) are injected
/// so the flow can be tested without a database or network.
class EmailAccountSetupTab extends StatefulWidget {
  const EmailAccountSetupTab({
    super.key,
    required this.connectionTester,
    required this.appDataDirectory,
    required this.onAccountCreated,
    required this.onDone,
    required this.oauthBuilder,
    required this.onOpenUrl,
    this.successDelay = const Duration(milliseconds: 900),
  });

  final ImapConnectionTester connectionTester;
  final String? Function() appDataDirectory;

  /// Persist the collection and start syncing it.
  final Future<void> Function(Collection collection) onAccountCreated;

  /// Called after the success view has been shown.
  final void Function(BuildContext context) onDone;

  /// Content for OAuth providers (Outlook; Gmail points at its own tab).
  final Widget Function(BuildContext context, EmailProvider provider)
  oauthBuilder;
  final Future<void> Function(Uri url) onOpenUrl;
  final Duration successDelay;

  @override
  State<EmailAccountSetupTab> createState() => _EmailAccountSetupTabState();
}

class _EmailAccountSetupTabState extends State<EmailAccountSetupTab> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '993');
  final _username = TextEditingController();

  _SetupState _state = _SetupState.idle;
  EmailProvider _provider = EmailProviderRegistry.other;
  ImapSecurity _security = ImapSecurity.ssl;
  bool _providerOverridden = false;
  String? _regionHost;
  String? _errorMessage;
  String? _authHint;
  String? _connectedEmail;

  /// What the last failed test was run with, kept so a Yandex account whose
  /// new app password is not active yet can be saved anyway.
  ImapConnectionRequest? _failedRequest;
  String? _failedEmail;
  bool _failedWithBadCredentials = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    super.dispose();
  }

  void _onEmailChanged(String value) {
    setState(() {
      if (!_providerOverridden) {
        _provider = EmailProviderRegistry.detectFromEmail(value);
        _regionHost = null;
      }
    });
  }

  void _onProviderChanged(EmailProvider provider) {
    setState(() {
      _provider = provider;
      _providerOverridden = true;
      _regionHost = null;
    });
  }

  void _onSecurityChanged(ImapSecurity security) {
    setState(() {
      _security = security;
      // Follow the conventional port unless the user typed a custom one.
      final current = _port.text.trim();
      if (current == '993' || current == '143' || current.isEmpty) {
        _port.text = security == ImapSecurity.ssl ? '993' : '143';
      }
    });
  }

  void _onRegionChanged(String host) => setState(() => _regionHost = host);

  /// The host the provider is reached at: the user's region pick for providers
  /// with regions, otherwise the registry default.
  String get _providerHost =>
      _provider.regionHosts.containsValue(_regionHost)
          ? _regionHost!
          : _provider.imapHost!;

  ImapConnectionRequest _buildRequest(String email, String username) {
    final isOther = _provider.id == EmailProviderRegistry.other.id;
    return ImapConnectionRequest(
      host: isOther ? _host.text.trim() : _providerHost,
      port: isOther ? int.parse(_port.text.trim()) : _provider.imapPort,
      security: isOther ? _security : _provider.security,
      username: username,
      password: _password.text,
      providerId: _provider.id,
    );
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final email = _email.text.trim();
    final isOther = _provider.id == EmailProviderRegistry.other.id;
    final username =
        isOther && _username.text.trim().isNotEmpty
            ? _username.text.trim()
            : email;
    final request = _buildRequest(email, username);

    setState(() {
      _state = _SetupState.loading;
      _errorMessage = null;
      _authHint = null;
      _failedWithBadCredentials = false;
    });

    try {
      final result = await widget.connectionTester.test(request);
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _failedRequest = request;
          _failedEmail = email;
          _failedWithBadCredentials =
              result.failure == ImapConnectionFailure.badCredentials;
          _state = _SetupState.error;
          _errorMessage = result.message;
          if (result.failure == ImapConnectionFailure.badCredentials) {
            _authHint = _provider.authFailureHint;
          }
        });
        return;
      }

      await _saveAccount(
        request,
        email,
        result.resolvedUsername ?? username,
      );
      if (!mounted) return;

    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _SetupState.error;
        _errorMessage = e.toString();
        _failedWithBadCredentials = false;
      });
    }
  }

  /// Saves the account, shows the success view, then leaves the flow.
  Future<void> _saveAccount(
    ImapConnectionRequest request,
    String email,
    String username,
  ) async {
    final isOther = _provider.id == EmailProviderRegistry.other.id;
    final collection = buildImapCollection(
      provider: _provider,
      email: email,
      username: username,
      password: request.password,
      settings:
          isOther || _provider.regionHosts.isNotEmpty
              ? ImapSettings(
                host: request.host,
                port: request.port,
                security: request.security,
                username: username,
              )
              : null,
      appDataDir: widget.appDataDirectory(),
    );
    await widget.onAccountCreated(collection);
    if (!mounted) return;

    setState(() {
      _state = _SetupState.success;
      _connectedEmail = email;
    });

    await Future.delayed(widget.successDelay);
    if (!mounted) return;
    widget.onDone(context);
  }

  /// Yandex only: a new app password can take hours to activate, so save the
  /// account anyway and let the scanner's retry window pick it up.
  Future<void> _saveAndRetryAutomatically() async {
    final request = _failedRequest;
    final email = _failedEmail;
    if (request == null || email == null) return;
    try {
      await _saveAccount(request, email, request.username);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _SetupState.error;
        _errorMessage = e.toString();
        _failedWithBadCredentials = false;
      });
    }
  }

  Future<void> _openUrl(Uri url) async {
    try {
      await widget.onOpenUrl(url);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open browser')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _SetupState.oauth) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton.icon(
                onPressed: () => setState(() => _state = _SetupState.idle),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Back'),
              ),
            ),
          ),
          Expanded(child: widget.oauthBuilder(context, _provider)),
        ],
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          child: switch (_state) {
            _SetupState.loading => _card(
              const ValueKey('loading'),
              const ImapLoadingView(),
            ),
            _SetupState.success => _card(
              const ValueKey('success'),
              ImapSuccessView(connectedEmail: _connectedEmail),
            ),
            _SetupState.error => _card(
              const ValueKey('error'),
              ImapErrorView(
                errorMessage: _errorMessage,
                hint: _authHint,
                onRetry: () => setState(() => _state = _SetupState.idle),
                secondaryActionLabel:
                    _provider.id == 'yandex' && _failedWithBadCredentials
                        ? 'Save and retry automatically'
                        : null,
                onSecondaryAction: _saveAndRetryAutomatically,
              ),
            ),
            _ => _card(
              const ValueKey('idle'),
              ImapIdleView(
                formKey: _formKey,
                emailController: _email,
                passwordController: _password,
                hostController: _host,
                portController: _port,
                usernameController: _username,
                provider: _provider,
                security: _security,
                regionHost: _regionHost,
                showProviderSection:
                    _providerOverridden || _email.text.contains('@'),
                onEmailChanged: _onEmailChanged,
                onProviderChanged: _onProviderChanged,
                onSecurityChanged: _onSecurityChanged,
                onRegionChanged: _onRegionChanged,
                onSubmit: _submit,
                onContinueOAuth:
                    () => setState(() => _state = _SetupState.oauth),
                onOpenHelpUrl: _openUrl,
              ),
            ),
          },
        ),
      ),
    );
  }

  Widget _card(Key key, Widget child) {
    return Card(
      key: key,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(padding: const EdgeInsets.all(32), child: child),
    );
  }
}
