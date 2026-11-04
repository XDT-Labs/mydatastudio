import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/email_source_catalog.dart';

Collection _account(String scanner, {String? providerId}) => Collection(
  id: 'c-$scanner-$providerId',
  name: 'account',
  path: '',
  type: 'email',
  scanner: scanner,
  scanStatus: 'idle',
  needsReAuth: false,
  emailProviderId: providerId,
);

EmailSource _source(String id) =>
    EmailSource.catalog.firstWhere((s) => s.id == id);

void main() {
  group('EmailSource.catalog', () {
    test('every provider in the registry has a card', () {
      // A provider left out here can't be added from the page, except by
      // someone who knows to type its address into "Other email account".
      final covered = EmailSource.catalog.expand((s) => s.providers).toSet();
      expect(covered, containsAll(EmailProviderRegistry.all));
    });

    test('domains shown on a card belong to that card', () {
      // The subtitle tells people which card is theirs, so it can't drift away
      // from what the registry actually recognises.
      for (final s in EmailSource.catalog) {
        if (s.group != EmailSourceGroup.more) continue;
        for (final domain in s.subtitle.split(', ')) {
          expect(
            s.providers,
            contains(EmailProviderRegistry.detectFromEmail('me@$domain')),
            reason: '${s.id}: $domain',
          );
        }
      }
    });
  });

  group('EmailSource.addedCount', () {
    test('counts IMAP accounts by provider, across a merged card', () {
      final accounts = [
        _account(AppConstants.scannerEmailImap, providerId: 'gmx_com'),
        _account(AppConstants.scannerEmailImap, providerId: 'gmx_de'),
        _account(AppConstants.scannerEmailImap, providerId: 'gmail'),
      ];
      expect(_source('gmx').addedCount(accounts), 2);
      expect(_source('gmail').addedCount(accounts), 1);
      expect(_source('yahoo').addedCount(accounts), 0);
    });

    test('legacy rows without a provider id still count', () {
      final accounts = [_account(AppConstants.scannerEmailYahoo)];
      expect(_source('yahoo').addedCount(accounts), 1);
    });

    test('a PST import counts for the PST card, not the Outlook account', () {
      final accounts = [_account(AppConstants.scannerEmailOutlookPst)];
      expect(_source('pst').addedCount(accounts), 1);
      expect(_source('outlook').addedCount(accounts), 0);
    });
  });

  group('EmailSourceCatalog', () {
    EmailSource? selected;
    String? selectedEmail;

    Future<void> pump(
      WidgetTester tester, {
      List<Collection> accounts = const [],
    }) async {
      selected = null;
      selectedEmail = null;
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailSourceCatalog(
              accounts: accounts,
              onSelected: (s, email) {
                selected = s;
                selectedEmail = email;
              },
            ),
          ),
        ),
      );
    }

    testWidgets('groups cards in order of how likely they are to be wanted', (
      tester,
    ) async {
      await pump(tester);
      double top(String key) =>
          tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(top('group-popular'), lessThan(top('group-more')));
      expect(top('group-more'), lessThan(top('group-other')));
      expect(top('source-gmail'), lessThan(top('group-more')));
      expect(top('source-pst'), greaterThan(top('group-other')));
    });

    testWidgets('a source with an account stays selectable and shows a count', (
      tester,
    ) async {
      await pump(
        tester,
        accounts: [
          _account(AppConstants.scannerEmailImap, providerId: 'gmail'),
          _account(AppConstants.scannerEmailImap, providerId: 'gmail'),
        ],
      );
      expect(find.text('2 added'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-gmail')));
      expect(selected?.id, 'gmail');
    });

    testWidgets('search also finds a provider by a domain not on its card', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'bellsouth');
      await tester.pump();
      expect(find.byKey(const ValueKey('source-att')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-gmail')), findsNothing);
    });

    testWidgets('an address narrows to its card and carries through', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), ' Me@verizon.net ');
      await tester.pump();
      expect(find.byKey(const ValueKey('source-aol')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-gmail')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-aol')));
      expect(selectedEmail, 'Me@verizon.net');
    });

    testWidgets('an unknown domain leads to "Other email account"', (
      tester,
    ) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'me@example.org');
      await tester.pump();
      expect(find.byKey(const ValueKey('source-other')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-pst')), findsNothing);
    });

    testWidgets('plain search passes no email to the form', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'yahoo');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('source-yahoo')));
      expect(selected?.id, 'yahoo');
      expect(selectedEmail, isNull);
    });
  });
}
