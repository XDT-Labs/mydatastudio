import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/aichat_skill.dart';
import 'package:mydatastudio/repositories/aichat_skills_repository.dart';

class AichatSkillsSettingsPage extends StatefulWidget {
  const AichatSkillsSettingsPage({super.key});

  @override
  State<AichatSkillsSettingsPage> createState() =>
      _AichatSkillsSettingsPageState();
}

class _AichatSkillsSettingsPageState extends State<AichatSkillsSettingsPage> {
  late final AichatSkillsRepository _repo;
  List<AichatSkill> _skills = [];
  StreamSubscription<List<AichatSkill>>? _sub;

  @override
  void initState() {
    super.initState();
    _repo = AichatSkillsRepository(DatabaseManager.instance.database!);
    _sub = _repo.watchAll().listen((skills) {
      if (!mounted) return;
      setState(() => _skills = skills);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _openEditor({AichatSkill? skill}) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _SkillEditorDialog(
        repo: _repo,
        skill: skill,
      ),
    );
  }

  Future<void> _deleteSkill(AichatSkill skill) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Skill'),
        content: Text('Delete "${skill.name}" (${skill.trigger})?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _repo.delete(skill.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chat Skills',
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Type /trigger in chat to activate a skill. Skills inject a system prompt that shapes how the model responds.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  FilledButton.icon(
                    onPressed: () => _openEditor(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New Skill'),
                  ),
                ],
              ),
            ),
          ),
          if (_skills.isEmpty)
            const SliverFillRemaining(
              child: Center(
                child: Text('No skills yet. Create one with "New Skill".'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final skill = _skills[index];
                    return _SkillTile(
                      skill: skill,
                      onToggle: (val) => _repo.setEnabled(skill.id, val),
                      onEdit: () => _openEditor(skill: skill),
                      onDelete: () => _deleteSkill(skill),
                    );
                  },
                  childCount: _skills.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Skill list tile ────────────────────────────────────────────────────────────

class _SkillTile extends StatelessWidget {
  final AichatSkill skill;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SkillTile({
    required this.skill,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Chip(
          label: Text(
            skill.trigger,
            style: theme.textTheme.labelMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
          visualDensity: VisualDensity.compact,
        ),
        title: Text(skill.name),
        subtitle: skill.description != null
            ? Text(
                skill.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: skill.enabled,
              onChanged: onToggle,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 20),
              tooltip: 'Edit',
              onPressed: onEdit,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Skill editor dialog ────────────────────────────────────────────────────────

class _SkillEditorDialog extends StatefulWidget {
  final AichatSkillsRepository repo;
  final AichatSkill? skill;

  const _SkillEditorDialog({required this.repo, this.skill});

  @override
  State<_SkillEditorDialog> createState() => _SkillEditorDialogState();
}

class _SkillEditorDialogState extends State<_SkillEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _triggerController;
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _systemPromptController;
  bool _enabled = true;
  bool _saving = false;
  String? _saveError;

  bool get _isEditing => widget.skill != null;

  @override
  void initState() {
    super.initState();
    final s = widget.skill;
    _triggerController = TextEditingController(text: s?.trigger ?? '/');
    _nameController = TextEditingController(text: s?.name ?? '');
    _descriptionController = TextEditingController(text: s?.description ?? '');
    _systemPromptController = TextEditingController(text: s?.systemPrompt ?? '');
    _enabled = s?.enabled ?? true;
  }

  @override
  void dispose() {
    _triggerController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final trigger = _triggerController.text.trim();
      final name = _nameController.text.trim();
      final description = _descriptionController.text.trim();
      final systemPrompt = _systemPromptController.text.trim();

      if (_isEditing) {
        await widget.repo.upsert(widget.skill!.copyWith(
          trigger: trigger,
          name: name,
          description: description.isEmpty ? null : description,
          systemPrompt: systemPrompt,
          enabled: _enabled,
        ));
      } else {
        await widget.repo.create(
          trigger: trigger,
          name: name,
          description: description.isEmpty ? null : description,
          systemPrompt: systemPrompt,
          enabled: _enabled,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _saveError = e.toString().contains('UNIQUE')
            ? 'A skill with this trigger already exists.'
            : 'Failed to save: $e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? 'Edit Skill' : 'New Skill',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 140,
                      child: TextFormField(
                        controller: _triggerController,
                        decoration: const InputDecoration(
                          labelText: 'Trigger',
                          hintText: '/command',
                          border: OutlineInputBorder(),
                        ),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Required';
                          if (!v.trim().startsWith('/')) return 'Must start with /';
                          if (v.trim().contains(' ')) return 'No spaces allowed';
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Summarize',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    hintText: 'Short description shown in the skills list',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _systemPromptController,
                  decoration: const InputDecoration(
                    labelText: 'System Prompt',
                    hintText: 'You are a summarization assistant. Summarize...',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                  maxLines: 5,
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Enabled'),
                    const SizedBox(width: 8),
                    Switch(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                  ],
                ),
                if (_saveError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _saveError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isEditing ? 'Save' : 'Create'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
