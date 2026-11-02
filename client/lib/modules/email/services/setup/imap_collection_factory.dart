import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Builds the collection for a verified IMAP account.
///
/// The password goes in `accessToken` (CollectionRepository encrypts it) and
/// the login name in `userId`, as the legacy Yahoo flow did. [settings] is
/// only for providers without a known host (`other`) and never holds a
/// password.
Collection buildImapCollection({
  required EmailProvider provider,
  required String email,
  required String username,
  required String password,
  ImapSettings? settings,
  String? appDataDir,
}) {
  final id = const Uuid().v4();
  return Collection(
    id: id,
    name: email,
    path: email, // Root path for the IMAP scanner
    localCopyPath:
        appDataDir != null ? p.join(appDataDir, 'files', 'email', id) : null,
    type: 'email',
    scanner: AppConstants.scannerEmailImap,
    emailProviderId: provider.id,
    imapSettings: settings?.toJsonString(),
    scanStatus: 'idle',
    oauthService: provider.oauthService,
    accessToken: password,
    userId: username,
    needsReAuth: false,
    downloadLocalCopy: true,
  );
}
