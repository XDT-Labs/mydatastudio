import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/widgets/source_tile.dart';

enum EmailSourceGroup {
  popular('Popular'),
  more('More providers'),
  other('Other ways to add mail');

  const EmailSourceGroup(this.label);
  final String label;
}

/// Which setup form a source opens.
enum EmailSourceForm { imap, outlook, pstFile }

/// One tile in the "add email" catalog. A tile can cover several registry
/// entries (GMX); the first is the default until the address says otherwise.
class EmailSource {
  const EmailSource({
    required this.id,
    required this.group,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.form,
    this.providers = const [],
  });

  final String id;
  final EmailSourceGroup group;
  final String title;
  final String subtitle;
  final IconData icon;
  final EmailSourceForm form;
  final List<EmailProvider> providers;

  /// How many of [accounts] came from this source. Legacy rows have no provider
  /// id, so they are matched by scanner.
  int addedCount(List<Collection> accounts) => accounts.where(_owns).length;

  bool _owns(Collection c) {
    if (c.scanner == AppConstants.scannerEmailOutlookPst) {
      return form == EmailSourceForm.pstFile;
    }
    final providerId =
        c.emailProviderId ??
        EmailProviderRegistry.forLegacyScanner(c.scanner)?.id;
    return providers.any((p) => p.id == providerId);
  }

  static const catalog = <EmailSource>[
    EmailSource(
      id: 'gmail',
      group: EmailSourceGroup.popular,
      title: 'Gmail',
      subtitle: 'Use an app password',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.gmail],
    ),
    EmailSource(
      id: 'outlook',
      group: EmailSourceGroup.popular,
      title: 'Outlook and Microsoft 365',
      subtitle: 'Sign in with Microsoft',
      icon: Icons.mail_outline,
      form: EmailSourceForm.outlook,
      providers: [EmailProviderRegistry.outlook],
    ),
    EmailSource(
      id: 'yahoo',
      group: EmailSourceGroup.popular,
      title: 'Yahoo Mail',
      subtitle: 'Use an app password',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.yahoo],
    ),
    EmailSource(
      id: 'icloud',
      group: EmailSourceGroup.popular,
      title: 'iCloud Mail',
      subtitle: 'Use an app password',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.icloud],
    ),
    EmailSource(
      id: 'aol',
      group: EmailSourceGroup.more,
      title: 'AOL and Verizon',
      subtitle: 'aol.com, verizon.net',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.aol],
    ),
    EmailSource(
      id: 'att',
      group: EmailSourceGroup.more,
      title: 'AT&T Mail',
      subtitle: 'att.net, sbcglobal.net',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.att],
    ),
    EmailSource(
      id: 'fastmail',
      group: EmailSourceGroup.more,
      title: 'Fastmail',
      subtitle: 'fastmail.com, fastmail.fm',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.fastmail],
    ),
    EmailSource(
      id: 'gmx',
      group: EmailSourceGroup.more,
      title: 'GMX',
      subtitle: 'gmx.com, gmx.de',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.gmxCom, EmailProviderRegistry.gmxDe],
    ),
    EmailSource(
      id: 'mailcom',
      group: EmailSourceGroup.more,
      title: 'mail.com',
      subtitle: 'mail.com, email.com',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.mailCom],
    ),
    EmailSource(
      id: 'webde',
      group: EmailSourceGroup.more,
      title: 'WEB.DE',
      subtitle: 'web.de',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.webDe],
    ),
    EmailSource(
      id: 'yandex',
      group: EmailSourceGroup.more,
      title: 'Yandex Mail',
      subtitle: 'yandex.com, yandex.ru',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.yandex],
    ),
    EmailSource(
      id: 'zoho',
      group: EmailSourceGroup.more,
      title: 'Zoho Mail',
      subtitle: 'zoho.com, zohomail.com',
      icon: Icons.mail_outline,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.zoho],
    ),
    EmailSource(
      id: 'other',
      group: EmailSourceGroup.other,
      title: 'Other email account',
      subtitle: 'Any IMAP server',
      icon: Icons.dns_outlined,
      form: EmailSourceForm.imap,
      providers: [EmailProviderRegistry.other],
    ),
    EmailSource(
      id: 'pst',
      group: EmailSourceGroup.other,
      title: 'Outlook PST file',
      subtitle: 'Import from this Mac',
      icon: Icons.upload_file_outlined,
      form: EmailSourceForm.pstFile,
    ),
  ];
}

/// Searchable, grouped grid of [EmailSource] tiles. An email address typed into
/// the search box narrows the grid to the card for that address, and is handed
/// to [onSelected] so it doesn't have to be typed again.
class EmailSourceCatalog extends StatefulWidget {
  const EmailSourceCatalog({
    super.key,
    required this.accounts,
    required this.onSelected,
  });

  /// Existing collections, for the "added" counts. People can have several
  /// accounts with one provider, so an added source stays selectable.
  final List<Collection> accounts;
  final void Function(EmailSource source, String? email) onSelected;

  @override
  State<EmailSourceCatalog> createState() => _EmailSourceCatalogState();
}

class _EmailSourceCatalogState extends State<EmailSourceCatalog> {
  String _query = '';

  String get _trimmedQuery => _query.trim().toLowerCase();

  bool _matches(EmailSource s) {
    final q = _trimmedQuery;
    if (q.isEmpty) return true;
    if (q.contains('@')) {
      return s.providers.contains(EmailProviderRegistry.detectFromEmail(q));
    }
    return s.title.toLowerCase().contains(q) ||
        s.subtitle.toLowerCase().contains(q) ||
        s.providers.any((p) => p.domains.any((d) => d.contains(q)));
  }

  @override
  Widget build(BuildContext context) {
    final visible = EmailSource.catalog.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: 'Search providers or enter your email address',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 24),
        for (final group in EmailSourceGroup.values)
          ..._section(context, group, visible),
        if (visible.isEmpty)
          Text(
            'No providers match "$_query".',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
      ],
    );
  }

  List<Widget> _section(
    BuildContext context,
    EmailSourceGroup group,
    List<EmailSource> visible,
  ) {
    final items = visible.where((s) => s.group == group).toList();
    if (items.isEmpty) return const [];
    final email = _trimmedQuery.contains('@') ? _query.trim() : null;
    return [
      Text(
        group.label,
        key: ValueKey('group-${group.name}'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      SourceTileGrid(
        children: [
          for (final s in items)
            SourceTile(
              key: ValueKey('source-${s.id}'),
              title: s.title,
              subtitle: s.subtitle,
              icon: s.icon,
              badges: [
                if (s.addedCount(widget.accounts) > 0)
                  SourceBadge('${s.addedCount(widget.accounts)} added'),
              ],
              onTap: () => widget.onSelected(s, email),
            ),
        ],
      ),
      const SizedBox(height: 28),
    ];
  }
}
