import 'package:enough_mail/enough_mail.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';

/// What a mailbox is for. Stored as [name] in `email_folders.type`.
enum FolderRole {
  inbox,
  sent,
  drafts,
  trash,
  junk,
  archive,
  all,
  flagged,
  important,
  user;

  /// Unknown values (including the legacy `system`) map to [user].
  static FolderRole fromDb(String? value) => FolderRole.values.firstWhere(
    (r) => r.name == value,
    orElse: () => FolderRole.user,
  );
}

/// Roles whose folders are not synced: spam and deleted mail is noise in an
/// archive. Rows already stored from such a folder are left alone; the folder
/// is simply never visited, so no removal logic runs for it either.
const syncSkippedRoles = <FolderRole>{FolderRole.trash, FolderRole.junk};

const _genericNameHints = <String, FolderRole>{
  'sent': FolderRole.sent,
  'sent mail': FolderRole.sent,
  'sent messages': FolderRole.sent,
  'sent items': FolderRole.sent,
  'trash': FolderRole.trash,
  'deleted messages': FolderRole.trash,
  'spam': FolderRole.junk,
  'junk': FolderRole.junk,
  'drafts': FolderRole.drafts,
  'archive': FolderRole.archive,
};

const _flagRoles = <MailboxFlag, FolderRole>{
  MailboxFlag.inbox: FolderRole.inbox,
  MailboxFlag.sent: FolderRole.sent,
  MailboxFlag.drafts: FolderRole.drafts,
  MailboxFlag.trash: FolderRole.trash,
  MailboxFlag.junk: FolderRole.junk,
  MailboxFlag.archive: FolderRole.archive,
  MailboxFlag.all: FolderRole.all,
  MailboxFlag.flagged: FolderRole.flagged,
};

/// Classifies a mailbox. Priority: RFC 6154 SPECIAL-USE flags, INBOX by name,
/// provider hints, generic English names, else [FolderRole.user].
///
/// enough_mail has no `\Important` flag, so [FolderRole.important] is only
/// reachable through provider hints.
FolderRole folderRoleFor({
  required String name,
  String? path,
  List<MailboxFlag> flags = const [],
  EmailProvider? provider,
}) {
  for (final entry in _flagRoles.entries) {
    if (flags.contains(entry.key)) return entry.value;
  }
  if ((path ?? name).toLowerCase() == 'inbox') return FolderRole.inbox;

  // Hints match the full path first (e.g. "[Gmail]/Important"), then the leaf.
  final keys = <String>{
    if (path != null) path.toLowerCase(),
    name.toLowerCase(),
  };
  for (final hints in [provider?.folderNameHints, _genericNameHints]) {
    if (hints == null) continue;
    for (final key in keys) {
      final role = hints[key];
      if (role != null) return role;
    }
  }
  return FolderRole.user;
}
