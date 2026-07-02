class AichatModel {
  final String id;
  final String alias;
  final String group;
  final String name;
  final String? file;
  final String? mmproj;
  final String? hfRepo;
  final String? chatHandler;
  final String type;
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
    this.hfRepo,
    this.chatHandler,
    required this.type,
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
      hfRepo: map['hf_repo'] as String?,
      chatHandler: map['chat_handler'] as String?,
      type: map['type'] as String,
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
      'hf_repo': hfRepo,
      'chat_handler': chatHandler,
      'type': type,
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
    String? hfRepo,
    String? chatHandler,
    String? type,
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
      hfRepo: hfRepo ?? this.hfRepo,
      chatHandler: chatHandler ?? this.chatHandler,
      type: type ?? this.type,
      baseUrl: baseUrl ?? this.baseUrl,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      updatedAt: now,
    );
  }
}
