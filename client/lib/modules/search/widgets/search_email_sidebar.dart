import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/widgets/email_details.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/info_row.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/section_widget.dart';
import 'package:mydatastudio/modules/search/widgets/search_sidebar_header.dart';

/// Search's detail panel for a mail hit.
///
/// Same furniture as [SearchFileSidebar] — the shared header, then a bounded
/// preview, then bordered metadata sections — so switching between a photo and
/// an email in a mixed result list doesn't feel like switching applications.
///
/// The message body sits *above* the metadata rather than below a header block
/// the way a mail client lays it out. In a result list the question being
/// answered is "why did this match?", and the answer is in the text; who sent
/// it and when are the follow-up. Reading the whole thread is the spacebar's
/// job, not this panel's.
class SearchEmailSidebar extends StatelessWidget {
  const SearchEmailSidebar({
    super.key,
    required this.email,
    required this.width,
    required this.onClose,
    this.collection,
    this.onToggleWidth,
    this.onOpenReader,
    this.isWide = false,
  });

  final Email email;

  /// The mail account this message came from. Null while it is still being
  /// looked up, or when the collection has been deleted out from under an
  /// indexed message — the row just says "Unknown" rather than blocking the
  /// rest of the panel.
  final Collection? collection;

  final double width;
  final VoidCallback onClose;
  final VoidCallback? onToggleWidth;
  final VoidCallback? onOpenReader;
  final bool isWide;

  static final DateFormat _dateFormat = DateFormat.yMMMd().add_jm();

  /// Height of the body preview, matched to the file sidebar's preview so the
  /// two panels line up when the user moves between result kinds.
  double get _bodyHeight => (width / 1.5).clamp(200.0, 500.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subject = email.subject?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchSidebarHeader(
          icon: Icons.mail_outline,
          title: 'Email Details',
          isWide: isWide,
          onToggleWidth: onToggleWidth,
          onClose: onClose,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject == null || subject.isEmpty ? '(No subject)' : subject,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),

                // The message itself. EmailDetails lays itself out with an
                // Expanded WebView, so it has to be given a bounded height
                // inside this scroll view or it fails to lay out at all.
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: _bodyHeight,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withValues(
                          alpha: 0.3,
                        ),
                      ),
                    ),
                    child: EmailDetails(email: email),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: onOpenReader,
                    icon: const Icon(Icons.open_in_full, size: 16),
                    label: const Text('Read full message'),
                  ),
                ),
                const SizedBox(height: 8),

                SectionWidget(
                  title: 'Message',
                  icon: Icons.info_outline,
                  children: [
                    infoRow('From', email.from, tooltip: email.from),
                    infoRow(
                      'To',
                      _joinAddresses(email.to),
                      tooltip: _joinAddresses(email.to),
                    ),
                    if (email.cc != null && email.cc!.isNotEmpty)
                      infoRow(
                        'Cc',
                        _joinAddresses(email.cc!),
                        tooltip: _joinAddresses(email.cc!),
                      ),
                    infoRow('Date', _dateFormat.format(email.date)),
                    infoRow('Status', email.isRead ? 'Read' : 'Unread'),
                    infoRow(
                      'Attachments',
                      email.hasAttachments ? 'Yes' : 'None',
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                SectionWidget(
                  title: 'Source',
                  icon: Icons.inbox_outlined,
                  children: [
                    infoRow('Account', collection?.name ?? 'Unknown'),
                    if (email.folderId != null && email.folderId!.isNotEmpty)
                      infoRow('Folder', email.folderId!),
                    if (email.labels != null && email.labels!.isNotEmpty)
                      infoRow('Labels', email.labels!.join(', ')),
                    if (email.messageId != null && email.messageId!.isNotEmpty)
                      infoRowSelectable('Message ID', email.messageId!),
                    if (email.threadId != null && email.threadId!.isNotEmpty)
                      infoRowSelectable('Thread ID', email.threadId!),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _joinAddresses(List<String> addresses) =>
      addresses.isEmpty ? '—' : addresses.join(', ');
}
