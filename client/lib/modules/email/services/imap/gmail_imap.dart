// Gmail's IMAP extensions (X-GM-LABELS, X-GM-MSGID, X-GM-THRID) and its
// download-limit errors. enough_mail knows none of them: its FETCH parser
// skips unknown data items. So the fetch goes out as a raw command with its
// own response parser, and everything that can be decided without a socket
// lives in the pure functions below, which are unit-tested.
import 'package:enough_mail/enough_mail.dart';
// enough_mail has no generic-command API in its public exports, but
// ImapClient.sendCommand is public and takes these types.
// ignore: implementation_imports
import 'package:enough_mail/src/codecs/modified_utf7_codec.dart';
// ignore: implementation_imports
import 'package:enough_mail/src/private/imap/command.dart';
// ignore: implementation_imports
import 'package:enough_mail/src/private/imap/imap_response.dart';
// ignore: implementation_imports
import 'package:enough_mail/src/private/imap/response_parser.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_role_mapper.dart';

/// Provider id of the Gmail entry in `EmailProviderRegistry`.
const gmailProviderId = 'gmail';

/// Collection scan status while Gmail's daily download limit blocks the sync.
/// The next sync resumes where this one stopped (sync state is kept) and sets
/// the status back to `ready`.
const gmailPausedScanStatus = 'Paused: Gmail daily download limit';

/// What Gmail says about one message.
class GmailMessageMeta {
  const GmailMessageMeta({
    required this.uid,
    this.msgId,
    this.threadId,
    this.labels,
  });

  final int uid;
  final String? msgId;
  final String? threadId;

  /// Decoded label names as Gmail reports them (`\Inbox`, `Work/Receipts`);
  /// null when the response did not carry X-GM-LABELS at all.
  final List<String>? labels;
}

// -- FETCH response parsing --------------------------------------------------

/// Parses the text of an untagged `n FETCH (...)` line (with or without the
/// leading `* `). Returns null when the line is not a FETCH carrying a UID.
GmailMessageMeta? parseGmailFetchLine(String line) {
  var text = line.startsWith('* ') ? line.substring(2) : line;
  final fetchAt = text.indexOf(' FETCH (');
  if (fetchAt < 0) return null;
  text = text.substring(fetchAt + ' FETCH '.length);

  final tokens = _tokenize(text);
  if (tokens.isEmpty || tokens.first is! List) return null;
  final items = tokens.first as List;

  int? uid;
  String? msgId;
  String? threadId;
  List<String>? labels;
  for (var i = 0; i + 1 < items.length; i++) {
    final key = items[i];
    if (key is! String) continue;
    final value = items[i + 1];
    switch (key.toUpperCase()) {
      case 'UID':
        if (value is String) uid = int.tryParse(value);
      case 'X-GM-MSGID':
        if (value is String) msgId = value;
      case 'X-GM-THRID':
        if (value is String) threadId = value;
      case 'X-GM-LABELS':
        if (value is List) {
          labels = [
            for (final l in value)
              if (l is String) decodeGmailLabel(l),
          ];
        }
    }
  }
  if (uid == null) return null;
  return GmailMessageMeta(
    uid: uid,
    msgId: msgId,
    threadId: threadId,
    labels: labels,
  );
}

/// Gmail sends label names in modified UTF-7 (RFC 3501 5.1.3), like mailbox
/// names; `&AOk-` is "é". Malformed input is returned unchanged.
String decodeGmailLabel(String raw) {
  if (!raw.contains('&')) return raw;
  try {
    return const ModifiedUtf7Codec().decodeText(raw);
  } catch (_) {
    return raw;
  }
}

