import 'dart:typed_data';

/// Converts [List<double>] ↔ raw IEEE-754 [Float32List] bytes for BLOB storage.
///
/// This keeps embedding vectors compact on disk (4 bytes per float vs ~18 bytes
/// as JSON text) and is the format expected by sqlite_vector's `vector_as_f32`.
class FloatListConverter {
  const FloatListConverter();

  List<double> fromSql(Uint8List fromDb) {
    return Float32List.view(fromDb.buffer).toList();
  }

  Uint8List toSql(List<double> value) {
    return Float32List.fromList(value).buffer.asUint8List();
  }
}
