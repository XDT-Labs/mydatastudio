// stores preferences as strings

class StringArrayConverter {
  const StringArrayConverter();

  List<String> fromSql(String fromDb) {
    if (fromDb.isEmpty) return [];
    return fromDb.split(",");
  }

  String toSql(List<String> value) {
    return value.join(",");
  }
}
