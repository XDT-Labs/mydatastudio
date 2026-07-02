import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/aichat_model.dart';
import 'package:mydatastudio/repositories/aichat_model_repository.dart';

// ─── Cloud model definitions ──────────────────────────────────────────────────

class _CloudGroup {
  final String group;
  final String label;
  final IconData icon;

  const _CloudGroup(this.group, this.label, this.icon);
}

const List<_CloudGroup> _cloudGroups = [
  _CloudGroup('gemini', 'Gemini', Icons.auto_awesome),
  _CloudGroup('claude', 'Claude', Icons.psychology),
  _CloudGroup('openai', 'OpenAI', Icons.hub),
  _CloudGroup('grok', 'Grok', Icons.bolt),
];

// ─── Page ─────────────────────────────────────────────────────────────────────

class AichatModelsSettingsPage extends StatefulWidget {
  const AichatModelsSettingsPage({super.key});

  @override
  State<AichatModelsSettingsPage> createState() =>
      _AichatModelsSettingsPageState();
}

class _AichatModelsSettingsPageState extends State<AichatModelsSettingsPage> {
  late final AichatModelRepository _repo;
  List<AichatModel> _models = [];
  bool _isLoading = true;

  // Local LLM
  final _hfApiKeyController = TextEditingController();
  AichatModel? _selectedModel;
  bool _isDownloading = false;
  String? _downloadError;
  double _downloadProgress = 0.0;
  double _downloadedMb = 0.0;
  double _totalMb = 0.0;

  // Ollama
  final _ollamaUrlController = TextEditingController();

  // Cloud API keys (one per group)
  final Map<String, TextEditingController> _apiKeyControllers = {
    for (final g in _cloudGroups) g.group: TextEditingController(),
  };
  // True for groups whose key has been saved to the DB
  final Map<String, bool> _savedApiKeys = {
    for (final g in _cloudGroups) g.group: false,
  };

  // Debounce timers — auto-save fires 600 ms after the last keystroke
  Timer? _hfKeyTimer;
  Timer? _ollamaUrlTimer;
  final Map<String, Timer?> _cloudKeyTimers = {
    for (final g in _cloudGroups) g.group: null,
  };

  StreamSubscription<List<AichatModel>>? _sub;

