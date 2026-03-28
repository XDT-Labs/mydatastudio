import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_details/stl_preview_widget.dart';

import '../../../../helpers/file_fixture.dart';

/// Fake renderer — returns a simple SizedBox, never touches OpenGL.
class FakeStlRenderer implements StlRenderer {
  FakeStlRenderer({this.shouldFail = false});
  final bool shouldFail;

  @override
  void dispose() {}

  @override
  Widget build(BuildContext context) =>
      shouldFail ? const Text('render_error') : const SizedBox.expand();
}

void main() {
  group('StlPreviewWidget', () {
    testWidgets('shows fake renderer content via rendererFactory', (tester) async {
      final file = makeTestFile(name: 'model.stl', contentType: 'application/octet-stream');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StlPreviewWidget(
              file: file,
              previewHeight: 300,
              resolvedPath: '/tmp/model.stl',
              rendererFactory: (_) => FakeStlRenderer(),
            ),
          ),
        ),
      );
      await tester.pump();
      // With rendererFactory, loading is skipped and the fake SizedBox renders.
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows error text when fake renderer has shouldFail=true',
        (tester) async {
      final file = makeTestFile(name: 'bad.stl');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StlPreviewWidget(
              file: file,
              previewHeight: 300,
              resolvedPath: '/tmp/bad.stl',
              rendererFactory: (_) => FakeStlRenderer(shouldFail: true),
            ),
          ),
        ),
      );
      await tester.pump();
      // FakeStlRenderer.build returns Text('render_error') when shouldFail=true.
      expect(find.text('render_error'), findsOneWidget);
    });
  });
}
