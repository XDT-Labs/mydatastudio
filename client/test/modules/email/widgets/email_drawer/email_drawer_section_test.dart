import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer.dart';

void main() {
  // New IMAP collections share one scanner id, so the drawer must group them by
  // provider or a Yahoo account would land under "Other".
  group('emailAccordionSectionFor', () {
    test('email.imap groups by provider id', () {
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailImap, 'yahoo'),
        EmailAccordionSection.yahoo,
      );
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailImap, 'outlook'),
        EmailAccordionSection.outlook,
      );
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailImap, 'gmail'),
        EmailAccordionSection.gmail,
      );
    });

    test('email.imap with other providers goes to other', () {
      for (final id in ['icloud', 'aol', 'fastmail', 'other', null]) {
        expect(
          emailAccordionSectionFor(AppConstants.scannerEmailImap, id),
          EmailAccordionSection.other,
        );
      }
    });

    test('legacy scanners keep their sections', () {
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailYahoo, null),
        EmailAccordionSection.yahoo,
      );
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailOutlook, null),
        EmailAccordionSection.outlook,
      );
      expect(
        emailAccordionSectionFor(AppConstants.scannerEmailOutlookPst, null),
        EmailAccordionSection.outlook,
      );
    });
  });
}
