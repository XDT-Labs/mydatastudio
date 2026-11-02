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
  String? _errorMessage;
  String? _connectedEmail;

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
      }
    });
  }

  void _onProviderChanged(EmailProvider provider) {
    setState(() {
      _provider = provider;
      _providerOverridden = true;
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

  ImapConnectionRequest _buildRequest(String email, String username) {
    final isOther = _provider.id == EmailProviderRegistry.other.id;
    return ImapConnectionRequest(
      host: isOther ? _host.text.trim() : _provider.imapHost!,
      port: isOther ? int.parse(_port.text.trim()) : _provider.imapPort,
      security: isOther ? _security : _provider.security,
      username: username,
      password: _password.text,
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
    });

    try {
      final result = await widget.connectionTester.test(request);
      if (!mounted) return;
      if (!result.ok) {
        setState(() {
          _state = _SetupState.error;
          _errorMessage = result.message;
        });
        return;
      }

      final collection = buildImapCollection(
        provider: _provider,
        email: email,
        username: username,
        password: request.password,
        settings:
            isOther
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _SetupState.error;
        _errorMessage = e.toString();
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
                onRetry: () => setState(() => _state = _SetupState.idle),
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
                showProviderSection:
                    _providerOverridden || _email.text.contains('@'),
                onEmailChanged: _onEmailChanged,
                onProviderChanged: _onProviderChanged,
                onSecurityChanged: _onSecurityChanged,
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
