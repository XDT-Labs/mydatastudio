import 'package:flutter/material.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:go_router/go_router.dart';


class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, TextEditingController> _clientIdControllers = {};
  final Map<String, TextEditingController> _clientSecretControllers = {};
  final Map<String, TextEditingController> _apiKeyControllers = {};
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
      final provider = await (db.select(db.providers)..where((tbl) => tbl.service.equals(service))).getSingleOrNull();
      if (provider != null) {
        _clientIdControllers[service]?.text = provider.clientId ?? '';
        _clientSecretControllers[service]?.text = provider.clientSecret ?? '';
        _apiKeyControllers[service]?.text = provider.apiKey ?? '';
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveProvider(String service) async {
    final clientId = _clientIdControllers[service]?.text.trim() ?? '';
    final clientSecret = _clientSecretControllers[service]?.text.trim() ?? '';
    final apiKey = _apiKeyControllers[service]?.text.trim() ?? '';

    // Route through writer isolate to avoid SQLITE_BUSY during scanning
    final writer = DatabaseManager.instance.writerIsolateClient;
    if (writer != null) {
      await writer.send({
        'type': 'save_provider',
        'service': service,
        'clientId': clientId,
        'clientSecret': clientSecret,
        'apiKey': apiKey,
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $service configuration')),
      );
    }
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
      body: _isLoading
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
                ..._supportedProviders.map((service) => _buildProviderSection(service)),
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
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _clientIdControllers[service],
              decoration: const InputDecoration(
                labelText: 'Client ID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _clientSecretControllers[service],
              decoration: const InputDecoration(
                labelText: 'Client Secret',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyControllers[service],
              decoration: const InputDecoration(
                labelText: 'API Key (Optional)',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () => _saveProvider(service),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
