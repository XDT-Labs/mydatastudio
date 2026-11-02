import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_sign_in_button.dart';

/// Everything that differs between cloud-drive providers in the sign-in form:
/// wording, logo, sign-in button and how the OAuth app credentials are asked
/// for. The form widgets default to [googleDrive], so adding a provider means
/// adding one instance here.
class CloudAccountBranding {
  const CloudAccountBranding({
    required this.name,
    required this.logo,
    required this.intro,
    required this.accessNote,
    required this.keepDeletedLabel,
    required this.scanningNote,
    required this.signInButton,
    required this.service,
    required this.requiresSecret,
    required this.credentialsUrl,
    required this.credentialsLinkText,
    required this.configureIntro,
    this.idLabel = 'Client ID',
  });

  /// Display name, e.g. "Google Drive".
  final String name;
  final Widget logo;

  /// Idle-view paragraph under the title.
  final String intro;

  /// Short note about the access the app asks for.
  final String accessNote;
  final String keepDeletedLabel;
  final String scanningNote;
  final Widget Function(VoidCallback onTap) signInButton;

  /// `providers.service` row holding this provider's OAuth app credentials.
  final String service;

  /// False for PKCE-only providers: no client secret is asked for or stored.
  final bool requiresSecret;
  final String credentialsUrl;
  final String credentialsLinkText;
  final String configureIntro;

  /// Label of the OAuth client id field ("App key" for Dropbox).
  final String idLabel;

  static final googleDrive = CloudAccountBranding(
    name: 'Google Drive',
    logo: Image.asset('assets/images/google-drive.png', height: 72),
    intro:
        'Sign in with your Google account to scan and browse your Drive '
        'files directly from this app.',
    accessNote:
        'Requires full Drive access to list, download, and delete files.',
    keepDeletedLabel: 'Keep files deleted from Google Drive',
    scanningNote: 'Scanning your Drive in the background…',
    signInButton: (onTap) => GoogleDriveSignInButton(onTap: onTap),
    service: 'google',
    requiresSecret: true,
    credentialsUrl: 'https://console.cloud.google.com/apis/credentials',
    credentialsLinkText: 'Get Credentials from Google Cloud Console',
    configureIntro:
        'To connect to Google Drive, you must provide your own OAuth Client ID and Secret.',
  );

  static final dropbox = CloudAccountBranding(
    name: 'Dropbox',
    logo: const Icon(Icons.cloud_queue, size: 72, color: Color(0xFF0061FF)),
    intro:
        'Sign in with your Dropbox account to scan and browse your files '
        'directly from this app.',
    accessNote:
        'Read-only access: this app can never change or delete your files.',
    keepDeletedLabel: 'Keep files deleted from Dropbox',
    scanningNote: 'Scanning your Dropbox in the background…',
    signInButton:
        (onTap) => ElevatedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.cloud_queue, size: 18),
          label: const Text('Sign in with Dropbox'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0061FF),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
    service: 'dropbox',
    requiresSecret: false,
    credentialsUrl: 'https://www.dropbox.com/developers/apps',
    credentialsLinkText: 'Create an app in the Dropbox App Console',
    configureIntro:
        'To connect to Dropbox, create a Dropbox app (Scoped access, Full Dropbox, '
        'read-only scopes, redirect URI http://localhost:53134/auth) and enter '
        'its App key. No secret is needed.',
    idLabel: 'App key',
  );

  static final oneDrive = CloudAccountBranding(
    name: 'OneDrive',
    logo: const Icon(
      Icons.cloud_circle_outlined,
      size: 72,
      color: Color(0xFF0078D4),
    ),
    intro:
        'Sign in with your Microsoft account (personal or work/school) to scan '
        'and browse your OneDrive files directly from this app.',
    accessNote:
        'Read-only access: this app can never change or delete your files. '
        "Personal Vault isn't readable by apps.",
    keepDeletedLabel: 'Keep files deleted from OneDrive',
    scanningNote: 'Scanning your OneDrive in the background…',
    signInButton:
        (onTap) => ElevatedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.cloud_circle_outlined, size: 18),
          label: const Text('Sign in with Microsoft'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0078D4),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
    // Shares the Microsoft (Entra) app row with Outlook mail.
    service: 'azure',
    requiresSecret: false,
    credentialsUrl:
        'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade',
    credentialsLinkText: 'Register an app in the Microsoft Entra admin center',
    configureIntro:
        'To connect to OneDrive, register a Microsoft Entra app as a public '
        'client (accounts in any organization and personal accounts, redirect '
        'URI http://localhost/auth, delegated Files.Read, User.Read and '
        'offline_access) and enter its Application (client) ID. No secret is '
        'needed.',
    idLabel: 'Application (client) ID',
  );
}
