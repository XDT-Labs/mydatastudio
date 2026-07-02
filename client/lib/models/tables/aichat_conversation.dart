class AichatConversation {
  final String id;
  String name;
  String? model;
  final DateTime createdAt;
  DateTime updatedAt;

  AichatConversation({
    required this.id,
    required this.name,
    this.model,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AichatConversation.fromDbMap(Map<String, dynamic> map) {
    return AichatConversation(
      id: map['id'] as String,
      name: map['name'] as String,
      model: map['model'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }
}
