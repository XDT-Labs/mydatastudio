import 'dart:io' as io;

import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/file_sources/file_source_file.dart';
import 'package:mydatatools/file_sources/file_source_provider.dart';
import 'package:mydatatools/file_sources/file_source_registry.dart';
import 'package:mydatatools/file_sources/local/local_file_provider.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

Collection _makeCollection(String scanner) => Collection(
      id: const Uuid().v4(),
      name: 'Test',
      path: '/tmp/test',
      type: 'file',
      scanner: scanner,
      scanStatus: 'pending',
      needsReAuth: false,
    );

void main() {
  group('FileSourceRegistry', () {
    test('forCollection returns LocalFileProvider for file.local', () {
      final collection = _makeCollection(AppConstants.scannerFileLocal);
      final provider = FileSourceRegistry.forCollection(collection);
      expect(provider, isA<LocalFileProvider>());
    });

    test('forCollection throws ArgumentError for unknown scanner', () {
      final collection = _makeCollection('unknown.scanner');
      expect(
        () => FileSourceRegistry.forCollection(collection),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('isSupported returns true for registered scanners', () {
      expect(
        FileSourceRegistry.isSupported(AppConstants.scannerFileLocal),
        isTrue,
      );
    });

    test('isSupported returns false for unregistered scanners', () {
      expect(
        FileSourceRegistry.isSupported('file.unknown'),
        isFalse,
      );
    });

    test('register allows overriding a provider at runtime', () {
      // Useful for injecting mocks in tests
      final stub = _StubProvider();
      FileSourceRegistry.register('file.stub', stub);

      final collection = _makeCollection('file.stub');
      final resolved = FileSourceRegistry.forCollection(collection);
      expect(resolved, same(stub));
    });

    test('LocalFileProvider has correct metadata', () {
      final provider = LocalFileProvider();
      expect(provider.providerKey, equals('local'));
      expect(provider.scannerType, equals(AppConstants.scannerFileLocal));
      expect(provider.displayName, equals('Local Files'));
    });
  });
}

// Minimal stub for testing registration
class _StubProvider implements FileSourceProvider {
  @override
  String get providerKey => 'stub';
  @override
  String get scannerType => 'file.stub';
  @override
  String get displayName => 'Stub';

  @override
  Future<List<FileSourceFile>> listFolder(collection, {folderId}) async => [];
  @override
  Future<io.File> downloadFile(collection, file, destPath) async =>
      throw UnimplementedError();
  @override
  Future<bool> deleteFile(collection, file) async => false;
  @override
  Future<void> openFile(collection, file) async {}
}
