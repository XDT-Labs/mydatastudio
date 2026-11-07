import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pdf_preview_widget.dart';
import 'package:pdfrx/pdfrx.dart';

class _FakePage implements PdfPage {
  _FakePage(this.width, this.height);

  @override
  final double width;
  @override
  final double height;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('PdfPreviewWidget', () {
    testWidgets('shows loading indicator on first pump', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: PdfPreviewWidget(
              filePath: '/tmp/nonexistent.pdf',
              previewHeight: 300,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    // Opening a real document needs the pdfium library, which `flutter test`
    // doesn't have, so errors and paging through a file are checked manually.
  });

  group('layoutPagesInARow', () {
    // The preview is a short, wide strip that pages left to right; pdfrx's
    // default vertical stack would change how it reads.
    test('puts pages side by side, centred on the tallest', () {
      final layout = layoutPagesInARow([
        _FakePage(100, 200),
        _FakePage(300, 100),
      ], const PdfViewerParams(margin: 10));

      expect(layout.pageLayouts, [
        const Rect.fromLTWH(10, 10, 100, 200),
        const Rect.fromLTWH(120, 60, 300, 100),
      ]);
      expect(layout.documentSize, const Size(430, 220));
    });
  });

  group('PdfPageNavBar', () {
    Future<List<int>> pump(WidgetTester tester, int current, int total) async {
      final visited = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PdfPageNavBar(
              currentPage: current,
              totalPages: total,
              onGoToPage: visited.add,
            ),
          ),
        ),
      );
      return visited;
    }

    IconButton button(WidgetTester tester, String tooltip) => tester.widget(
      find.widgetWithIcon(IconButton, switch (tooltip) {
        'Next page' => Icons.chevron_right,
        _ => Icons.chevron_left,
      }),
    );

    testWidgets('moves one page at a time from the middle', (tester) async {
      final visited = await pump(tester, 2, 3);
      expect(find.text('Page 2 of 3'), findsOneWidget);

      await tester.tap(find.byTooltip('Next page'));
      await tester.tap(find.byTooltip('Previous page'));

      expect(visited, [3, 1]);
    });

    testWidgets('stops at both ends of the document', (tester) async {
      await pump(tester, 1, 2);
      expect(button(tester, 'Previous page').onPressed, isNull);
      expect(button(tester, 'Next page').onPressed, isNotNull);

      await pump(tester, 2, 2);
      expect(button(tester, 'Previous page').onPressed, isNotNull);
      expect(button(tester, 'Next page').onPressed, isNull);
    });
  });
}
