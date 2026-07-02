class AichatSkill {
  final String id;
  final String trigger;
  final String name;
  final String? description;
  final String systemPrompt;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  AichatSkill({
    required this.id,
    required this.trigger,
    required this.name,
    this.description,
    required this.systemPrompt,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AichatSkill.fromDbMap(Map<String, dynamic> map) {
    return AichatSkill(
      id: map['id'] as String,
      trigger: map['trigger'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      systemPrompt: map['system_prompt'] as String,
      enabled: (map['enabled'] as int) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'trigger': trigger,
      'name': name,
      'description': description,
      'system_prompt': systemPrompt,
      'enabled': enabled ? 1 : 0,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  AichatSkill copyWith({
    String? trigger,
    String? name,
    String? description,
    String? systemPrompt,
    bool? enabled,
  }) {
    return AichatSkill(
      id: id,
      trigger: trigger ?? this.trigger,
      name: name ?? this.name,
      description: description ?? this.description,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }
}
