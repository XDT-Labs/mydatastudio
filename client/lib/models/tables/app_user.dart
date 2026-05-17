class AppUser {
  String id;
  String name;
  String email;
  String password;
  String localStoragePath;
  String? privateKey;
  String? publicKey;

  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    required this.localStoragePath,
    this.privateKey,
    this.publicKey,
  });

  factory AppUser.fromDbMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['id'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      password: map['password'] as String,
      localStoragePath: map['local_storage_path'] as String,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'password': password,
      'local_storage_path': localStoragePath,
    };
  }
}