  @override
  void initState() {
    super.initState();
    final db = DatabaseManager.instance.database!;
    _repo = AichatModelRepository(db);
    _sub = _repo.watchAll().listen((models) {
      if (!mounted) return;
      setState(() => _models = models);
    });
    _loadInitial();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hfKeyTimer?.cancel();
    _ollamaUrlTimer?.cancel();
    for (final t in _cloudKeyTimers.values) {
      t?.cancel();
    }
    _hfApiKeyController.dispose();
    _ollamaUrlController.dispose();
    for (final c in _apiKeyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInitial() async {
    final models = await _repo.getAll();

    final ollamaModel = models.where((m) => m.group == 'ollama').firstOrNull;
    final ollamaUrl = ollamaModel?.baseUrl ?? 'http://localhost:11434';

    // Load all API keys from providers table in one query
    final db = DatabaseManager.instance.database!;
    final providerServices = [
      'huggingface',
      ..._cloudGroups.map((g) => g.group),
    ];
    final placeholders = providerServices.map((_) => '?').join(', ');
    final providerRows = await db.select(
      'SELECT service, api_key FROM providers WHERE service IN ($placeholders)',
      providerServices,
    );
    final providerKeys = {
      for (final r in providerRows)
        r['service'] as String: r['api_key'] as String? ?? '',
    };

    final hfKey = providerKeys['huggingface'] ?? '';

    final Map<String, String> savedKeys = {};
    for (final g in _cloudGroups) {
      final key = providerKeys[g.group] ?? '';
      if (key.isNotEmpty) savedKeys[g.group] = key;
    }

    if (!mounted) return;

    // Flush everything in one setState so controllers and savedApiKeys flags
    // are always in sync with the first real build pass.
    setState(() {
      _models = models;
      _isLoading = false;
      _ollamaUrlController.text = ollamaUrl;
      if (hfKey.isNotEmpty) _hfApiKeyController.text = hfKey;
      for (final entry in savedKeys.entries) {
        _apiKeyControllers[entry.key]?.text = entry.value;
        _savedApiKeys[entry.key] = true;
      }
    });
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<AichatModel> _byGroup(String group) =>
      _models.where((m) => m.group == group).toList();

  Future<void> _saveHfKey() async {
    final key = _hfApiKeyController.text.trim();
    if (key.isEmpty) return;
    await DatabaseManager.instance.database!.execute(
      'INSERT INTO providers (service, client_id, client_secret, api_key, type) '
      'VALUES (?, \'\', \'\', ?, \'model\') '
      'ON CONFLICT(service) DO UPDATE SET api_key = excluded.api_key',
      ['huggingface', key],
    );
    _showSnack('HuggingFace API key saved');
  }

  void _onHfKeyChanged(String _) {
    _hfKeyTimer?.cancel();
    _hfKeyTimer = Timer(const Duration(milliseconds: 600), _saveHfKey);
  }

  void _onOllamaUrlChanged(String _) {
    _ollamaUrlTimer?.cancel();
    _ollamaUrlTimer = Timer(const Duration(milliseconds: 600), _saveOllamaUrl);
  }

  void _onCloudKeyChanged(String group, String _) {
    _cloudKeyTimers[group]?.cancel();
    _cloudKeyTimers[group] = Timer(
      const Duration(milliseconds: 600),
      () => _saveCloudApiKey(group),
    );
  }

  Future<void> _saveCloudApiKey(String group) async {
    final key = _apiKeyControllers[group]?.text.trim() ?? '';
    if (key.isEmpty) return;
    await DatabaseManager.instance.database!.execute(
      'INSERT INTO providers (service, client_id, client_secret, api_key, type) '
      'VALUES (?, \'\', \'\', ?, \'model\') '
      'ON CONFLICT(service) DO UPDATE SET api_key = excluded.api_key',
      [group, key],
    );
    // Enable all models in that group that aren't yet enabled
    for (final m in _byGroup(group)) {
      if (!m.enabled) await _repo.setEnabled(m.id, true);
    }
    setState(() => _savedApiKeys[group] = true);
    _showSnack('Saved $group API key');
  }

  Future<void> _saveOllamaUrl() async {
    final url = _ollamaUrlController.text.trim();
    if (url.isEmpty) return;
    final existing = _byGroup('ollama');
    if (existing.isEmpty) {
      await _repo.create(
        alias: 'Ollama',
        group: 'ollama',
        name: 'ollama',
        type: 'ollama',
        baseUrl: url,
        enabled: true,
      );
    } else {
      await _repo.setBaseUrl(existing.first.id, url);
    }
    _showSnack('Saved Ollama URL');
  }

  /// Downloads a single file from HuggingFace via the AI server's SSE endpoint.
  /// Returns the local path on success, null on failure.
  Future<String?> _downloadSingleFile({
    required http.Client client,
    required String serviceUrl,
    required String hfRepo,
    required String filename,
    required String hfToken,
    required String label,
  }) async {
    final request = http.Request(
      'POST',
      Uri.parse('$serviceUrl/util/download-model'),
    );
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'model_name': hfRepo,
      'filename': filename,
      if (hfToken.isNotEmpty) 'hf_token': hfToken,
    });

    final streamed = await client.send(request);
    if (streamed.statusCode != 200) {
      if (mounted)
        setState(
          () =>
              _downloadError =
                  '$label download failed (${streamed.statusCode})',
        );
      return null;
    }

    String? resultPath;
    final buffer = StringBuffer();
    await streamed.stream.transform(const Utf8Decoder()).forEach((chunk) async {
      buffer.write(chunk);
      final lines = buffer.toString().split('\n');
      buffer
        ..clear()
        ..write(lines.last);

      for (final line in lines.sublist(0, lines.length - 1)) {
        if (!line.startsWith('data: ')) continue;
        final event = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        final status = event['status'] as String;

        if (status == 'downloading') {
          if (!mounted) return;
          setState(() {
            _downloadProgress = (event['progress'] as num).toDouble();
            _downloadedMb = (event['downloaded_mb'] as num).toDouble();
            _totalMb = (event['total_mb'] as num).toDouble();
          });
        } else if (status == 'complete') {
          resultPath = event['model_path'] as String? ?? '';
          if (resultPath!.isEmpty) resultPath = null;
        } else if (status == 'error') {
          if (mounted)
            setState(
              () =>
                  _downloadError =
                      event['message'] as String? ?? '$label download failed',
            );
        }
      }
    });
    return resultPath;
  }

  Future<void> _downloadModel() async {
    if (_selectedModel == null) return;
    final model = _selectedModel!;

    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl == null) {
      _showSnack('AI service is not running');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadError = null;
      _downloadProgress = 0.0;
      _downloadedMb = 0.0;
      _totalMb = 0.0;
    });

    final hfRows = await DatabaseManager.instance.database!.select(
      "SELECT api_key FROM providers WHERE service = 'huggingface' LIMIT 1",
    );
    final hfToken =
        hfRows.isNotEmpty
            ? (hfRows.first['api_key'] as String? ?? '').trim()
            : '';

