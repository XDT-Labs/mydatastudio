import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/import_dialog.dart';

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(body: child),
  );
}

void main() {
  group('ImportDialog Widget Tests', () {
    testWidgets('renders import dialog title and file selection area', (
      tester,
    ) async {
      await tester.pumpWidget(createTestApp(const ImportDialog()));
      await tester.pumpAndSettle();

      expect(find.text('Import Photos & Videos'), findsOneWidget);
      expect(find.text('Click to select images or videos'), findsOneWidget);
      expect(
        find.text('Supports PNG, JPG, WEBP, MP4, MOV, etc.'),
        findsOneWidget,
      );
      expect(find.text('Import'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('cancel button closes dialog', (tester) async {
      bool dialogClosed = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: darkColorScheme),
          home: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  final result = await showDialog<bool>(
                    context: context,
                    builder: (_) => const ImportDialog(),
                  );
                  if (result == false) dialogClosed = true;
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.byType(ImportDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(ImportDialog), findsNothing);
      expect(dialogClosed, isTrue);
    });
  });
}
