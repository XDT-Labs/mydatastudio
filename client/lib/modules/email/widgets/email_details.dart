import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/modules/email/services/email_body_preparer.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/email/widgets/email_detail/email_attachments_section.dart';
import 'package:mydatastudio/modules/email/widgets/email_detail/email_body_view.dart';
import 'package:material_ui/material_ui.dart';

class EmailDetails extends StatefulWidget {
  const EmailDetails({super.key, required this.email});

  final Email email;

  @override
  State<EmailDetails> createState() => _EmailDetails();
}

class _EmailDetails extends State<EmailDetails> {
  PreparedEmailBody? _body;

  /// Attachments to show in the strip below the body — the ones the message
  /// embeds are inlined into the HTML instead and deliberately left out.
  List<model.File> _attachments = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(EmailDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.email.id != widget.email.id) {
      _load();
    }
  }

  /// Fetches attachments and renders the body.
  ///
  /// One pass, in this order, because the body can't be built until the
  /// attachments are known: an HTML message embeds its images as
  /// `cid:` references that only resolve against the extracted files.
  Future<void> _load() async {
    final emailId = widget.email.id;
    final repo = EmailRepository(DatabaseManager.instance.database!);
    final attachments = await repo.getAttachments(emailId);

    // Arrow-key navigation can move on while this is in flight; anything
    // rendered now would belong to a message that is no longer open.
    if (!mounted || widget.email.id != emailId) return;

    final body = await EmailBodyPreparer.prepare(
      htmlBody: widget.email.htmlBody,
      plainBody: widget.email.plainBody,
      attachments: attachments,
    );
    if (!mounted || widget.email.id != emailId) return;

    setState(() {
      _body = body;
      // Two signals, because they cover different mail. `isInline` is what the
      // scanners recorded at import; `inlinedAttachmentIds` is what this render
      // actually resolved, which still catches archives scanned before the flag
      // existed and never got the backfill.
      _attachments =
          attachments
              .where(
                (a) => !a.isInline && !body.inlinedAttachmentIds.contains(a.id),
              )
              .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = _body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child:
              body == null
                  ? const SizedBox.shrink()
                  : EmailBodyView.forPlatform(body),
        ),
        if (_attachments.isNotEmpty)
          EmailAttachmentsSection(attachments: _attachments),
      ],
    );
  }
}
