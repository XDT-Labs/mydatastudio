import 'dart:typed_data';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/repositories/database_repository.dart';

AppDatabase _createTestDb() => AppDatabase(null, null, null, true);

void main() {
  group('DatabaseRepository - Embeddings', () {
    late AppDatabase database;
    late DatabaseRepository repo;

    setUp(() async {
      database = _createTestDb();
      repo = DatabaseRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('Float32 BLOB round-trip preserves values within float32 precision',
        () {
      // Dart doubles are float64; converting to Float32List truncates precision.
      final original = List<double>.generate(2048, (i) => i * 0.001);
      final asFloat32 = Float32List.fromList(original);
      final roundTripped = List<double>.from(asFloat32);

      for (int i = 0; i < original.length; i++) {
        expect(
          roundTripped[i],
          closeTo(original[i], 1e-6),
          reason: 'Value at index $i should survive float32 round-trip',
        );
      }
    });

    test('upsertFileEmbedding inserts a row into files_embeddings', () async {
      final embedding = List<double>.generate(2048, (i) => i * 0.001);
      await repo.upsertFileEmbedding('file-001', embedding);

      final rows = await database
          .customSelect('SELECT file_id FROM files_embeddings WHERE file_id = ?',
              variables: [Variable.withString('file-001')])
          .get();
      expect(rows.length, 1);
      expect(rows.first.read<String>('file_id'), 'file-001');
    });

    test('upsertFileEmbedding updates existing row (upsert semantics)',
        () async {
      final embedding1 = List<double>.generate(2048, (i) => i * 0.001);
      final embedding2 = List<double>.generate(2048, (i) => i * 0.002);

      await repo.upsertFileEmbedding('file-001', embedding1);
      await repo.upsertFileEmbedding('file-001', embedding2); // should upsert

      final rows = await database
          .customSelect('SELECT file_id FROM files_embeddings WHERE file_id = ?',
              variables: [Variable.withString('file-001')])
          .get();
      expect(rows.length, 1, reason: 'Should only have one row after upsert');
    });

    test('deleteFileEmbedding removes the row from files_embeddings', () async {
      final embedding = List<double>.generate(2048, (i) => i * 0.001);
      await repo.upsertFileEmbedding('file-001', embedding);
      await repo.deleteFileEmbedding('file-001');

      final rows = await database
          .customSelect('SELECT file_id FROM files_embeddings WHERE file_id = ?',
              variables: [Variable.withString('file-001')])
          .get();
      expect(rows.isEmpty, true);
    });

    test('deleteFileEmbedding on non-existent id is a no-op', () async {
      // Should not throw
      await expectLater(
        repo.deleteFileEmbedding('does-not-exist'),
        completes,
      );
    });

    test(
      'findSimilarFiles returns results ordered by distance (closest first)',
      () async {
        // This test requires the sqlite_vector native extension to be loaded.
        // It will pass in production builds where native assets are bundled.
        final q = List<double>.generate(2048, (i) => i * 0.001);
        await repo.upsertFileEmbedding('file-a', q);

        final results = await repo.findSimilarFiles(q, limit: 5);
        expect(results, isNotEmpty);
        expect(results.first.fileId, 'file-a');

        // Distances should be non-decreasing
        for (int i = 1; i < results.length; i++) {
          expect(results[i].distance >= results[i - 1].distance, true);
        }
      },
      skip: 'Requires sqlite_vector native extension (native assets build)',
    );
  });
}
