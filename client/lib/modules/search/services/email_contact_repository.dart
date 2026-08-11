import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/search/services/address_parser.dart';
import 'package:resqlite/resqlite.dart';

/// Maintains the `emails_contacts` index — every email address seen in the
/// archive, with the display name and correspondence volume needed to rank it.
///
/// Named for what it is: a derived index over `emails`, in the same family as
/// `emails_fts` and `emails_embeddings`, holding nothing that is not recoverable
/// by re-parsing `from`/`to`/`cc`. It is **not** a contact book, and the bare
/// name `contacts` is left free for a root-level contacts module.
///
/// The distinction that matters if such a module arrives: rows here are keyed by
/// **address**, not by person. One human with three addresses is three rows, and
/// this archive already contains exactly that — `mnimer@allaire.com` and
/// `mike@digitalchef.com` both carry the display name "Mike Nimer". A
/// person-level module would consume this table as a source and map many
/// addresses onto one identity; it would not be this table renamed. That is also
/// why [resolveName] returns every candidate instead of picking one.
///
/// This exists because neither of the obvious alternatives works against the
/// data as it is actually stored. `emails."from"` holds RFC 5322 text
/// (`Google Payments <payments-noreply@google.com>`), so `SELECT DISTINCT` over
/// it yields display-name+address blobs, one per name variant, that no
/// `from:` filter can equality-match. `emails."to"` and `cc` hold
/// comma-joined *lists*, so `DISTINCT` over them yields recipient lists rather
/// than addresses. Both need parsing, and parsing is not expressible in the
/// SQL triggers that keep the FTS5 indexes in sync — hence a Dart-side index
/// maintained on the write path.
///
/// It is also what keeps a per-keystroke autocomplete query off the `emails`
/// table: a `DISTINCT` scan there is fine at a thousand rows and unusable at
/// two hundred thousand.
class EmailContactRepository {
  final AppDatabase db;
  final AppLogger logger = AppLogger(null);

  EmailContactRepository(this.db);

  /// Folds [emails] into the index, one increment per appearance.
  ///
  /// Runs in a single transaction: a batch that fails partway would otherwise
  /// leave counts that over-represent whichever addresses happened to come
  /// first, and those counts are what ranks the autocomplete.
  Future<void> indexEmails(List<Email> emails) async {
    if (emails.isEmpty) return;

    await db.transaction((tx) async {
      for (final email in emails) {
        final timestamp = email.date.millisecondsSinceEpoch;

        final sender = AddressParser.parseOne(email.from);
        if (sender != null) {
          await _upsert(tx, sender, timestamp, isRecipient: false);
        }

        // `to` and `cc` are addressed *by* the user, which is the signal worth
        // separating: someone who receives a hundred of your messages is a
        // stronger autocomplete match than a mailing list that sent you a
        // hundred.
        final recipients = [
          ...AddressParser.parseList(email.to.join(',')),
          ...AddressParser.parseList((email.cc ?? []).join(',')),
        ];
        for (final recipient in recipients) {
          await _upsert(tx, recipient, timestamp, isRecipient: true);
        }
      }
    });
  }

  Future<void> _upsert(
    Transaction tx,
    ParsedAddress parsed,
    int timestamp, {
    required bool isRecipient,
  }) {
    // COALESCE on display_name keeps the first real name rather than letting a
    // later bare-address appearance blank it out — `to` headers in this archive
    // routinely carry no display name at all, so last-write-wins would erase
    // names that only ever arrive on the `from` side.
    return tx.execute(
      '''
      INSERT INTO emails_contacts (address, display_name, local_part,
                                   message_count, sent_count,
                                   first_seen, last_seen)
      VALUES (?, ?, ?, 1, ?, ?, ?)
      ON CONFLICT(address) DO UPDATE SET
        display_name  = COALESCE(emails_contacts.display_name,
                                 excluded.display_name),
        local_part    = excluded.local_part,
        message_count = emails_contacts.message_count + 1,
        sent_count    = emails_contacts.sent_count + excluded.sent_count,
        first_seen    = MIN(COALESCE(emails_contacts.first_seen,
                                     excluded.first_seen),
                            excluded.first_seen),
        last_seen     = MAX(COALESCE(emails_contacts.last_seen,
                                     excluded.last_seen),
                            excluded.last_seen)
      ''',
      [
        parsed.address,
        parsed.displayName,
        parsed.localPart,
        isRecipient ? 1 : 0,
        timestamp,
        timestamp,
      ],
    );
  }

