import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';
import 'package:mydatastudio/services/credential_codec.dart';

import 'package:url_launcher/url_launcher.dart';

class GoogleDriveConfigureView extends StatefulWidget {
  final VoidCallback onConfigured;

  const GoogleDriveConfigureView({
    super.key,
    required this.onConfigured,
    this.branding,
  });

  /// Defaults to Google Drive.
  final CloudAccountBranding? branding;

  @override
  State<GoogleDriveConfigureView> createState() =>
      _GoogleDriveConfigureViewState();
}

class _GoogleDriveConfigureViewState extends State<GoogleDriveConfigureView> {
  final _clientIdController = TextEditingController();
  final _clientSecretController = TextEditingController();
  bool _isSaving = false;

  @override
  void dispose() {
    _clientIdController.dispose();
    _clientSecretController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;

    final b = widget.branding ?? CloudAccountBranding.googleDrive;
    final clientId = _clientIdController.text.trim();
    final clientSecret = _clientSecretController.text.trim();

    if (clientId.isEmpty || (b.requiresSecret && clientSecret.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            b.requiresSecret
                ? '${b.idLabel} and Client Secret are required'
                : '${b.idLabel} is required',
          ),
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await DatabaseManager.instance.database!.execute(
        'INSERT INTO providers (service, client_id, client_secret, api_key, type) '
        'VALUES (?, ?, ?, ?, \'collection\') '
        'ON CONFLICT(service) DO UPDATE SET '
        'client_id = excluded.client_id, '
        'client_secret = excluded.client_secret, '
        'api_key = excluded.api_key',
        [
          b.service,
          clientId,
          b.requiresSecret ? CredentialCodec.encrypt(clientSecret) : '',
          '',
        ],
      );

      widget.onConfigured();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save configuration: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.branding ?? CloudAccountBranding.googleDrive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        b.logo,
        const SizedBox(height: 24),
        Text(
          'Configure ${b.name}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          b.configureIntro,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          link: true,
          child: InkWell(
            onTap: () => launchUrl(Uri.parse(b.credentialsUrl)),
            child: Text(
              b.credentialsLinkText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.blue,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _clientIdController,
          decoration: InputDecoration(
            labelText: b.idLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        if (b.requiresSecret) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _clientSecretController,
            decoration: const InputDecoration(
              labelText: 'Client Secret',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
        ],
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child:
              _isSaving
                  ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Text(
                    'Save & Continue',
                    style: TextStyle(fontSize: 16),
                  ),
        ),
      ],
    );
  }
}
