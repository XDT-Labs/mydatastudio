import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/oauth/microsoft_auth.dart';

import 'package:url_launcher/url_launcher.dart';

class OutlookConfigureView extends StatefulWidget {
  final VoidCallback onConfigured;

  const OutlookConfigureView({super.key, required this.onConfigured});

  @override
  State<OutlookConfigureView> createState() => _OutlookConfigureViewState();
}

class _OutlookConfigureViewState extends State<OutlookConfigureView> {
  final _clientIdController = TextEditingController();
  bool _isSaving = false;

  @override
  void dispose() {
    _clientIdController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;

    final clientId = _clientIdController.text.trim();

    if (clientId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Client ID is required')),
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
        ['azure', clientId, '', ''],
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.email, size: 72, color: Color(0xFF0078D4)),
        const SizedBox(height: 24),
        const Text(
          'Configure Outlook',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          kBundledOutlookClientId.isEmpty
              ? "Microsoft sign-in isn't configured in this build. To connect "
                  'to Outlook, register your own app in Microsoft Entra (a '
                  'public client with redirect URI http://localhost) and '
                  'enter its Application (client) ID. No client secret is '
                  'needed.'
              : 'Enter the Application (client) ID of your own Microsoft '
                  'Entra app to use it instead of the built-in one. No client '
                  'secret is needed.',
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
            onTap:
                () => launchUrl(
                  Uri.parse(
                    'https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade',
                  ),
                ),
            child: const Text(
              'Register an app in the Microsoft Azure Portal',
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
          decoration: const InputDecoration(
            labelText: 'Client ID',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor: const Color(0xFF0078D4),
            foregroundColor: Colors.white,
          ),
          child:
              _isSaving
                  ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
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