/// Minimal IMAP tokenizer: atoms and quoted strings become [String]s (quotes
/// removed, `\\` and `\"` unescaped), parenthesised lists become [List]s.
/// An unquoted `\Inbox` and a quoted `"\\Inbox"` give the same label.
List<Object> _tokenize(String s) {
  var i = 0;
  List<Object> parseSequence(bool nested) {
    final out = <Object>[];
    while (i < s.length) {
      final c = s[i];
      if (c == ' ') {
        i++;
      } else if (c == '(') {
        i++;
        out.add(parseSequence(true));
      } else if (c == ')') {
        i++;
        if (nested) return out;
      } else if (c == '"') {
        i++;
        final b = StringBuffer();
        while (i < s.length && s[i] != '"') {
          if (s[i] == r'\' && i + 1 < s.length) i++;
          b.write(s[i]);
          i++;
        }
        i++; // closing quote
        out.add(b.toString());
      } else {
        final start = i;
        while (i < s.length && s[i] != ' ' && s[i] != '(' && s[i] != ')') {
          i++;
        }
        out.add(s.substring(start, i));
      }
    }
    return out;
  }

  return parseSequence(false);
}

/// Collects the metadata of every FETCH line of one command.
class GmailFetchParser extends ResponseParser<List<GmailMessageMeta>> {
  final List<GmailMessageMeta> _found = [];

  @override
  List<GmailMessageMeta> parse(
    ImapResponse imapResponse,
    Response<List<GmailMessageMeta>> response,
  ) => _found;

  @override
  bool parseUntagged(
    ImapResponse imapResponse,
    Response<List<GmailMessageMeta>>? response,
  ) {
    final meta = parseGmailFetchLine(imapResponse.parseText);
    if (meta == null) return false;
    _found.add(meta);
    return true;
  }
}

/// `UID FETCH <uids> (X-GM-LABELS X-GM-MSGID X-GM-THRID)`, optionally limited
/// to messages changed since [changedSinceModseq] (CONDSTORE; Gmail raises a
/// message's MODSEQ when its labels change). Needs the folder SELECTed.
Future<List<GmailMessageMeta>> fetchGmailMeta(
  ImapClient client,
  MessageSequence uids, {
  int? changedSinceModseq,
}) {
  final since =
      changedSinceModseq == null ? '' : ' (CHANGEDSINCE $changedSinceModseq)';
  final command = Command(
    'UID FETCH ${uids.toString()} '
    '(X-GM-LABELS X-GM-MSGID X-GM-THRID)$since',
  );
  return client.sendCommand<List<GmailMessageMeta>>(
    command,
    GmailFetchParser(),
  );
}

// -- Download limit ----------------------------------------------------------

/// True when [error] (an ImapException's text, or any error's `toString()`) is
/// Gmail refusing further downloads for the day: `[OVERQUOTA]`, "Account
/// exceeded command or bandwidth limits" or "Download limit exceeded".
bool isGmailDownloadLimitError(Object error) {
  final t = error.toString().toLowerCase();
  return t.contains('[overquota]') ||
      t.contains('exceeded command or bandwidth limits') ||
      t.contains('download limit exceeded');
}

/// Thrown by the fetch helpers so the sync stops cleanly instead of treating
/// the refusal as a per-message failure.
class ImapDownloadLimitException implements Exception {
  const ImapDownloadLimitException(this.cause);
  final Object cause;

  @override
  String toString() => 'ImapDownloadLimitException: $cause';
}

// -- Folder choice -----------------------------------------------------------

/// Path of the `\All` mailbox (`[Gmail]/All Mail`): SPECIAL-USE flag first,
/// then the registry's name hints. Null when the account hides it from IMAP.
String? gmailAllMailPath(List<Mailbox> mailboxes, {EmailProvider? provider}) {
  for (final m in mailboxes) {
    if (m.hasFlag(MailboxFlag.noSelect) || m.hasFlag(MailboxFlag.nonExistent)) {
      continue;
    }
    final role = folderRoleFor(
      name: m.name,
      path: m.path,
      flags: m.flags,
      provider: provider,
    );
    if (role == FolderRole.all) return m.path;
  }
  return null;
}

// -- Labels -> folders -------------------------------------------------------

/// Maps Gmail labels to `email_folders` ids.
///
/// Gmail also exposes every label as an IMAP mailbox whose path equals the
/// label name, and the system labels as `INBOX` / `[Gmail]/...`, so labels map
/// onto folder rows that `LIST` already created. A message's primary folder is
/// All Mail; every other folder it belongs to goes in the `labels` column,
/// which the folder filter already honours.
class GmailLabelMapper {
  GmailLabelMapper({
    required this.allMailPath,
    required Iterable<({String path, FolderRole role})> folders,
  }) : knownPaths = {for (final f in folders) f.path} {
    for (final f in folders) {
      switch (f.role) {
        case FolderRole.sent:
          _system.putIfAbsent(r'\Sent', () => f.path);
        case FolderRole.drafts:
          _system.putIfAbsent(r'\Draft', () => f.path);
        case FolderRole.flagged:
          _system.putIfAbsent(r'\Starred', () => f.path);
        case FolderRole.important:
          _system.putIfAbsent(r'\Important', () => f.path);
        default:
      }
    }
  }

  final String allMailPath;

  /// Folder ids that already have an `email_folders` row.
  final Set<String> knownPaths;

  /// System label -> folder path as LIST reported it (localised accounts).
  final Map<String, String> _system = {};

  /// English paths, used when LIST did not reveal one.
  static const _defaults = {
    r'\Inbox': 'INBOX',
    r'\Sent': '[Gmail]/Sent Mail',
    r'\Draft': '[Gmail]/Drafts',
    r'\Starred': '[Gmail]/Starred',
    r'\Important': '[Gmail]/Important',
  };

  static const _dropped = {r'\Trash', r'\Spam', r'\All', r'\Muted'};

  /// Folder id of one label, or null if it is not a folder membership
  /// (Trash/Spam/All Mail, or a name that cannot live in the comma-separated
  /// `labels` column).
  String? folderIdFor(String label) {
    if (_dropped.contains(label)) return null;
    final path =
        label.startsWith(r'\') ? (_system[label] ?? _defaults[label]) : label;
    if (path == null || path.isEmpty || path.contains(',')) return null;
    if (path == allMailPath) return null;
    return path;
  }

  /// The `labels` column value for a message: folder ids except the primary.
  List<String> foldersFor(Iterable<String> labels) {
    final out = <String>[];
    for (final l in labels) {
      final id = folderIdFor(l);
      if (id != null && !out.contains(id)) out.add(id);
    }
    return out;
  }
}
