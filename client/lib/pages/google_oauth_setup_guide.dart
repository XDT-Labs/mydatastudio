import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

/// Step-by-step instructions for creating the Google OAuth client that Google
/// Drive signs in with. Each user creates their own: the app is then used
/// under Google's personal-use exception, with no app verification or
/// security assessment.
///
/// Collapsed by default because it is long; [initiallyExpanded] opens it when
/// the user arrives from the Add Source page to set Drive up.
class GoogleOAuthSetupGuide extends StatelessWidget {
  const GoogleOAuthSetupGuide({super.key, this.initiallyExpanded = false});

  final bool initiallyExpanded;

  /// Scopes the Google Drive connection requests (LoginProviders.googleDrive).
  static const scopes = [
    'https://www.googleapis.com/auth/drive',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
  ];

  static final _steps = <_Step>[
    _Step(
      'Create a Google Cloud project',
      'Sign in to Google Cloud Console with your Google account, choose New '
          'project, give it a name (for example "My Data Studio") and click '
          'Create. Make sure the new project is selected in the project picker '
          'at the top of the page before continuing.',
      link: (
        'Create a project',
        'https://console.cloud.google.com/projectcreate',
      ),
    ),
    _Step(
      'Enable the Google Drive API',
      'Open the Google Drive API page in the API Library and click Enable.',
      link: (
        'Google Drive API',
        'https://console.cloud.google.com/apis/library/drive.googleapis.com',
      ),
    ),
    _Step(
      'Set up the Google Auth Platform',
      'In the console menu open Google Auth Platform and click Get started. '
          'Enter an app name and your email as the support email. For '
          'Audience choose External (choose Internal only if your account is '
          'part of a Google Workspace organization and only its members will '
          'use it). Enter your email as the contact, accept the policy and '
          'click Create.',
    ),
    _Step(
      'Add the Drive scopes',
      'In Google Auth Platform open Data Access, click Add or remove scopes, '
          'and add the three scopes below (paste them into "Manually add '
          'scopes" if they are hard to find). Click Update, then Save.',
      showScopes: true,
    ),
    _Step(
      'Publish the app (important)',
      'In Google Auth Platform open Audience and click Publish app, then '
          'Confirm. While the app is in Testing, Google signs you out of Drive '
          'every 7 days. You do not need to submit the app for verification: '
          'an app used only by you (fewer than 100 users) falls under '
          "Google's personal-use exception.",
    ),
    _Step(
      'Create the OAuth client',
      'In Google Auth Platform open Clients and click Create client. Choose '
          'Application type: Desktop app, give it a name and click Create. You '
          'do not need to add a redirect URI.',
      link: ('Clients', 'https://console.cloud.google.com/auth/clients'),
    ),
    _Step(
      'Copy the Client ID and Client Secret',
      'Copy both values from the dialog (or download the JSON file and keep '
          'it somewhere safe), then paste them into the fields below. They '
          'are saved automatically.',
    ),
    _Step(
      'Sign in to Google Drive',
      'In Files, click the + (Add Source) button and choose Google Drive. '
          'Google will warn that it '
          "hasn't verified this app, because the app is yours and unreviewed. "
          'Click Advanced, then Go to (your app name). On the next screen, '
          'tick the Google Drive permission before clicking Continue: without '
          'it the app cannot read your files.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: const ValueKey('google-oauth-setup-guide'),
      initiallyExpanded: initiallyExpanded,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      title: const Text('How to create your own Google OAuth client'),
      subtitle: Text(
        'Google Drive needs a Client ID and Secret from your own Google Cloud '
        'project. It takes about 10 minutes and is free.',
        style: theme.textTheme.bodySmall,
      ),
      children: [
        for (final (i, step) in _steps.indexed)
          _StepView(number: i + 1, step: step),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _Link(
            'Google Auth Platform help',
            'https://support.google.com/cloud/answer/15544987',
          ),
        ),
      ],
    );
  }
}

class _Step {
  const _Step(this.title, this.body, {this.link, this.showScopes = false});

  final String title;
  final String body;
  final (String, String)? link;
  final bool showScopes;
}

class _StepView extends StatelessWidget {
  const _StepView({required this.number, required this.step});

  final int number;
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$number.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  step.title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(step.body, style: const TextStyle(height: 1.4)),
                if (step.showScopes) ...[
                  const SizedBox(height: 6),
                  for (final s in GoogleOAuthSetupGuide.scopes)
                    SelectableText(
                      s,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                ],
                if (step.link case (final label, final url)) ...[
                  const SizedBox(height: 4),
                  _Link(label, url),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, this.url);

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      link: true,
      child: InkWell(
        onTap: () => launchUrl(Uri.parse(url)),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.blue,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}
