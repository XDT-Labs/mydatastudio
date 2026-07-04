import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/app_user.dart';

class SetupStep4 extends StatelessWidget {
  const SetupStep4({
    super.key,
    required this.appUser,
    required this.onCancel,
    required this.onSubmit,
  });

  final AppUser? appUser;
  final VoidCallback onCancel;
  final void Function(AppUser) onSubmit;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Choose your language',
          style: textTheme.titleLarge?.copyWith(color: colorScheme.onSurface),
        ),
        const SizedBox(height: 4),
        Text(
          'More languages are coming soon.',
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: 'English',
              isExpanded: true,
              icon: const Icon(Icons.expand_more),
              items: const [
                DropdownMenuItem(value: 'English', child: Text('English')),
              ],
              onChanged: null,
            ),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () => onCancel(),
              child: const Text('Back'),
            ),
            const Spacer(),
            FilledButton(
              onPressed: appUser != null ? () => onSubmit(appUser!) : null,
              child: const Text('Complete Setup'),
            ),
          ],
        ),
      ],
    );
  }
}
