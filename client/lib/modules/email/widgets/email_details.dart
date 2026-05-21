import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/modules/email/widgets/email_detail/email_attachments_section.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class EmailDetails extends StatefulWidget {
  const EmailDetails({super.key, required this.email});

  final Email email;

  @override
  State<EmailDetails> createState() => _EmailDetails();
}

class _EmailDetails extends State<EmailDetails> {
  late final WebViewController _controller;
  List<model.File> _attachments = [];

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _loadEmailContent();
    _fetchAttachments();
  }

  @override
  void didUpdateWidget(EmailDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.email.id != widget.email.id) {
      _loadEmailContent();
      _fetchAttachments();
    }
  }

  Future<void> _fetchAttachments() async {
    final repo = EmailRepository(DatabaseManager.instance.database!);
    final attachments = await repo.getAttachments(widget.email.id);
    if (mounted) {
      setState(() {
        _attachments = attachments;
      });
    }
  }

  static const _csp = '<meta http-equiv="Content-Security-Policy" '
      "content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:;\">";

  void _loadEmailContent() {
    final htmlBody = widget.email.htmlBody;
    final plainBody = widget.email.plainBody;

    String html;
    if (htmlBody != null && htmlBody.trim().isNotEmpty) {
      html = _sanitizeHtml(htmlBody);
    } else if (plainBody != null && plainBody.trim().isNotEmpty) {
      final escaped = _escapeHtml(plainBody);
      html =
          '<html><head>$_csp</head><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">$escaped</body></html>';
    } else {
      html =
          '<html><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">(No content)</body></html>';
    }

    _controller.loadHtmlString(html);
  }

  static String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _sanitizeHtml(String html) {
    var s = html;
    s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r"""\s+on\w+\s*=\s*["'][^"']*["']""", caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s+on\w+\s*=\s*\S+', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<(iframe|object|embed|form|applet|base)[\s\S]*?(/?>|</\1>)', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'javascript\s*:', caseSensitive: false), 'blocked:');
    s = s.replaceAll(RegExp(r'<meta[^>]*>', caseSensitive: false), '');

    if (s.contains(RegExp(r'<head', caseSensitive: false))) {
      s = s.replaceFirst(RegExp(r'<head([^>]*)>', caseSensitive: false), '<head\$1>$_csp');
    } else if (s.contains(RegExp(r'<html', caseSensitive: false))) {
      s = s.replaceFirst(RegExp(r'<html([^>]*)>', caseSensitive: false), '<html\$1><head>$_csp</head>');
    } else {
      s = '<html><head>$_csp</head><body>$s</body></html>';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: WebViewWidget(controller: _controller)),
        if (_attachments.isNotEmpty)
          EmailAttachmentsSection(attachments: _attachments),
      ],
    );
  }
}
