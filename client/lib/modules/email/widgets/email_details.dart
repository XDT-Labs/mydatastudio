import 'package:mydatatools/models/tables/email.dart';
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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    _loadEmailContent();
  }

  @override
  void didUpdateWidget(EmailDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.email.id != widget.email.id) {
      _loadEmailContent();
    }
  }

  void _loadEmailContent() {
    String html = widget.email.htmlBody ?? 
        '<html><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">${widget.email.plainBody ?? "(empty)"}</body></html>';
    
    _controller.loadHtmlString(html);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: Colors.grey.shade300, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 1),
              ),
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
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
