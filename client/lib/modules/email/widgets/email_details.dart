import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:mydatatools/modules/email/widgets/email_detail/email_attachments_section.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class EmailDetails extends StatefulWidget {
  const EmailDetails({
    super.key,
    required this.email,
    required this.width,
    required this.isExpanded,
    required this.onClose,
    required this.onExpand,
  });

  final Email email;
  final double width;
  final bool isExpanded;
  final VoidCallback onClose;
  final VoidCallback onExpand;

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
    // Remove script tags and content
    s = s.replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
    // Remove event handlers (on*)
    s = s.replaceAll(RegExp(r"""\s+on\w+\s*=\s*["'][^"']*["']""", caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s+on\w+\s*=\s*\S+', caseSensitive: false), '');
    // Remove dangerous tags
    s = s.replaceAll(RegExp(r'<(iframe|object|embed|form|applet|base)[\s\S]*?(/?>|</\1>)', caseSensitive: false), '');
    // Block javascript: URLs
    s = s.replaceAll(RegExp(r'javascript\s*:', caseSensitive: false), 'blocked:');
    // Remove existing meta tags (we inject our own CSP)
    s = s.replaceAll(RegExp(r'<meta[^>]*>', caseSensitive: false), '');

    // Inject CSP meta tag
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
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.surface),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
            ),
            child: Row(
              children: [
                const Icon(Icons.email_outlined, size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Email Details',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    widget.isExpanded
                        ? Icons.close_fullscreen
                        : Icons.open_in_full,
                    color: Colors.black,
                  ),
                  tooltip: widget.isExpanded ? 'Restore' : 'Expand',
                  onPressed: widget.onExpand,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Close',
                  onPressed: widget.onClose,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Content
          Expanded(child: WebViewWidget(controller: _controller)),

          // Attachments Row
          if (_attachments.isNotEmpty) _buildAttachmentsSection(),
        ],
      ),
    );
  }

  Widget _buildAttachmentsSection() {
    return EmailAttachmentsSection(attachments: _attachments);
  }

}
