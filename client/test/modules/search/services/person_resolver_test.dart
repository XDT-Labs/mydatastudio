import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
import 'package:mydatastudio/modules/search/services/person_resolver.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/search_filters.dart';

/// An address index without a database behind it.
///
/// Matches the substring behaviour of the real
/// [EmailContactRepository.resolveName] — ordered wildcards over display name
/// and address — because the resolver's whole job is deciding which of those
/// loose matches is specific enough to build a *filter* from. A fake that only
/// returned exact matches would make every one of those tests pass vacuously.
class _FakeContacts implements EmailContactRepository {
  _FakeContacts(this.rows);

  final List<EmailContact> rows;

  @override
  Future<List<EmailContact>> resolveName(String name, {int limit = 10}) async {
    final pattern = RegExp(
      '.*${name.trim().split(RegExp(r'\s+')).map(RegExp.escape).join('.*')}.*',
      caseSensitive: false,
    );
    final matched =
        rows
            .where(
              (c) =>
                  pattern.hasMatch(c.displayName ?? '') ||
                  pattern.hasMatch(c.address),
            )
            .toList()
          ..sort((a, b) => b.messageCount.compareTo(a.messageCount));
    return matched.take(limit).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not needed here');
}

EmailContact _contact(
  String address, {
  String? displayName,
  int messageCount = 1,
}) {
  return EmailContact(
    address: address,
    displayName: displayName,
    localPart: address.split('@').first,
    messageCount: messageCount,
    sentCount: 0,
  );
}

/// The archive these tests describe. Deliberately built from the shapes that
/// actually appear in a real mailbox: one person on two addresses, two
/// different people sharing a first name, and a company whose name contains a
/// common English word.
final _archive = _FakeContacts([
  _contact('mnimer@allaire.com', displayName: 'Mike Nimer', messageCount: 6889),
  _contact(
    'mike@digitalchef.com',
    displayName: 'Mike Nimer',
    messageCount: 1853,
  ),
  _contact('mike.jones@corp.com', displayName: 'Mike Jones', messageCount: 40),
  _contact('sarah@example.com', displayName: 'Sarah Chen', messageCount: 210),
  _contact('joanne@example.com', displayName: 'Joanne Reed', messageCount: 12),
  _contact('sales@networksolutions.com', displayName: 'Network Solutions'),
]);

Future<ParsedQuery> _resolve(String raw, {_FakeContacts? contacts}) {
  final resolver = PersonResolver.withRepository(contacts ?? _archive);
  return resolver.resolve(QueryParser.parse(raw));
}

void main() {
  group('PersonResolver — prose becomes the same plan as syntax', () {
    test(
      'prose and colon syntax produce an identical sender constraint',
      () async {
        // The load-bearing assertion of search-plan section 2b. If these two ever
        // diverge, natural-language queries quietly lose their filter and start
        // returning other people's mail — which looks like a ranking problem and
        // is not one.
        final prose = await _resolve(
          'emails from sarah chen about the invoice',
        );
        final syntax = QueryParser.parse(
          'from:sarah@example.com about the invoice',
        );

        expect(prose.filtersFor(FilterField.from).map((f) => f.value), [
          'sarah@example.com',
        ]);
        expect(
          SearchFilters.forEmails(prose)?.sql,
          SearchFilters.forEmails(syntax)?.sql,
        );
      },
    );

    test('the name and its preposition leave the free text', () async {
      // FTS5 joins terms with an implicit AND, so a leftover "from" or "sarah"
      // would demand those words of every row — excluding exactly the mail the
      // filter just selected.
      final resolved = await _resolve(
        'emails from sarah chen about the invoice',
      );
      expect(resolved.freeText, 'about the invoice');
    });

    test('a person on several addresses resolves to all of them', () async {
      // Choosing one would silently drop half the answer, and there is no
      // signal here that says which half.
      final resolved = await _resolve('emails from mike nimer');
      expect(
        resolved.filtersFor(FilterField.from).map((f) => f.value).toSet(),
        {'mnimer@allaire.com', 'mike@digitalchef.com'},
      );
    });

    test(
      'several addresses OR together instead of excluding each other',
      () async {
        // No message has two senders, so AND'ing these can only return nothing.
        final resolved = await _resolve('emails from mike nimer');
        final where = SearchFilters.forEmails(resolved)!.sql;
        expect(where, contains(' OR '));
        expect(
          where,
          isNot(contains('LIKE ? COLLATE NOCASE AND e."from" LIKE')),
        );
      },
    );

    test('to resolves against the recipient, not the sender', () async {
      final resolved = await _resolve('emails to sarah chen');
      expect(resolved.filtersFor(FilterField.to).map((f) => f.value), [
        'sarah@example.com',
      ]);
      expect(resolved.filtersFor(FilterField.from), isEmpty);
    });
  });

  group('PersonResolver — what it refuses to resolve', () {
    test('a name matching nothing is left as free text', () async {
      // Section 2d: an unresolvable person falls back to ranked retrieval over
      // the words. Dropping them instead would search for less than was asked.
      final resolved = await _resolve('emails from russel jong');
      expect(resolved.filtersFor(FilterField.from), isEmpty);
      expect(resolved.freeText, 'from russel jong');
    });

    test('a single word only resolves on a whole-name match', () async {
      // resolveName matches substrings, which is right for autocomplete and
      // wrong for a filter that removes results: "ann" is inside "Joanne", and
      // a hard sender filter built on that hides everything else with no sign
      // anything went wrong.
      final resolved = await _resolve('emails from ann');
      expect(resolved.filtersFor(FilterField.from), isEmpty);
      expect(resolved.freeText, 'from ann');
    });

    test(
      'a common word that happens to sit inside a company name is not a person',
      () async {
        // "Network Solutions" contains "work". Without a stoplist, "notes from
        // work" becomes a hard filter on that company's mail.
        final resolved = await _resolve('notes from work');
        expect(resolved.filtersFor(FilterField.from), isEmpty);
        expect(resolved.freeText, contains('from work'));
      },
    );

    test('an explicit from: outranks anything inferred from prose', () async {
      // The user already supplied the address. A second constraint on the same
      // field, OR'd in, would widen what they narrowed on purpose.
      final resolved = await _resolve(
        'from:sarah@example.com notes from mike nimer',
      );
      expect(resolved.filtersFor(FilterField.from).map((f) => f.value), [
        'sarah@example.com',
      ]);
      expect(resolved.freeText, contains('from mike nimer'));
    });
  });

  group('PersonResolver — where the name ends', () {
    test('prefers the longest name that resolves', () async {
      // "mike" alone matches three people including two different humans;
      // "mike jones" matches one. Taking the short match first would turn a
      // specific query into a broad one.
      final resolved = await _resolve('emails from mike jones');
      expect(resolved.filtersFor(FilterField.from).map((f) => f.value), [
        'mike.jones@corp.com',
      ]);
    });

    test('a name cannot swallow the next preposition', () async {
      final resolved = await _resolve('emails from mike jones to sarah chen');
      expect(resolved.filtersFor(FilterField.from).map((f) => f.value), [
        'mike.jones@corp.com',
      ]);
      expect(resolved.filtersFor(FilterField.to).map((f) => f.value), [
        'sarah@example.com',
      ]);
      expect(resolved.freeText, isEmpty);
    });
  });

  group('PersonResolver — with/between become participant', () {
    test('with matches the person in any role, not just as sender', () async {
      // "My emails with Sarah" is the whole correspondence. A thread alternates
      // direction with every reply, so resolving this to from: would return
      // half of it and look like missing mail.
      final resolved = await _resolve('emails with sarah chen');
      expect(resolved.filtersFor(FilterField.participant).map((f) => f.value), [
        'sarah@example.com',
      ]);
      expect(resolved.filtersFor(FilterField.from), isEmpty);

      final sql = SearchFilters.forEmails(resolved)!.sql;
      expect(sql, contains('e."from" LIKE'));
      expect(sql, contains('e."to" LIKE'));
      expect(sql, contains('e.cc LIKE'));
    });

    test('between resolves both people, and requires both', () async {
      final resolved = await _resolve(
        'emails between mike jones and sarah chen',
      );
      expect(
        resolved
            .filtersFor(FilterField.participant)
            .map((f) => f.value)
            .toSet(),
        {'mike.jones@corp.com', 'sarah@example.com'},
      );
      expect(resolved.freeText, isEmpty);

      // Two people means both were there. OR'ing them would answer with every
      // message either of them ever touched — not a conversation between them,
      // and a far larger set than the question implies.
      final filter = SearchFilters.forEmails(resolved)!;
      expect(filter.sql, contains(') AND ('));
      expect(filter.params.length, 6, reason: 'three columns per person');
    });

    test(
      "one person's several addresses stay OR'd inside their own clause",
      () async {
        // The counterpart to the test above: AND across people, OR within one.
        // A message carries one sender, so AND'ing an individual's addresses
        // matches nothing at all.
        final resolved = await _resolve('emails with mike nimer');
        expect(resolved.filtersFor(FilterField.participant).length, 2);

        final filter = SearchFilters.forEmails(resolved)!;
        expect(filter.sql, isNot(contains(') AND (')));
        expect(filter.params.length, 6);
      },
    );

    test('and is not consumed for a directional field', () async {
      // "from mike and sarah" means either — a message has one sender — while
      // "between mike and sarah" means both. Treating them alike would silently
      // swap one combinator for the other.
      final resolved = await _resolve('emails from mike jones and sarah chen');
      expect(resolved.filtersFor(FilterField.from).map((f) => f.value), [
        'mike.jones@corp.com',
      ]);
      expect(resolved.filtersFor(FilterField.participant), isEmpty);
      expect(resolved.freeText, 'and sarah chen');
    });

    test('a participant query cannot be satisfied by a file', () async {
      // Mail-only, like from:/to:/cc:. Returning photos for "emails with sarah"
      // would look like the filter was ignored.
      final resolved = await _resolve('emails with sarah chen');
      expect(SearchFilters.forFiles(resolved), isNull);
    });

    test(
      'participant: is typeable, and typed repeats OR like any field',
      () async {
        // Nothing the user types carries source text, so they form one group.
        // That keeps the documented behaviour for repeats of a typed field.
        final typed = QueryParser.parse(
          'participant:a@x.com participant:b@x.com',
        );
        final filter = SearchFilters.forEmails(typed)!;
        expect(filter.sql, isNot(contains(') AND (')));
        expect(filter.params.length, 6);
      },
    );
  });

  group('PersonResolver — the chip stays correctable', () {
    test('an inferred filter carries the words it came from', () async {
      // Removing a chip works by deleting the token it came from. A resolved
      // filter's value is an address that appears nowhere in the raw query, so
      // without this the delete matches nothing and the chip looks broken.
      final resolved = await _resolve('emails from sarah chen');
      final filter = resolved.filtersFor(FilterField.from).single;
      expect(filter.isInferred, isTrue);
      expect(filter.sourceText, 'from sarah chen');
      expect(resolved.raw.contains(filter.sourceText!), isTrue);
    });

    test('a typed filter carries no source text', () async {
      final parsed = QueryParser.parse('from:sarah@example.com');
      expect(parsed.filters.single.isInferred, isFalse);
    });
  });
}
