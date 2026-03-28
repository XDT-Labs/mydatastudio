import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details/text_preview_widget.dart';

import '../../../../helpers/file_fixture.dart';

void main() {
  group('TextPreviewWidget', () {
    testWidgets('renders injected plain text content', (tester) async {
      final file = makeTestFile(name: 'readme.txt', contentType: 'text/plain');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextPreviewWidget(
              file: file,
              ext: '.txt',
              previewHeight: 300,
              initialContent: 'hello world',
              onSave: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('hello world'), findsOneWidget);
    });

    testWidgets('shows Edit button for markdown files', (tester) async {
      final file = makeTestFile(name: 'note.md', path: '/tmp/note.md', contentType: 'text/markdown');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextPreviewWidget(
              file: file,
              ext: '.md',
              previewHeight: 300,
              initialContent: '# heading',
              onSave: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit_button')), findsOneWidget);
    });

    testWidgets('calls onSave with edited content', (tester) async {
      String? savedContent;
      final file = makeTestFile(name: 'note.md', path: '/tmp/note.md', contentType: 'text/markdown');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextPreviewWidget(
              file: file,
              ext: '.md',
              previewHeight: 300,
              initialContent: 'original',
              onSave: (c) async => savedContent = c,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit_button')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'updated content');
      await tester.tap(find.byKey(const Key('save_button')));
      await tester.pumpAndSettle();
      expect(savedContent, equals('updated content'));
    });

    testWidgets('hides Edit button for non-markdown text', (tester) async {
      final file = makeTestFile(name: 'log.txt', contentType: 'text/plain');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextPreviewWidget(
              file: file,
              ext: '.txt',
              previewHeight: 300,
              initialContent: 'log output',
              onSave: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit_button')), findsNothing);
    });
  });
}
