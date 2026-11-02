/// What happens locally when a message disappears from the server.
enum EmailDeletePolicy {
  /// The local archive copy stays visible.
  keep('keep'),

  /// The local row is hidden (`emails.is_deleted = 1`).
  markDeleted('mark_deleted'),

  /// The local row and its attachment file rows are deleted.
  remove('remove');

  const EmailDeletePolicy(this.dbValue);

  /// The string stored in `collections.email_delete_policy`.
  final String dbValue;

  /// Unknown or null values fall back to [keep], the non-destructive default.
  static EmailDeletePolicy fromDb(String? value) => EmailDeletePolicy.values
      .firstWhere((p) => p.dbValue == value, orElse: () => EmailDeletePolicy.keep);
}
