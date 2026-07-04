import 'dart:io';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reactive_forms/reactive_forms.dart';
import 'package:mydatastudio/database_manager.dart';

class SetupStep2 extends StatefulWidget {
  const SetupStep2({
    super.key,
    required this.appUser,
    required this.onCancel,
    required this.onSubmit,
  });

  final AppUser? appUser;
  final VoidCallback onCancel;
  final void Function(AppUser) onSubmit;

  @override
  State<SetupStep2> createState() => _SetupStep2State();
}

class _SetupStep2State extends State<SetupStep2> {
  String? errorMessage;
  bool isNetworkShare = false;

  final storageForm = FormGroup({
    'storageLocation': FormControl<String>(validators: [Validators.required]),
  });

  @override
  void initState() {
    super.initState();
    _checkInitialPathWal();
  }

  Future<void> _checkInitialPathWal() async {
    final path = widget.appUser?.localStoragePath;
    if (path != null && path.isNotEmpty) {
      final supports = await DatabaseManager.testPathSupportsWal(path);
      if (mounted) {
        setState(() {
          isNetworkShare = !supports;
        });
      }
    }
  }

  void onStepCancelHandler() {
    widget.onCancel();
  }

  Future<void> onStepContinueHandler(BuildContext context) async {
    var appUser = widget.appUser;

    if (storageForm.valid && appUser != null) {
      String? dbDir = MainApp.appDataDirectory.value;
      appUser.localStoragePath =
          (dbDir! is Directory) ? (dbDir as Directory).path : dbDir;

      try {
        errorMessage = null;
        //Check directories as needed
        var dir = Directory(appUser.localStoragePath);
        var keysDir = Directory(
          "${appUser.localStoragePath}${Platform.pathSeparator}keys",
        );
        var dbDir = Directory(
          "${appUser.localStoragePath}${Platform.pathSeparator}data",
        );
        var repoDir = Directory(
          "${appUser.localStoragePath}${Platform.pathSeparator}files",
        );
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        if (!keysDir.existsSync()) {
          keysDir.createSync(recursive: true);
        }
        if (!dbDir.existsSync()) {
          dbDir.createSync(recursive: true);
        }
        if (!repoDir.existsSync()) {
          repoDir.createSync(recursive: true);
        }

        // Test SQLite WAL support (fails on network/SMB shares)
        setState(() {
          errorMessage = 'Validating storage speed and locking...';
        });
        final supportsWal = await DatabaseManager.testPathSupportsWal(
          appUser.localStoragePath,
        );
        setState(() {
          isNetworkShare = !supportsWal;
          errorMessage = null;
        });

        //call callback and proceed to next step
        widget.onSubmit(appUser);
      } catch (e) {
        //Missing permissions required to use folder
        storageForm.findControl('storageLocation')?.value = '';
        setState(() {
          errorMessage = 'Missing permissions required to use folder';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    //handle async setup for validators
    var dir = MainApp.supportDirectory.valueOrNull;
    var field = storageForm.findControl('storageLocation');
    if (field != null && (field.value == null || field.value!.isEmpty)) {
      String? initialPath;
      if (widget.appUser?.localStoragePath != null &&
          widget.appUser!.localStoragePath.isNotEmpty) {
        initialPath = widget.appUser!.localStoragePath;
      } else if (dir is String) {
        initialPath = dir as String;
      } else if (dir is Directory) {
        initialPath = dir.path;
      }
      if (initialPath != null) {
        field.value = initialPath;
        MainApp.appDataDirectory.add(initialPath);
      }
    }

    return ReactiveForm(
      formGroup: storageForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Choose your archive location',
            style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'This is where My Data Studio stores everything it downloads from your '
            'other online services — files, emails, social media posts, and more. '
            'Choose your largest hard drive. If you have an external NAS or drive, use that.',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: ReactiveTextField(
                    readOnly: true,
                    formControlName: 'storageLocation',
                    style: TextStyle(color: colorScheme.onSurface),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () async {
                    String? result =
                        await FilePicker.platform.getDirectoryPath();
                    if (result != null) {
                      storageForm.findControl('storageLocation')?.value =
                          result;
                      MainApp.appDataDirectory.add(result);
                      final supportsWal =
                          await DatabaseManager.testPathSupportsWal(result);
                      setState(() {
                        isNetworkShare = !supportsWal;
                      });
                    }
                  },
                  child: const Text('Browse'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (errorMessage != null)
            Text(
              errorMessage!,
              style: TextStyle(color: colorScheme.error),
            ),
          if (isNetworkShare)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colorScheme.tertiary),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: colorScheme.tertiary, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This path is on a network share. The database will be stored '
                        'locally on your primary drive for compatibility and performance, '
                        'while your files and backups remain on the network share.',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              TextButton(
                onPressed: () => onStepCancelHandler(),
                child: const Text('Back'),
              ),
              const Spacer(),
              ReactiveFormConsumer(
                builder: (context, form, child) {
                  return FilledButton(
                    onPressed:
                        storageForm.valid
                            ? () => onStepContinueHandler(context)
                            : null,
                    child: const Text('Continue'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
