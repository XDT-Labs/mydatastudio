import 'package:mydatatools/database_manager.dart';
import 'package:drift/drift.dart';
import 'package:mydatatools/models/tables/converters/string_array_convertor.dart';

@UseRowClass(Provider, constructor: 'fromDb')
class Providers extends Table {
  TextColumn get service => text()();
  TextColumn get clientId => text().nullable()();
  TextColumn get clientSecret => text().nullable()();
  TextColumn get apiKey => text().nullable()();
  TextColumn get permissions => text().map(const StringArrayConverter()).nullable()();

  @override
  Set<Column> get primaryKey => {service};
}

class Provider implements Insertable<Provider> {
  String service;
  String? clientId;
  String? clientSecret;
  String? apiKey;
  List<String>? permissions;

  Provider({
    required this.service,
    this.clientId,
    this.clientSecret,
    this.apiKey,
    this.permissions,
  });

  Provider.fromDb({
    required this.service,
    this.clientId,
    this.clientSecret,
    this.apiKey,
    this.permissions,
  });

  @override
  Map<String, Expression<Object>> toColumns(bool nullToAbsent) {
    return ProvidersCompanion(
      service: Value(service),
      clientId: clientId == null && nullToAbsent ? const Value.absent() : Value(clientId),
      clientSecret: clientSecret == null && nullToAbsent ? const Value.absent() : Value(clientSecret),
      apiKey: apiKey == null && nullToAbsent ? const Value.absent() : Value(apiKey),
      permissions: permissions == null && nullToAbsent ? const Value.absent() : Value(permissions),
    ).toColumns(nullToAbsent);
  }
}
