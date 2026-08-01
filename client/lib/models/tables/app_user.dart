class AppUser {
  String id;
  String name;
  String email;
  String password;
  String? privateKey;
  String? publicKey;

  /// Transient, in-memory only (never in [toDbMap], never persisted): the
  /// storage path chosen during the setup wizard, threaded between steps
  /// before `config.json`/`MainApp.appDataDirectory` become the source of
  /// truth. Not stored per-user — the app has one storage location.
  String localStoragePath;

  /// Transient, in-memory only (never in [toDbMap], never persisted): the
  /// plaintext password entered during setup, used once to create the credential
  /// vault at setup completion (AUDIT M2). Cleared immediately after.
  String? plaintextPassword;

  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    required this.localStoragePath,
    this.privateKey,
    this.publicKey,
    this.plaintextPassword,
  });

  factory AppUser.fromDbMap(Map<String, dynamic> map) {
    return AppUser(
      id: map['id'] as String,
      name: map['name'] as String,
      email: map['email'] as String,
      password: map['password'] as String,
      localStoragePath: '',
    );
  }

  Map<String, dynamic> toDbMap() {
    return {'id': id, 'name': name, 'email': email, 'password': password};
  }
}
