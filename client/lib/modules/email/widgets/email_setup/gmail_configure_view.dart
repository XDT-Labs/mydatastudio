import 'package:flutter/material.dart';
import 'package:mydatatools/database_manager.dart';

import 'package:url_launcher/url_launcher.dart';

class GmailConfigureView extends StatefulWidget {
  final VoidCallback onConfigured;

  const GmailConfigureView({super.key, required this.onConfigured});

  @override
  State<GmailConfigureView> createState() => _GmailConfigureViewState();
}

class _GmailConfigureViewState extends State<GmailConfigureView> {
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

    final clientId = _clientIdController.text.trim();
    final clientSecret = _clientSecretController.text.trim();

    if (clientId.isEmpty || clientSecret.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Client ID and Client Secret are required')),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await DatabaseManager.instance.database!.execute(
        'INSERT INTO providers (service, client_id, client_secret, api_key) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(service) DO UPDATE SET '
        'client_id = excluded.client_id, '
        'client_secret = excluded.client_secret, '
        'api_key = excluded.api_key',
        ['google', clientId, clientSecret, ''],
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
        const Icon(Icons.email, size: 72, color: Colors.red),
        const SizedBox(height: 24),
        const Text(
          'Configure Gmail',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'To connect to Gmail, you must provide your own OAuth Client ID and Secret.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600, height: 1.5),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => launchUrl(Uri.parse('https://console.cloud.google.com/apis/credentials')),
          child: const Text(
            'Get Credentials from Google Cloud Console',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.blue, decoration: TextDecoration.underline),
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
        const SizedBox(height: 16),
        TextField(
          controller: _clientSecretController,
          decoration: const InputDecoration(
            labelText: 'Client Secret',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: _isSaving ? null : _save,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          child: _isSaving 
            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Save & Continue', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}
