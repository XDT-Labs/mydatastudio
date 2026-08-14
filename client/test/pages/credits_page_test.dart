import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/pages/credits_page.dart';

/// The gazetteer shipped with this app is CC BY 4.0, and attribution is the
/// entire obligation that licence imposes. If this page stops naming GeoNames
/// the app is distributing the data in breach of its licence — which no other
/// test would notice.
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
      home: child,
    );
  }

  testWidgets('credits the gazetteer and names its licence', (tester) async {
    await tester.pumpWidget(wrap(const CreditsPage()));
    await tester.pumpAndSettle();

    expect(find.text('GeoNames'), findsOneWidget);
    expect(find.text('Creative Commons Attribution 4.0'), findsOneWidget);
  });

  testWidgets('links to the licence and the source', (tester) async {
    // A named licence the reader cannot go and read is a weak credit.
    const geonames = CreditsPage.credits;

    expect(geonames.single.licenceUrl, contains('creativecommons.org'));
    expect(geonames.single.sourceUrl, contains('geonames.org'));

    await tester.pumpWidget(wrap(const CreditsPage()));
    await tester.pumpAndSettle();

    expect(find.text('License'), findsOneWidget);
    expect(find.text('Source'), findsOneWidget);
  });

  testWidgets('offers the bundled package licences too', (tester) async {
    await tester.pumpWidget(wrap(const CreditsPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Package licenses'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
  });
}
