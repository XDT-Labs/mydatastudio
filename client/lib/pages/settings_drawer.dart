import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: Container(
        height: double.infinity,
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.all(8),
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Settings',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key),
              title: const Text('Providers'),
              selected: true, // Currently the only page
              onTap: () {
                // Navigate to providers if not already there, currently we only have one settings page
                GoRouter.of(context).go('/settings');
              },
            ),
          ],
        ),
      ),
    );
  }
}
