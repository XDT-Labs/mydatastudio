import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion.dart';

/// Addresses seen anywhere in the archive, for `from:` / `to:` / `cc:` /
/// `participant:`.
///
/// Reads the materialized `emails_contacts` index rather than `emails`. §13a of
/// the search plan has the measurement behind that: `emails."from"` holds RFC
/// 5322 text and `to`/`cc` hold comma-joined lists, so a `DISTINCT` over either
/// offers rows that are not addresses and that no `from:` filter can match.
class ContactSuggestionProvider extends CachedFieldSuggestionProvider {
  ContactSuggestionProvider(this._contacts);

  final EmailContactRepository _contacts;

  @override
  Set<FilterField> get fields => const {
    FilterField.from,
    FilterField.to,
    FilterField.cc,
    FilterField.participant,
  };

  @override
  Future<List<FieldSuggestion>> load() async {
    final contacts = await _contacts.all();
    return [
      for (final contact in contacts)
        FieldSuggestion(
          value: contact.address,
          label: contact.label,
          // Suppressed when the label already *is* the address, so a nameless
          // contact renders as one line rather than the same text twice.
          detail: contact.label == contact.address ? null : contact.address,
          count: contact.messageCount,
        ),
    ];
  }
}

/// AI-generated image tags, for `tag:`.
///
/// The highest-value field in the dropdown and the one that justifies building
/// it generically: there are thousands of these, no user can guess them, and
/// without completion the filter is effectively undiscoverable.
class TagSuggestionProvider extends CachedFieldSuggestionProvider {
  TagSuggestionProvider(this._db);

  final AppDatabase _db;

  @override
  Set<FilterField> get fields => const {FilterField.tag};

  @override
  Future<List<FieldSuggestion>> load() async {
    final rows = await _db.select(
      'SELECT tag, COUNT(*) AS n FROM file_tags '
      'GROUP BY tag ORDER BY n DESC, tag ASC',
    );
    return [
      for (final row in rows)
        FieldSuggestion(
          value: row['tag'] as String,
          label: row['tag'] as String,
          count: (row['n'] as int?) ?? 0,
        ),
    ];
  }
}

/// Landmarks recognized in photos, for `near:`.
class LandmarkSuggestionProvider extends CachedFieldSuggestionProvider {
  LandmarkSuggestionProvider(this._db);

  final AppDatabase _db;

  @override
  Set<FilterField> get fields => const {FilterField.near};

  @override
  Future<List<FieldSuggestion>> load() async {
    final rows = await _db.select(
      'SELECT landmark, COUNT(*) AS n FROM file_landmarks '
      'GROUP BY landmark ORDER BY n DESC, landmark ASC',
    );
    return [
      for (final row in rows)
        FieldSuggestion(
          value: row['landmark'] as String,
          label: row['landmark'] as String,
          count: (row['n'] as int?) ?? 0,
        ),
    ];
  }
}

/// Configured collections, for `in:`.
class CollectionSuggestionProvider extends CachedFieldSuggestionProvider {
  CollectionSuggestionProvider(this._db);

  final AppDatabase _db;

  @override
  Set<FilterField> get fields => const {FilterField.in_};

  @override
  Future<List<FieldSuggestion>> load() async {
    final rows = await _db.select(
      'SELECT name FROM collections WHERE name IS NOT NULL ORDER BY name ASC',
    );
    return [
      for (final row in rows)
        FieldSuggestion(
          value: row['name'] as String,
          label: row['name'] as String,
        ),
    ];
  }
}

/// Fields whose vocabulary is fixed by the query grammar rather than by data.
///
/// Only the canonical spelling of each value is offered. The parser also
/// accepts aliases (`photo` for `image`, `mail` for `email`), but a dropdown
/// listing every synonym would present a choice where none exists — the
/// aliases still work when typed.
class StaticSuggestionProvider implements FieldSuggestionProvider {
  const StaticSuggestionProvider();

  static const _values = <FilterField, List<String>>{
    FilterField.type: ['image', 'video', 'pdf', 'document', 'email'],
    FilterField.has: ['attachment'],
    FilterField.is_: ['read', 'unread'],
  };

  @override
  Set<FilterField> get fields => _values.keys.toSet();

  @override
  Future<List<FieldSuggestion>> suggest(
    FilterField field,
    String typed, {
    int limit = 8,
  }) async {
    final values = [
      for (final value in _values[field] ?? const <String>[])
        FieldSuggestion(value: value, label: value),
    ];
    return rankSuggestions(values, typed, limit: limit);
  }

  @override
  void invalidate() {}
}

/// Routes a field to the provider that knows its values.
///
/// Holds the providers for the lifetime of the search page so their caches
/// survive between keystrokes and between searches.
class FieldSuggestionService {
  FieldSuggestionService(List<FieldSuggestionProvider> providers)
    : _providers = {
        for (final provider in providers)
          for (final field in provider.fields) field: provider,
      };

  /// Builds the standard set against a live database.
  factory FieldSuggestionService.forDatabase(AppDatabase db) {
    return FieldSuggestionService([
      ContactSuggestionProvider(EmailContactRepository(db)),
      TagSuggestionProvider(db),
      LandmarkSuggestionProvider(db),
      CollectionSuggestionProvider(db),
      const StaticSuggestionProvider(),
    ]);
  }

  final Map<FilterField, FieldSuggestionProvider> _providers;

  /// True when [field] has any suggestions to offer at all.
  bool supports(FilterField field) => _providers.containsKey(field);

  /// Values for [field] matching [typed], best first.
  ///
  /// Returns empty rather than throwing for a field nothing can complete
  /// (`subject:`, `after:`) — the caret sits in those constantly and a search
  /// box has no business failing because it has nothing to suggest.
  Future<List<FieldSuggestion>> suggest(
    FilterField field,
    String typed, {
    int limit = 8,
  }) async {
    final provider = _providers[field];
    if (provider == null) return const [];
    return provider.suggest(field, typed, limit: limit);
  }

  /// Drops every cached list. Called when a scan completes, since a sync is
  /// what adds contacts and tags.
  void invalidate() {
    for (final provider in _providers.values) {
      provider.invalidate();
    }
  }
}
