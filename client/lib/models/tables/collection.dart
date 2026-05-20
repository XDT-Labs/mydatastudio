class Collection {
  String id;
  String name;
  String path;
  String type;
  String scanner;
  String scanStatus;
  //oauth tokens for external systems
  String? oauthService;
  String? accessToken;
  String? refreshToken;
  String? idToken;
  String? userId;
  DateTime? expiration;
  DateTime? lastScanDate;
  bool needsReAuth = false;
  bool downloadLocalCopy = false;
  String? localCopyPath;

  // fields not in db
  String? status;
  String? statusMessage;

  Collection({
    required this.id,
    required this.name,
    required this.path,
    required this.type,
    required this.scanner,
    required this.scanStatus,
    this.oauthService,
    this.accessToken,
    this.refreshToken,
    this.idToken,
    this.userId,
    this.expiration,
    this.lastScanDate,
    required this.needsReAuth,
    this.downloadLocalCopy = false,
    this.localCopyPath,
  });

  factory Collection.fromDbMap(Map<String, dynamic> map) {
    return Collection(
      id: map['id'] as String,
      name: map['name'] as String,
      path: map['path'] as String,
      type: map['type'] as String,
      scanner: map['scanner'] as String,
      scanStatus: map['scan_status'] as String,
      oauthService: map['oauth_service'] as String?,
      accessToken: map['access_token'] as String?,
      refreshToken: map['refresh_token'] as String?,
      idToken: map['id_token'] as String?,
      userId: map['user_id'] as String?,
      expiration: map['expiration'] != null ? DateTime.fromMillisecondsSinceEpoch(map['expiration'] as int) : null,
      lastScanDate: map['last_scan_date'] != null ? DateTime.fromMillisecondsSinceEpoch(map['last_scan_date'] as int) : null,
      needsReAuth: (map['needs_re_auth'] as int? ?? 0) != 0,
      downloadLocalCopy: (map['download_local_copy'] as int? ?? 0) != 0,
      localCopyPath: map['local_copy_path'] as String?,
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
      'path': path,
      'type': type,
      'scanner': scanner,
      'scan_status': scanStatus,
      'oauth_service': oauthService,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'id_token': idToken,
      'user_id': userId,
      'expiration': expiration?.millisecondsSinceEpoch,
      'last_scan_date': lastScanDate?.millisecondsSinceEpoch,
      'needs_re_auth': needsReAuth ? 1 : 0,
      'download_local_copy': downloadLocalCopy ? 1 : 0,
      'local_copy_path': localCopyPath,
    };
  }
}
