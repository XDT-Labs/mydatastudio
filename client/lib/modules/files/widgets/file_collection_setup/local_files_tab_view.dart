import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';

class LocalFilesTabView extends StatelessWidget {
  const LocalFilesTabView({
    super.key,
    required this.form,
    required this.onBrowse,
    required this.onSave,
    required this.onCancel,
  });

  final FormGroup form;
  final VoidCallback onBrowse;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: MediaQuery.of(context).size.width / 2,
        child: ReactiveForm(
          formGroup: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Select folder to add.',
                style: TextStyle(fontWeight: FontWeight.normal, fontSize: 16),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ReactiveTextField(
                      formControlName: 'name',
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
                    child: ReactiveTextField(
                      formControlName: 'path',
                      readOnly: true,
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
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: onSave,
                    child: const Text('Add Folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
