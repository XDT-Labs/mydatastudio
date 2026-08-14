import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/info_row.dart';

void main() {
  group('infoRow & infoRowSelectable', () {
    testWidgets('infoRow renders label and value text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: infoRow('Name', 'my_file.png'),
          ),
        ),
      );

      expect(find.text('Name'), findsOneWidget);
      expect(find.text('my_file.png'), findsOneWidget);
    });

    testWidgets('infoRowSelectable renders label and selectable value text without hardcoded black color', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: infoRowSelectable('Path', '/users/home/my_file.png'),
          ),
        ),
      );

      expect(find.text('Path'), findsOneWidget);
      final selectableTextFinder = find.byType(SelectableText);
      expect(selectableTextFinder, findsOneWidget);

      final SelectableText widget = tester.widget(selectableTextFinder);
      expect(widget.data, '/users/home/my_file.png');
      expect(widget.style?.color, isNull);
    });
  });
}
