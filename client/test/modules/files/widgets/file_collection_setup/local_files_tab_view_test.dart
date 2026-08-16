import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/local_files_tab_view.dart';

void main() {
  group('LocalFilesTabView', () {
    late GlobalKey<FormState> formKey;
    late TextEditingController name;
    late TextEditingController path;

    setUp(() {
      formKey = GlobalKey<FormState>();
      name = TextEditingController();
      path = TextEditingController();
    });

    tearDown(() {
      name.dispose();
      path.dispose();
    });

    testWidgets('renders name and path fields', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalFilesTabView(
              formKey: formKey,
              nameController: name,
              pathController: path,
              onBrowse: () {},
              onSave: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      expect(find.text('Name *'), findsOneWidget);
      expect(find.text('Folder *'), findsOneWidget);
    });

    testWidgets('Browse button calls onBrowse', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalFilesTabView(
              formKey: formKey,
              nameController: name,
              pathController: path,
              onBrowse: () => called = true,
              onSave: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('Browse'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('Add Folder button calls onSave', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalFilesTabView(
              formKey: formKey,
              nameController: name,
              pathController: path,
              onBrowse: () {},
              onSave: () => called = true,
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('Add Folder'));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('Cancel button calls onCancel', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalFilesTabView(
              formKey: formKey,
              nameController: name,
              pathController: path,
              onBrowse: () {},
              onSave: () {},
              onCancel: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Cancel'));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
