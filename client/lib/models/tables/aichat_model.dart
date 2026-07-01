class AichatModel {
  final String id;
  final String alias;
  final String group;
  final String name;
  final String? file;
  final String? mmproj;
  final String type;
  final String? apiKey;
  final String? baseUrl;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  AichatModel({
    required this.id,
    required this.alias,
    required this.group,
    required this.name,
    this.file,
    this.mmproj,
    required this.type,
    this.apiKey,
    this.baseUrl,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AichatModel.fromDbMap(Map<String, dynamic> map) {
    return AichatModel(
      id: map['id'] as String,
      alias: map['alias'] as String,
      group: map['group'] as String,
      name: map['name'] as String,
      file: map['file'] as String?,
      mmproj: map['mmproj'] as String?,
      type: map['type'] as String,
      apiKey: map['api_key'] as String?,
      baseUrl: map['base_url'] as String?,
      enabled: (map['enabled'] as int) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'alias': alias,
      'group': group,
      'name': name,
      'file': file,
      'mmproj': mmproj,
      'type': type,
      'api_key': apiKey,
      'base_url': baseUrl,
      'enabled': enabled ? 1 : 0,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  AichatModel copyWith({
    String? alias,
    String? group,
    String? name,
    String? file,
    String? mmproj,
    String? type,
    String? apiKey,
    String? baseUrl,
    bool? enabled,
  }) {
    final now = DateTime.now();
    return AichatModel(
      id: id,
      alias: alias ?? this.alias,
      group: group ?? this.group,
      name: name ?? this.name,
      file: file ?? this.file,
      mmproj: mmproj ?? this.mmproj,
      type: type ?? this.type,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      updatedAt: now,
    );
  }
}
