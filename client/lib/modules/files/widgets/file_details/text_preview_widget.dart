import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:xml/xml.dart';

class TextPreviewWidget extends StatefulWidget {
  const TextPreviewWidget({
    super.key,
    required this.file,
    required this.ext,
    required this.previewHeight,
    required this.onSave,
    this.initialContent,
  });

  final File file;
  final String ext;
  final double previewHeight;
  final Future<void> Function(String content) onSave;

  /// If provided, skips filesystem I/O and uses this content directly.
  final String? initialContent;

  @override
  State<TextPreviewWidget> createState() => _TextPreviewWidgetState();
}

class _TextPreviewWidgetState extends State<TextPreviewWidget> {
  String? _textContent;
  bool _loading = true;
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    if (widget.initialContent != null) {
      _textContent = widget.initialContent;
      _loading = false;
    } else {
      _loading = false; // parent has already loaded content
      _textContent = widget.initialContent;
    }
  }

  @override
  void didUpdateWidget(TextPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _isEditing = false;
      _editController.dispose();
      _editController = TextEditingController();
      if (widget.initialContent != null) {
        setState(() {
          _textContent = widget.initialContent;
          _loading = false;
        });
      } else {
        setState(() {
          _textContent = null;
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final content = _textContent;
    if (content == null) {
      return const SizedBox.shrink();
    }

    final isMarkdown = widget.ext == '.md' || widget.ext == '.markdown';

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: widget.previewHeight,
        width: double.infinity,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(isMarkdown),
            Expanded(
              child:
                  _isEditing
                      ? TextField(
                        controller: _editController,
                        maxLines: null,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(12),
                        ),
                        style: const TextStyle(
                          fontFamily: 'Courier',
                          fontSize: 13,
                        ),
                      )
                      : SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: _renderTextContent(content),
                      ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(bool isMarkdown) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: Colors.grey.shade100,
      child: Row(
        children: [
          Text(
            widget.ext.toUpperCase().replaceFirst('.', ''),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const Spacer(),
          if (isMarkdown &&
              !_isEditing &&
              !widget.file.path.startsWith('gdrive://'))
            TextButton.icon(
              key: const Key('edit_button'),
              onPressed: () {
                setState(() {
                  _isEditing = true;
                  _editController.text = _textContent!;
                });
              },
              icon: const Icon(Icons.edit, size: 14),
              label: const Text('Edit', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(50, 24),
              ),
            ),
          if (_isEditing) ...[
            TextButton(
              onPressed: () => setState(() => _isEditing = false),
              child: const Text(
                'Cancel',
                style: TextStyle(fontSize: 11, color: Colors.red),
              ),
            ),
            const SizedBox(width: 4),
            TextButton(
              key: const Key('save_button'),
              onPressed: () async {
                await widget.onSave(_editController.text);
                if (mounted) {
                  setState(() {
                    _textContent = _editController.text;
                    _isEditing = false;
                  });
                }
              },
              child: const Text(
                'Save',
                style: TextStyle(fontSize: 11, color: Colors.green),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _renderTextContent(String content) {
    if (widget.ext == '.md' || widget.ext == '.markdown') {
      return MarkdownBody(data: content);
    }
    if (widget.ext == '.xml' || widget.ext == '.xsl' || widget.ext == '.xslt') {
      return Text(
        _tidyXml(content),
        style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
      );
    }
    return Text(
      content,
      style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
    );
  }

  static String _tidyXml(String xmlString) {
    try {
      final document = XmlDocument.parse(xmlString);
      return document.toXmlString(pretty: true, indent: '  ');
    } catch (_) {
      return xmlString;
    }
  }
}
