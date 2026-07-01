import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({super.key});

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  bool _aiChatExpanded = false;

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouterState.of(context).uri.toString();

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
              selected: currentRoute == '/settings',
              onTap: () => GoRouter.of(context).go('/settings'),
            ),
            // AI Chat section
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('AI Chat'),
              trailing: Icon(
                _aiChatExpanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
              onTap: () => setState(() => _aiChatExpanded = !_aiChatExpanded),
            ),
            if (_aiChatExpanded)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 40, right: 16),
                leading: const Icon(Icons.memory, size: 20),
                title: const Text('Models'),
                selected: currentRoute == '/settings/aichat-models',
                onTap: () => GoRouter.of(context).go('/settings/aichat-models'),
              ),
          ],
        ),
      ),
    );
  }
}