  /// Rebuilds the index from every message already in the archive.
  ///
  /// Needed because the write-path hook only sees mail that arrives after it
  /// exists; without this an upgraded install has an empty `emails_contacts`
  /// table and no `from:` autocomplete at all until the next sync.
  ///
  /// Reads in pages and selects only the four address-bearing columns — a
  /// large archive is mostly `html_body`/`plain_body`/`headers`, and pulling
  /// those to count addresses would materialize hundreds of megabytes for
  /// nothing.
  Future<int> backfillFromEmails({int pageSize = 500}) async {
    await db.execute('DELETE FROM emails_contacts');

    var offset = 0;
    var indexed = 0;
    while (true) {
      final rows = await db.select(
        'SELECT id, "from", "to", cc, date FROM emails '
        'WHERE is_deleted = 0 ORDER BY rowid LIMIT ? OFFSET ?',
        [pageSize, offset],
      );
      if (rows.isEmpty) break;

      await db.transaction((tx) async {
        for (final row in rows) {
          final timestamp = (row['date'] as int?) ?? 0;

          final sender = AddressParser.parseOne(row['from'] as String?);
          if (sender != null) {
            await _upsert(tx, sender, timestamp, isRecipient: false);
          }
          for (final recipient in [
            ...AddressParser.parseList(row['to'] as String?),
            ...AddressParser.parseList(row['cc'] as String?),
          ]) {
            await _upsert(tx, recipient, timestamp, isRecipient: true);
          }
        }
      });

      indexed += rows.length;
      offset += pageSize;
    }

    logger.i('EmailContactRepository: indexed contacts from $indexed emails');
    return indexed;
  }

  /// Every contact, most-corresponded-with first.
  ///
  /// Returned whole rather than filtered in SQL because the caller holds this
  /// in memory and filters per keystroke — see the suggestion cache. Ordering
  /// by volume here is what makes a one- or two-character prefix land on the
  /// right person instead of an alphabetical accident.
  Future<List<EmailContact>> all({int? limit}) async {
    final rows = await db.select(
      'SELECT address, display_name, local_part, message_count, sent_count, '
      'first_seen, last_seen FROM emails_contacts '
      'ORDER BY message_count DESC, address ASC'
      '${limit != null ? ' LIMIT ?' : ''}',
      [if (limit != null) limit],
    );
    return rows.map(EmailContact.fromDbMap).toList();
  }

  /// Addresses plausibly belonging to a person named [name].
  ///
  /// This is the lookup that lets prose (`emails from mike nimer`) resolve to
  /// the same hard sender filter as the `from:mike@x.com` syntax. It is a
  /// database question, not a model one: the archive knows which addresses a
  /// name corresponds to and a language model does not.
  ///
  /// Returns every candidate rather than guessing between them — an ambiguous
  /// name is for the caller to disambiguate visibly, since silently picking
  /// the wrong Mike returns a confidently empty result set.
  Future<List<EmailContact>> resolveName(String name, {int limit = 10}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return const [];

    // Match the name as a whole and each of its parts, so "mike nimer" finds
    // both `Mike Nimer <m@x.com>` and a nameless `mnimer@gmail.com`.
    final pattern = '%${trimmed.replaceAll(RegExp(r'\s+'), '%')}%';
    final rows = await db.select(
      '''
      SELECT address, display_name, local_part, message_count, sent_count,
             first_seen, last_seen
      FROM emails_contacts
      WHERE display_name LIKE ? COLLATE NOCASE
         OR address      LIKE ? COLLATE NOCASE
      ORDER BY message_count DESC, address ASC
      LIMIT ?
      ''',
      [pattern, pattern, limit],
    );
    return rows.map(EmailContact.fromDbMap).toList();
  }
}

/// One row of the `emails_contacts` index — one **address**, not one person.
class EmailContact {
  /// Lowercased — the identity key. See [AddressParser].
  final String address;
  final String? displayName;
  final String localPart;

  /// Total appearances across `from`, `to` and `cc`.
  final int messageCount;

  /// Appearances as a recipient (`to`/`cc`) — mail addressed outward.
  final int sentCount;

  final DateTime? firstSeen;
  final DateTime? lastSeen;

  const EmailContact({
    required this.address,
    required this.displayName,
    required this.localPart,
    required this.messageCount,
    required this.sentCount,
    this.firstSeen,
    this.lastSeen,
  });

  factory EmailContact.fromDbMap(Map<String, Object?> map) {
    DateTime? at(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return EmailContact(
      address: map['address'] as String,
      displayName: map['display_name'] as String?,
      localPart: map['local_part'] as String? ?? '',
      messageCount: (map['message_count'] as int?) ?? 0,
      sentCount: (map['sent_count'] as int?) ?? 0,
      firstSeen: at(map['first_seen']),
      lastSeen: at(map['last_seen']),
    );
  }

  /// What the autocomplete row shows: the human name when one is known,
  /// the address otherwise.
  String get label =>
      (displayName?.isNotEmpty ?? false) ? displayName! : address;

  @override
  String toString() => 'EmailContact($address, $displayName, n=$messageCount)';
}
