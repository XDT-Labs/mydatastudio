import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/similar_files_tab.dart';

void main() {
  group('SimilarFilesTab', () {
    testWidgets('renders min similarity slider', (tester) async {
      final dummyFile = model.File(
        id: 'file-123',
        name: 'test.jpg',
        path: '/test.jpg',
        parent: '/',
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: 'col-123',
        contentType: 'image/jpeg',
        size: 100,
        isDeleted: false,
      );
      
      final dummyCollection = Collection(
        id: 'col-123',
        name: 'Test Col',
        path: '/col-123',
        type: 'file',
        scanner: 'local',
        needsReAuth: false,
        scanStatus: 'idle',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SimilarFilesTab(
              file: dummyFile,
              collection: dummyCollection,
            ),
          ),
        ),
      );
      
      expect(find.byType(Slider), findsOneWidget);
      expect(find.textContaining('Min similarity:'), findsOneWidget);
    });
  });
}
