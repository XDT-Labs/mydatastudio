import 'dart:io' as io;
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:mydatatools/modules/email/services/email_repository.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:open_filex/open_filex.dart';

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

  void _loadEmailContent() {
    final htmlBody = widget.email.htmlBody;
    final plainBody = widget.email.plainBody;
    
    String html;
    if (htmlBody != null && htmlBody.trim().isNotEmpty) {
      html = htmlBody;
    } else if (plainBody != null && plainBody.trim().isNotEmpty) {
      html = '<html><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">$plainBody</body></html>';
    } else {
      html = '<html><body style="font-family: sans-serif; white-space: pre-wrap; padding: 16px;">(No content)</body></html>';
    }
    
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
          
          // Attachments Row
          if (_attachments.isNotEmpty) _buildAttachmentsSection(),
        ],
      ),
    );
  }

  Widget _buildAttachmentsSection() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(top: BorderSide(color: Colors.grey.shade200, width: 1)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${_attachments.length} Attachments',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _attachments.length,
              itemBuilder: (context, index) {
                final attachment = _attachments[index];
                return _buildAttachmentThumbnail(attachment);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentThumbnail(model.File file) {
    final isImage = file.contentType.startsWith('image/');
    
    return GestureDetector(
      onTap: () async {
        if (await io.File(file.path).exists()) {
          await OpenFilex.open(file.path);
        }
      },
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade300),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: isImage
                  ? Image.file(
                      io.File(file.path),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.broken_image, color: Colors.grey),
                    )
                  : Center(
                      child: Icon(
                        _getIconForType(file.contentType),
                        size: 32,
                        color: Colors.grey.shade400,
                      ),
                    ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              color: Colors.grey.shade50,
              child: Text(
                file.name,
                style: const TextStyle(fontSize: 10, overflow: TextOverflow.ellipsis),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getIconForType(String? mimeType) {
    if (mimeType == null) return Icons.insert_drive_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('text')) return Icons.description;
    if (mimeType.contains('zip') || mimeType.contains('compressed')) {
      return Icons.folder_zip;
    }
    if (mimeType.contains('video')) return Icons.video_file;
    if (mimeType.contains('audio')) return Icons.audio_file;
    return Icons.insert_drive_file;
  }
}
