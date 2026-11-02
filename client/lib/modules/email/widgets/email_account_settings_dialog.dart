import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// Whether the account's scanner honours [EmailDeletePolicy]. Only the IMAP
/// scanners reconcile server-side deletions; the Gmail API scanner and PST
/// imports do not, so the setting is hidden for them.
bool supportsEmailDeletePolicy(String scanner) =>
    scanner == AppConstants.scannerEmailImap ||
    scanner == AppConstants.scannerEmailYahoo ||
    scanner == AppConstants.scannerEmailOutlook;

/// Shows the per-account settings dialog. [onSave] defaults to persisting via
/// [CollectionRepository.updateEmailDeletePolicy] (a single-column write).
Future<void> showEmailAccountSettingsDialog(
  BuildContext context, {
  required Collection collection,
  Future<void> Function(Collection)? onSave,
}) {
  return showDialog<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => EmailAccountSettingsDialog(
      collection: collection,
      onSave: onSave ??
        (c) => CollectionRepository().updateEmailDeletePolicy(
          c.id,
          c.emailDeletePolicy,
        ),
    ),
  );
}

class EmailAccountSettingsDialog extends StatefulWidget {
  const EmailAccountSettingsDialog({
    super.key,
    required this.collection,
    required this.onSave,
  });

  final Collection collection;
  final Future<void> Function(Collection) onSave;

  @override
  State<EmailAccountSettingsDialog> createState() =>
      _EmailAccountSettingsDialogState();
}

class _EmailAccountSettingsDialogState
    extends State<EmailAccountSettingsDialog> {
  late EmailDeletePolicy _policy = widget.collection.emailDeletePolicy;

  static const _options = <(EmailDeletePolicy, String, String)>[
    (
      EmailDeletePolicy.keep,
      'Keep in this app',
      'Mail deleted on the server stays visible here. Best for an archive.',
    ),
    (
      EmailDeletePolicy.markDeleted,
      'Hide in this app',
      'Mail deleted on the server is hidden here but can be recovered.',
    ),
    (
      EmailDeletePolicy.remove,
      'Delete from this app',
      'Mail deleted on the server is permanently deleted here, '
          'including its attachments.',
    ),
  ];

  Future<void> _save() async {
    final changedToRemove = _policy == EmailDeletePolicy.remove &&
        widget.collection.emailDeletePolicy != EmailDeletePolicy.remove;
    if (changedToRemove && !await _confirmRemove()) return;
    widget.collection.emailDeletePolicy = _policy;
    await widget.onSave(widget.collection);
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmRemove() async {
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanently delete local copies?'),
        content: const Text(
          'On the next sync, emails that were deleted on the server will be '
          'permanently deleted from this app, along with their attachments. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete locally',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.collection.name} settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When an email is deleted on the server',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            RadioGroup<EmailDeletePolicy>(
              groupValue: _policy,
              onChanged: (v) {
                if (v != null) setState(() => _policy = v);
              },
              child: Column(
                children: [
                  for (final (policy, title, subtitle) in _options)
                    RadioListTile<EmailDeletePolicy>(
                      value: policy,
                      title: Text(title),
                      subtitle: Text(subtitle),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
