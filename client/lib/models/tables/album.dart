class Album {
  String id;
  String name;

  Album({required this.id, required this.name});

  factory Album.fromDbMap(Map<String, dynamic> map) {
    return Album(
      id: map['id'] as String,
      name: map['name'] as String,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
    };
  }
}
