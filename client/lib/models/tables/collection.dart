import 'package:mydatastudio/models/tables/email_delete_policy.dart';

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

  /// When the collection was added; null for rows from before the column.
  DateTime? dateCreated;
  bool needsReAuth = false;
  bool downloadLocalCopy = false;
  String? localCopyPath;

  /// IMAP email only. Id of an `EmailProviderRegistry` provider.
  String? emailProviderId;

  /// JSON host/port/security/username for the `other` provider. Never a password.
  String? imapSettings;
  EmailDeletePolicy emailDeletePolicy;

  /// Provider change-feed position; null until a full walk has stored one.
  String? changeCursor;

  /// Keep rows/local copies of files the source deleted (sets
  /// `files.source_deleted_date` instead of `is_deleted`).
  bool keepDeletedFiles = false;

  /// ContentPolicy JSON; null = derive from [downloadLocalCopy].
  String? contentPolicy;

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
    this.dateCreated,
    required this.needsReAuth,
    this.downloadLocalCopy = false,
    this.localCopyPath,
    this.emailProviderId,
    this.imapSettings,
    this.emailDeletePolicy = EmailDeletePolicy.keep,
    this.changeCursor,
    this.keepDeletedFiles = false,
    this.contentPolicy,
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
      dateCreated: map['date_created'] != null ? DateTime.fromMillisecondsSinceEpoch(map['date_created'] as int) : null,
      needsReAuth: (map['needs_re_auth'] as int? ?? 0) != 0,
      downloadLocalCopy: (map['download_local_copy'] as int? ?? 0) != 0,
      localCopyPath: map['local_copy_path'] as String?,
      emailProviderId: map['email_provider_id'] as String?,
      imapSettings: map['imap_settings'] as String?,
      emailDeletePolicy: EmailDeletePolicy.fromDb(
        map['email_delete_policy'] as String?,
      ),
      changeCursor: map['change_cursor'] as String?,
      keepDeletedFiles: (map['keep_deleted_files'] as int? ?? 0) != 0,
      contentPolicy: map['content_policy'] as String?,
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
      'date_created': dateCreated?.millisecondsSinceEpoch,
      'needs_re_auth': needsReAuth ? 1 : 0,
      'download_local_copy': downloadLocalCopy ? 1 : 0,
      'local_copy_path': localCopyPath,
      'email_provider_id': emailProviderId,
      'imap_settings': imapSettings,
      'email_delete_policy': emailDeletePolicy.dbValue,
      'change_cursor': changeCursor,
      'keep_deleted_files': keepDeletedFiles ? 1 : 0,
      'content_policy': contentPolicy,
    };
  }
}
