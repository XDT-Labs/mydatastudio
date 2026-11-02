import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/step_indicator_widget.dart';

/// Provider-specific instructions for creating an app password.
class AppPasswordHelp {
  const AppPasswordHelp({required this.steps, this.url, this.linkLabel});

  final List<String> steps;
  final Uri? url;
  final String? linkLabel;

  static AppPasswordHelp forProvider(EmailProvider provider) {
    switch (provider.id) {
      case 'yahoo':
        return AppPasswordHelp(
          steps: const [
            'Log in to your Yahoo Account Security settings.',
            'Click "Generate app password".',
            'Select "Other App", name it "mydatastudio", and click Generate.',
            'Copy the 16-character code and paste it below.',
          ],
          url: Uri.parse('https://login.yahoo.com/account/security'),
          linkLabel: 'Open Yahoo Security Settings',
        );
      case 'icloud':
        return AppPasswordHelp(
          steps: const [
            'Sign in to your Apple Account and open Sign-In and Security.',
            'Choose "App-Specific Passwords" and generate one.',
            'Paste it below.',
          ],
          url: Uri.parse('https://account.apple.com/account/manage'),
          linkLabel: 'Open Apple Account',
        );
      default:
        return AppPasswordHelp(
          steps: [
            'Open the security settings of your ${provider.displayName} '
                'account.',
            'Generate an app-specific password for IMAP access.',
            'Paste it below.',
          ],
        );
    }
  }
}

/// The add-account form: address, detected provider (overridable) and the
/// credential fields that provider needs. State lives in the owning tab, which
/// validates on submit.
class ImapIdleView extends StatelessWidget {
  const ImapIdleView({
    super.key,
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.hostController,
    required this.portController,
    required this.usernameController,
    required this.provider,
    required this.security,
    required this.showProviderSection,
    required this.onEmailChanged,
    required this.onProviderChanged,
    required this.onSecurityChanged,
    required this.onSubmit,
    required this.onContinueOAuth,
    required this.onOpenHelpUrl,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController hostController;
  final TextEditingController portController;
  final TextEditingController usernameController;
  final EmailProvider provider;
  final ImapSecurity security;

  /// False until the user has typed an address (or picked a provider), so the
  /// first screen is just the address field.
  final bool showProviderSection;
  final ValueChanged<String> onEmailChanged;
  final ValueChanged<EmailProvider> onProviderChanged;
  final ValueChanged<ImapSecurity> onSecurityChanged;
  final VoidCallback onSubmit;
  final VoidCallback onContinueOAuth;
  final ValueChanged<Uri> onOpenHelpUrl;

  /// A local part, an `@`, and a dotted domain. Deliberately loose — the
  /// address is proved by the IMAP login that follows, not by this.
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String _securityLabel(ImapSecurity s) => switch (s) {
    ImapSecurity.ssl => 'SSL/TLS',
    ImapSecurity.startTls => 'STARTTLS',
    ImapSecurity.none => 'None',
  };

  InputDecoration _decoration(String label, {String? hint, IconData? icon}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon != null ? Icon(icon) : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );

  @override
  Widget build(BuildContext context) {
    final isOther = provider.id == EmailProviderRegistry.other.id;
    final isOAuth = provider.authType == EmailAuthType.oauth2;
    final isAppPassword = provider.authType == EmailAuthType.appPassword;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Form(
        key: formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: Icon(Icons.email, size: 64)),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'Connect an email account',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Enter your address and we will work out the rest. Works with '
                'Yahoo, Outlook, iCloud, AOL, Fastmail and any IMAP server.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, height: 1.5),
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              key: const Key('email-field'),
              controller: emailController,
              onChanged: onEmailChanged,
              keyboardType: TextInputType.emailAddress,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Email is required';
                }
                return _emailPattern.hasMatch(value)
                    ? null
                    : 'Enter a valid email address';
              },
              decoration: _decoration(
                'Email Address',
                hint: 'yourname@example.com',
                icon: Icons.alternate_email,
              ),
            ),
            if (showProviderSection) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('provider-dropdown'),
                initialValue: provider.id,
                decoration: _decoration('Provider'),
                items: [
                  for (final p in EmailProviderRegistry.all)
                    DropdownMenuItem(
                      value: p.id,
                      child: Text(
                        p.id == EmailProviderRegistry.other.id
                            ? 'Other (IMAP)'
                            : p.displayName,
                      ),
                    ),
                ],
                onChanged: (id) {
                  final next =
                      id == null ? null : EmailProviderRegistry.byId(id);
                  if (next != null) onProviderChanged(next);
                },
              ),
              const SizedBox(height: 16),
              if (isOAuth) ...[
                Text(
                  'Sign in with ${provider.displayName} to connect this '
                  'account. No password is stored.',
                  style: TextStyle(color: Colors.grey.shade600, height: 1.5),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    key: const Key('continue-oauth-button'),
                    onPressed: onContinueOAuth,
                    icon: const Icon(Icons.login),
                    label: Text('Continue with ${provider.displayName}'),
                  ),
                ),
              ] else ...[
                if (isAppPassword) ..._buildHelp(context),
                if (isOther) ..._buildServerFields(),
                TextFormField(
                  key: const Key('password-field'),
                  controller: passwordController,
                  obscureText: true,
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return isAppPassword
                          ? 'App password is required'
                          : 'Password is required';
                    }
                    if (provider.id == 'yahoo' && value.length < 16) {
                      return 'App password should be 16 characters';
                    }
                    return null;
                  },
                  decoration: _decoration(
                    isAppPassword ? 'App Password' : 'Password',
                    icon: Icons.lock_outline,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    key: const Key('submit-button'),
                    onPressed: onSubmit,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text(
                      'Test & Connect',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHelp(BuildContext context) {
    final help = AppPasswordHelp.forProvider(provider);
    return [
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
            for (var i = 0; i < help.steps.length; i++)
              StepIndicatorWidget(number: i + 1, text: help.steps[i]),
            if (help.url != null) ...[
              const SizedBox(height: 12),
              Center(
                child: TextButton.icon(
                  onPressed: () => onOpenHelpUrl(help.url!),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(help.linkLabel ?? 'Open settings'),
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _buildServerFields() {
    return [
      TextFormField(
        key: const Key('host-field'),
        controller: hostController,
        validator:
            (v) =>
                (v == null || v.trim().isEmpty)
                    ? 'IMAP server is required'
                    : null,
        decoration: _decoration(
          'IMAP Server',
          hint: 'imap.example.com',
          icon: Icons.dns_outlined,
        ),
      ),
      const SizedBox(height: 16),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              key: const Key('port-field'),
              controller: portController,
              keyboardType: TextInputType.number,
              validator: (v) {
                final port = int.tryParse(v ?? '');
                return (port == null || port < 1 || port > 65535)
                    ? 'Invalid port'
                    : null;
              },
              decoration: _decoration('Port'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<ImapSecurity>(
              key: const Key('security-dropdown'),
              initialValue: security,
              decoration: _decoration('Security'),
              items: [
                for (final s in ImapSecurity.values)
                  DropdownMenuItem(value: s, child: Text(_securityLabel(s))),
              ],
              onChanged: (s) {
                if (s != null) onSecurityChanged(s);
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const Key('username-field'),
        controller: usernameController,
        decoration: _decoration(
          'Username',
          hint: 'Defaults to your email address',
          icon: Icons.person_outline,
        ),
      ),
      const SizedBox(height: 16),
    ];
  }
}
