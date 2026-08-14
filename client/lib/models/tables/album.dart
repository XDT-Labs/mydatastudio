class Album {
  String id;
  String name;
  String? description;
  String? coverFileId;

  Album({
    required this.id,
    required this.name,
    this.description,
    this.coverFileId,
  });

  factory Album.fromDbMap(Map<String, dynamic> map) {
    return Album(
      id: map['id'] as String,
      name: map['name'] as String,
      description: map['description'] as String?,
      coverFileId: map['cover_file_id'] as String?,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'cover_file_id': coverFileId,
    };
  }
}

