import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/services/address_parser.dart';

void main() {
  group('AddressParser.parseOne', () {
    test('parses "Display Name <addr>" from a real "from" header', () {
      // The contacts index shows this name in the UI; if display-name
      // extraction regresses, every contact card falls back to a bare
      // email address.
      final result = AddressParser.parseOne(
        'Google Payments <payments-noreply@google.com>',
      );
      expect(result, isNotNull);
      expect(result!.displayName, 'Google Payments');
      expect(result.address, 'payments-noreply@google.com');
      expect(result.localPart, 'payments-noreply');
    });

    test('strips surrounding quotes but keeps inner brackets verbatim', () {
      // Bot senders like GitHub's coderabbitai wrap the name in quotes
      // specifically because it contains "[bot]" - a naive quote-strip
      // that also ate inner characters would mangle real sender names.
      final result = AddressParser.parseOne(
        '"coderabbitai[bot]" <notifications@github.com>',
      );
      expect(result, isNotNull);
      expect(result!.displayName, 'coderabbitai[bot]');
      expect(result.address, 'notifications@github.com');
    });

    test('bare address has no display name', () {
      final result = AddressParser.parseOne('mike@xdtlabs.com');
      expect(result, isNotNull);
      expect(result!.displayName, isNull);
      expect(result.address, 'mike@xdtlabs.com');
      expect(result.localPart, 'mike');
    });

    test('lowercases the address but preserves display-name casing', () {
      // The index key must be case-insensitive (see class doc), but the
      // name shown to the user should still look like a real name.
      final result = AddressParser.parseOne('Bob Smith <Bob@X.COM>');
      expect(result!.address, 'bob@x.com');
      expect(result.displayName, 'Bob Smith');
    });

    test('angle brackets with surrounding whitespace trim correctly', () {
      final result = AddressParser.parseOne('Name < addr@x.com >');
      expect(result!.address, 'addr@x.com');
      expect(result.displayName, 'Name');
    });

    test('multiple @ signs: whole text is the address, localPart is '
        'before the first @', () {
      // Malformed but real-world headers exist; localPart drives
      // autocomplete ranking, so it must stay anchored to the first '@'
      // rather than throwing or picking the last one.
      final result = AddressParser.parseOne('a@b@c.com');
      expect(result!.address, 'a@b@c.com');
      expect(result.localPart, 'a');
    });

    test('unterminated angle bracket degrades instead of throwing', () {
      expect(() => AddressParser.parseOne('Name <addr@x.com'), returnsNormally);
      final result = AddressParser.parseOne('Name <addr@x.com');
      expect(result!.address, 'addr@x.com');
    });

    test('unterminated quote degrades instead of throwing', () {
      expect(
        () => AddressParser.parseOne('"Name <addr@x.com>'),
        returnsNormally,
      );
      final result = AddressParser.parseOne('"Name <addr@x.com>');
      expect(result!.address, 'addr@x.com');
    });

    test('no @ means no usable address', () {
      expect(AddressParser.parseOne('not-an-address'), isNull);
    });

    test('null, empty, and whitespace-only input return null', () {
      expect(AddressParser.parseOne(null), isNull);
      expect(AddressParser.parseOne(''), isNull);
      expect(AddressParser.parseOne('   '), isNull);
    });
  });

  group('AddressParser.parseList', () {
    test('parses a comma-joined list of bare addresses (real "to" data)', () {
      final result = AddressParser.parseList(
        'mike@xdtlabs.com,mnimer@gmail.com',
      );
      expect(result.length, 2);
      expect(result.map((a) => a.address), [
        'mike@xdtlabs.com',
        'mnimer@gmail.com',
      ]);
    });

    test('parses three bare addresses from real "cc" data', () {
      final result = AddressParser.parseList(
        'bmageau@hotmail.com,dave_meier@comcast.net,shelleyinfog@comcast.net',
      );
      expect(result.length, 3);
    });

    test('a comma inside a quoted display name does not split that entry', () {
      // This is the case a naive `split(',')` breaks: the quoted name
      // has its own comma, so a length-based split would produce three
      // segments (one broken) instead of two clean addresses.
      final result = AddressParser.parseList(
        '"Nimer, Mike" <mike@x.com>,bob@y.com',
      );
      expect(result.length, 2);
      expect(result[0].displayName, 'Nimer, Mike');
      expect(result[0].address, 'mike@x.com');
      expect(result[1].address, 'bob@y.com');
    });

    test('dedupes case-variant duplicates, keeping the first display name', () {
      // Real measured data has the same mailbox appear with different
      // casing across messages; the contacts index must collapse these
      // to one contact, not fragment it.
      final result = AddressParser.parseList('Bob Jones <Bob@X.COM>,bob@x.com');
      expect(result.length, 1);
      expect(result.single.address, 'bob@x.com');
      expect(result.single.displayName, 'Bob Jones');
    });

    test('skips unparseable entries instead of throwing', () {
      final result = AddressParser.parseList(
        'mike@xdtlabs.com,not-an-address,bob@y.com',
      );
      expect(result.map((a) => a.address), ['mike@xdtlabs.com', 'bob@y.com']);
    });

    test('trailing/leading commas and empty segments are skipped', () {
      final result = AddressParser.parseList(',mike@xdtlabs.com,,bob@y.com,');
      expect(result.length, 2);
    });

    test('unterminated quote in a list entry degrades without throwing', () {
      expect(
        () => AddressParser.parseList('"Open Quote <a@x.com>,b@y.com'),
        returnsNormally,
      );
    });

    test('unterminated angle bracket in a list entry degrades without '
        'throwing', () {
      expect(
        () => AddressParser.parseList('Name <a@x.com,b@y.com'),
        returnsNormally,
      );
    });

    test('null, empty, and whitespace-only input return an empty list', () {
      expect(AddressParser.parseList(null), isEmpty);
      expect(AddressParser.parseList(''), isEmpty);
      expect(AddressParser.parseList('   '), isEmpty);
    });
  });
}
