import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/content_policy_controls.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

class LocalFilesTabView extends StatelessWidget {
  const LocalFilesTabView({
    super.key,
    required this.formKey,
    required this.nameController,
    required this.pathController,
    required this.onBrowse,
    required this.onSave,
    required this.onCancel,
    this.intro = 'Select folder to add.',
    this.policy,
    this.onPolicyChanged,
  });

  /// Owned by the page, so it can validate on save and light up both fields'
  /// errors at once.
  final GlobalKey<FormState> formKey;
  final TextEditingController nameController;
  final TextEditingController pathController;
  final VoidCallback onBrowse;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  /// Line shown above the fields; varies by source (network drive, etc.).
  final String intro;

  /// Which files get an archive copy. Shown for cloud sync folders only: a
  /// plain local folder already is the copy.
  final ContentPolicy? policy;
  final ValueChanged<ContentPolicy>? onPolicyChanged;

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            intro,
            style: const TextStyle(fontWeight: FontWeight.normal, fontSize: 16),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: nameController,
                  validator:
                      (value) =>
                          (value == null || value.isEmpty)
                              ? 'Name is required'
                              : null,
                  decoration: const InputDecoration(
                    hintText: 'Name of folder',
                    labelText: 'Name *',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: pathController,
                  readOnly: true,
                  validator:
                      (value) =>
                          (value == null || value.isEmpty)
                              ? 'Folder is required'
                              : null,
                  decoration: const InputDecoration(
                    icon: Icon(Icons.folder_open),
                    hintText: 'Click Browse to select a folder',
                    labelText: 'Folder *',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: onBrowse,
                icon: const Icon(Icons.search),
                label: const Text('Browse'),
              ),
            ],
          ),
          if (policy != null && onPolicyChanged != null) ...[
            const SizedBox(height: 16),
            ContentPolicyControls(policy: policy!, onChanged: onPolicyChanged!),
          ],
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: onSave,
                child: const Text('Add Folder'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
