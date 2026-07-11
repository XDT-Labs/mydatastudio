import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, TextEditingController> _clientIdControllers = {};
  final Map<String, TextEditingController> _clientSecretControllers = {};
  final Map<String, TextEditingController> _apiKeyControllers = {};
  final Map<String, Timer?> _debounceTimers = {};
  bool _isLoading = true;

  final List<String> _supportedProviders = [
    'google',
    'microsoft/azure',
    'dropbox',
    'facebook',
    'instagram',
    'twitter',
  ];

  @override
  void initState() {
    super.initState();
    for (final provider in _supportedProviders) {
      _clientIdControllers[provider] = TextEditingController();
      _clientSecretControllers[provider] = TextEditingController();
      _apiKeyControllers[provider] = TextEditingController();
    }
    _loadProviders();
  }

  @override
  void dispose() {
    for (final timer in _debounceTimers.values) {
      timer?.cancel();
    }
    for (final controller in _clientIdControllers.values) {
      controller.dispose();
    }
    for (final controller in _clientSecretControllers.values) {
      controller.dispose();
    }
    for (final controller in _apiKeyControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProviders() async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;

    for (final service in _supportedProviders) {
      final rows = await db.select(
        "SELECT * FROM providers WHERE service = ?",
        [service],
      );
      if (rows.isNotEmpty) {
        final provider = Provider.fromDbMap(rows.first);
        _clientIdControllers[service]?.text = provider.clientId ?? '';
        _clientSecretControllers[service]?.text = provider.clientSecret ?? '';
        _apiKeyControllers[service]?.text = provider.apiKey ?? '';
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _onFieldChanged(String service) {
    _debounceTimers[service]?.cancel();
    _debounceTimers[service] = Timer(
      const Duration(milliseconds: 600),
      () => _saveProvider(service),
    );
  }

  Future<void> _saveProvider(String service) async {
    final clientId = _clientIdControllers[service]?.text.trim() ?? '';
    final clientSecret = _clientSecretControllers[service]?.text.trim() ?? '';
    final apiKey = _apiKeyControllers[service]?.text.trim() ?? '';

    await DatabaseManager.instance.database!.execute(
      'INSERT INTO providers (service, client_id, client_secret, api_key, type) '
      'VALUES (?, ?, ?, ?, \'collection\') '
      'ON CONFLICT(service) DO UPDATE SET '
      'client_id = excluded.client_id, '
      'client_secret = excluded.client_secret, '
      'api_key = excluded.api_key',
      [service, clientId, clientSecret, apiKey],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Providers'),
        leading: BackButton(
          onPressed: () {
            if (GoRouter.of(context).canPop()) {
              GoRouter.of(context).pop();
            } else {
              GoRouter.of(context).go('/');
            }
          },
        ),
      ),
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  Text(
                    'OAuth Providers',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Configure your OAuth Client ID and Secret for various services. '
                    'If left blank, the application will attempt to use default environment variables if available.',
                  ),
                  const SizedBox(height: 24),
                  ..._supportedProviders.map(
                    (service) => _buildProviderSection(service),
                  ),
                ],
              ),
    );
  }

  Widget _buildProviderSection(String service) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              service.toUpperCase(),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            if (service == 'google') ...[
              const Text(
                'To connect to Google services, you must provide your own OAuth Client ID and Client Secret. Ensure your OAuth consent screen is configured with the following scopes:\n'
                '• https://www.googleapis.com/auth/userinfo.email\n'
                '• https://www.googleapis.com/auth/userinfo.profile\n'
                '• https://www.googleapis.com/auth/drive\n'
                '• https://www.googleapis.com/auth/user.emails.read\n'
                '• https://www.googleapis.com/auth/gmail.readonly\n\n'
                'Note: Ensure that the Google People API, Google Drive API, and Gmail API are enabled in your Google Cloud Console project.',
                style: TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () => launchUrl(
                  Uri.parse('https://console.cloud.google.com/apis/credentials'),
                ),
                child: const Text(
                  'Get Credentials from Google Cloud Console',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.blue,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _clientIdControllers[service],
              onChanged: (val) => _onFieldChanged(service),
              decoration: const InputDecoration(
                labelText: 'Client ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _clientSecretControllers[service],
              onChanged: (val) => _onFieldChanged(service),
              decoration: const InputDecoration(
                labelText: 'Client Secret',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            if (service != 'google') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyControllers[service],
                onChanged: (val) => _onFieldChanged(service),
                decoration: const InputDecoration(
                  labelText: 'API Key (Optional)',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
