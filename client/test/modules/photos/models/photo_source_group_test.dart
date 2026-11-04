import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/modules/photos/models/photo_source_group.dart';

void main() {
  // The Photos drawer and the hide dialog must tell the user the same source
  // name; a generic IMAP collection is still "their Yahoo mail" to them.
  group('photoSourceGroupFor email.imap', () {
    test('groups by provider so it matches the legacy scanners', () {
      expect(
        photoSourceGroupFor(
          AppConstants.scannerEmailImap,
          emailProviderId: 'yahoo',
        ),
        photoSourceGroupFor(AppConstants.scannerEmailYahoo),
      );
      expect(
        photoSourceGroupFor(
          AppConstants.scannerEmailImap,
          emailProviderId: 'outlook',
        ),
        photoSourceGroupFor(AppConstants.scannerEmailOutlook),
      );
    });

    test('providers without their own group fall into other', () {
      for (final id in ['icloud', 'aol', 'fastmail', 'other', null]) {
        expect(
          photoSourceGroupFor(
            AppConstants.scannerEmailImap,
            emailProviderId: id,
          ),
          PhotoSourceGroup.other,
        );
      }
    });

    test('legacy scanners are unchanged without a provider id', () {
      expect(
        photoSourceGroupFor(AppConstants.scannerEmailYahoo),
        PhotoSourceGroup.yahoo,
      );
      expect(
        photoSourceGroupFor(AppConstants.scannerEmailOutlookPst),
        PhotoSourceGroup.outlook,
      );
    });
  });
}
