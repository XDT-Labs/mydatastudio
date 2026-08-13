import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// One piece of third-party work the app ships and has to credit.
class Credit {
  const Credit({
    required this.title,
    required this.description,
    required this.licence,
    required this.licenceUrl,
    required this.sourceUrl,
    required this.usedFor,
  });

  final String title;
  final String description;
  final String licence;
  final String licenceUrl;
  final String sourceUrl;

  /// Where in the app it shows up, so this page says something a reader
  /// cannot get from a licence file.
  final String usedFor;
}

/// Attribution for the third-party data and code bundled into the app.
///
/// Not optional decoration: the embedded gazetteer is CC BY 4.0, whose whole
/// requirement is that the credit travels with the work. Shipping the data
/// without a screen the user can actually reach would breach the licence.
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key});

  static const List<Credit> credits = [
    Credit(
      title: 'GeoNames',
      description:
          'A worldwide list of populated places, with coordinates, regions '
          'and populations.',
      licence: 'Creative Commons Attribution 4.0',
      licenceUrl: 'https://creativecommons.org/licenses/by/4.0/',
      sourceUrl: 'https://www.geonames.org/',
      usedFor:
          'Searching for a city in Photos → Locations, so photos can be '
          'filtered by where they were taken. The place list is embedded in '
          'the app — no location data ever leaves this machine.',
    ),
  ];

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(title: const Text('Credits & Licenses')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'My Data Studio is built on work published by others. '
            'The data and code below ship inside the app.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 24),

          Text('Embedded data', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...credits.map(
            (credit) => _CreditCard(credit: credit, onOpen: _open),
          ),

          const SizedBox(height: 24),
          Text('Open source software', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('Package licenses'),
              subtitle: Text(
                'Every open source package this app is built from, with its '
                'full licence text.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'My Data Studio',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreditCard extends StatelessWidget {
  const _CreditCard({required this.credit, required this.onOpen});

  final Credit credit;
  final Future<void> Function(String url) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(credit.title, style: theme.textTheme.titleSmall),
                ),
                Chip(
                  label: Text(
                    credit.licence,
                    style: theme.textTheme.labelSmall,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(credit.description, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(
              credit.usedFor,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Source'),
                  onPressed: () => onOpen(credit.sourceUrl),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.gavel_outlined, size: 16),
                  label: const Text('License'),
                  onPressed: () => onOpen(credit.licenceUrl),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