    final client = http.Client();
    try {
      final modelPath = await _downloadSingleFile(
        client: client,
        serviceUrl: serviceUrl,
        hfRepo: model.hfRepo!,
        filename: model.file!,
        hfToken: hfToken,
        label: 'model',
      );
      if (modelPath == null) return;

      String? mmprojPath;
      final mmprojFilename = model.mmproj ?? '';
      if (mmprojFilename.isNotEmpty && !mmprojFilename.startsWith('/')) {
        if (mounted) {
          setState(() {
            _downloadProgress = 0.0;
            _downloadedMb = 0.0;
            _totalMb = 0.0;
          });
        }
        mmprojPath = await _downloadSingleFile(
          client: client,
          serviceUrl: serviceUrl,
          hfRepo: model.hfRepo!,
          filename: mmprojFilename,
          hfToken: hfToken,
          label: 'vision projector',
        );
      }

      // Update the existing seeded DB row with the downloaded file paths
      await _repo.setLocalPath(model.id, modelPath, mmprojPath);

      if (!mounted) return;
      setState(() {
        _downloadProgress = 1.0;
        _selectedModel = null;
      });
      _showSnack('Downloaded ${model.alias}');
    } catch (e) {
      if (mounted) setState(() => _downloadError = 'Error: $e');
    } finally {
      client.close();
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  Future<void> _confirmDelete(AichatModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Delete model?'),
            content: Text(
              'This will delete "${model.name}" and remove its files from disk. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(
                  'Delete',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true) return;

    // Ask the server to delete the file(s) from disk first
    final serviceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (serviceUrl != null && (model.file ?? '').isNotEmpty) {
      try {
        await http.post(
          Uri.parse('$serviceUrl/util/delete-model'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'model_path': model.file}),
        );
      } catch (e) {
        // Server unreachable — log and continue so the DB row is still removed
        debugPrint('delete-model server call failed: $e');
      }
    }

    await _repo.delete(model.id);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('AI Chat Models')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Default LLM Model'),
          const SizedBox(height: 8),
          _defaultModelCard(),
          const SizedBox(height: 24),
          _sectionHeader('Local Models'),
          const SizedBox(height: 8),
          _localLlmCard(),
          const SizedBox(height: 12),
          _ollamaCard(),
          const SizedBox(height: 24),
          ..._cloudGroups.map(
            (g) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeader(g.label),
                const SizedBox(height: 8),
                _cloudCard(g),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  // ── Default model card ─────────────────────────────────────────────────────

  Widget _defaultModelCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Gemma 4 12B',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'Built-in model. Always available.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Hugging Face download card ──────────────────────────────────────────────

  Widget _localLlmCard() {
    final downloadable = _byGroup('local')
        .where((m) => !m.enabled && (m.hfRepo ?? '').isNotEmpty)
        .toList();
    final downloaded = _byGroup('local')
        .where((m) => m.alias != 'gemma4:12b' && m.enabled)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hugging Face',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            // HuggingFace API Key
            TextField(
              controller: _hfApiKeyController,
              onChanged: _onHfKeyChanged,
              decoration: const InputDecoration(
                labelText: 'HuggingFace API Key',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Download a Model',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            // DB-backed downloadable models dropdown
            InputDecorator(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Select model',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<AichatModel>(
                  value: _selectedModel,
                  isExpanded: true,
                  items: downloadable
                      .map(
                        (m) => DropdownMenuItem(value: m, child: Text(m.name)),
                      )
                      .toList(),
                  onChanged: _isDownloading
                      ? null
                      : (v) => setState(() => _selectedModel = v),
                ),
              ),
            ),
            if (_selectedModel != null) ...[
              const SizedBox(height: 4),
              Text(
                '${_selectedModel!.hfRepo}  ·  ${_selectedModel!.file}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (_isDownloading) ...[
              LinearProgressIndicator(
                value: _downloadProgress > 0 ? _downloadProgress : null,
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _totalMb > 0
                        ? '$_downloadedMb MB / $_totalMb MB'
                        : 'Connecting…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_downloadProgress > 0)
                    Text(
                      '${(_downloadProgress * 100).toStringAsFixed(0)}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ] else ...[
              if (_downloadError != null) ...[
                Text(
                  _downloadError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              ElevatedButton.icon(
                onPressed: _selectedModel != null ? _downloadModel : null,
                icon: const Icon(Icons.download),
                label: const Text('Download Model'),
              ),
            ],
            // Downloaded models list
            if (downloaded.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                'Downloaded Models',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              ...downloaded.map((m) => _modelTile(m)),
            ],
          ],
        ),
      ),
    );
  }

  // ── Ollama card ────────────────────────────────────────────────────────────

  Widget _ollamaCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Ollama',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ollamaUrlController,
              onChanged: _onOllamaUrlChanged,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Cloud provider card ────────────────────────────────────────────────────

  Widget _cloudCard(_CloudGroup g) {
    final groupModels = _byGroup(g.group);
    final hasSavedKey = _savedApiKeys[g.group] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(g.icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  g.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiKeyControllers[g.group],
              onChanged: (v) => _onCloudKeyChanged(g.group, v),
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
              ),
            ),
            if (hasSavedKey && groupModels.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...groupModels.map((m) => _modelTile(m)),
            ] else if (!hasSavedKey) ...[
              const SizedBox(height: 8),
              Text(
                'Enter an API key to enable ${g.label} models.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Individual model tile ──────────────────────────────────────────────────

  Widget _modelTile(AichatModel model, {bool isDefault = false}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(model.name),
      subtitle:
          model.group == 'local'
              ? Text(
                model.file ?? model.name,
                style: Theme.of(context).textTheme.bodySmall,
              )
              : null,
      trailing:
          isDefault
              ? null
              : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: model.enabled,
                    onChanged: (v) => _repo.setEnabled(model.id, v),
                  ),
                  if (model.group == 'local')
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'Remove',
                      onPressed: () => _confirmDelete(model),
                    ),
                ],
              ),
    );
  }
}
