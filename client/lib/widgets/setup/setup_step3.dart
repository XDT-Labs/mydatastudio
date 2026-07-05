import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/helpers/encryption_helper.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/app_user.dart';
import 'package:pointycastle/pointycastle.dart';

class SetupStep3 extends StatefulWidget {
  const SetupStep3({
    super.key,
    required this.appUser,
    required this.onCancel,
    required this.onSubmit,
  });

  final AppUser? appUser;
  final VoidCallback onCancel;
  final void Function(AppUser) onSubmit;

  @override
  State<SetupStep3> createState() => _SetupStep3State();
}

class _SetupStep3State extends State<SetupStep3> {
  final EncryptionHelper encHelper = EncryptionHelper();
  final AppLogger logger = AppLogger(null);
  bool _isSubmitting = false;

  //async method to load os data and initialize form
  AppUser _ensureKeys(AppUser appUser) {
    if (appUser.localStoragePath.isNotEmpty) {
      //check storage location for existing public & private pem files to use
      var keysDir = Directory(
        "${appUser.localStoragePath}${Platform.pathSeparator}keys",
      );
      var pubFile = File("${keysDir.path}${Platform.pathSeparator}public.pem");
      var priFile = File("${keysDir.path}${Platform.pathSeparator}private.pem");

      if (pubFile.existsSync() && priFile.existsSync()) {
        appUser.publicKey = pubFile.readAsStringSync();
        appUser.privateKey = priFile.readAsStringSync();
      }
      //if existing files don't exists, generate new keys
      else if (appUser.publicKey == null) {
        AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> keys =
            encHelper.generateRSAkeyPair();
        appUser.publicKey = encHelper.encodePublicKeyToPemPKCS1(keys.publicKey);
        appUser.privateKey = encHelper.encodePrivateKeyToPemPKCS1(
          keys.privateKey,
        );
      }
    }
    return appUser;
  }

  Future<void> _confirmRegenerateKeys(AppUser appUser) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Regenerate encryption keys?'),
            content: const Text(
              'Any files already encrypted with the current keys will no longer '
              'be readable. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Regenerate'),
              ),
            ],
          ),
    );

    if (confirmed == true) {
      AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> keys =
          encHelper.generateRSAkeyPair();
      setState(() {
        appUser.publicKey = encHelper.encodePublicKeyToPemPKCS1(keys.publicKey);
        appUser.privateKey = encHelper.encodePrivateKeyToPemPKCS1(
          keys.privateKey,
        );
      });
    }
  }

  void _viewKeys(AppUser appUser) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Your Encryption Keys'),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _keyBlock(context, 'Public Key', appUser.publicKey ?? ''),
                    const SizedBox(height: 16),
                    _keyBlock(context, 'Private Key', appUser.privateKey ?? ''),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
    );
  }

  Widget _keyBlock(BuildContext context, String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              tooltip: 'Copy to clipboard',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: value));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('$label copied to clipboard')),
                );
              },
            ),
          ],
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ],
    );
  }

  Future<void> _downloadKeys(AppUser appUser) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a location to save a backup copy of your keys',
    );
    if (result == null) return;

    try {
      File(
        '$result${Platform.pathSeparator}public.pem',
      ).writeAsStringSync(appUser.publicKey ?? '');
      File(
        '$result${Platform.pathSeparator}private.pem',
      ).writeAsStringSync(appUser.privateKey ?? '');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Keys saved to $result')));
      }
    } catch (e) {
      logger.e('Failed to save keys: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save keys to that location')),
        );
      }
    }
  }

  void onStepContinueHandler(BuildContext context, AppUser user) {
    widget.onSubmit(user);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.appUser == null) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    var appUserClone = widget.appUser!;
    if (appUserClone.publicKey == null || appUserClone.privateKey == null) {
      appUserClone = _ensureKeys(appUserClone);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Encryption keys',
          style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
        ),
        const SizedBox(height: 4),
        Text(
          'My Data Studio generates a private/public key pair for future data sharing features and online backups'
          ' — you can view or download a backup copy below.',
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
              Icon(Icons.check_circle, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Encryption keys ready',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => _viewKeys(appUserClone),
              icon: const Icon(Icons.visibility_outlined, size: 18),
              label: const Text('View Keys'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: () => _downloadKeys(appUserClone),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download Keys'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => _confirmRegenerateKeys(appUserClone),
          child: const Text('Regenerate keys'),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () => widget.onCancel(),
              child: const Text('Back'),
            ),
            const Spacer(),
            FilledButton(
              onPressed:
                  _isSubmitting
                      ? null
                      : () {
                        setState(() {
                          _isSubmitting = true;
                        });
                        onStepContinueHandler(context, appUserClone);
                      },
              child:
                  _isSubmitting
                      ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Text('Continue'),
            ),
          ],
        ),
      ],
    );
  }
}
