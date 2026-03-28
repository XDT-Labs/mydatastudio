import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

class PdfPreviewWidget extends StatefulWidget {
  const PdfPreviewWidget({
    super.key,
    required this.filePath,
    required this.previewHeight,
    @visibleForTesting this.testController,
  });

  final String filePath;
  final double previewHeight;
  final PdfController? testController;

  @override
  State<PdfPreviewWidget> createState() => _PdfPreviewWidgetState();
}

class _PdfPreviewWidgetState extends State<PdfPreviewWidget> {
  PdfController? _pdfController;
  int _currentPage = 1;
  int _totalPages = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.testController != null) {
      _pdfController = widget.testController;
      _loading = false;
    } else {
      _initPdf();
    }
  }

  @override
  void didUpdateWidget(PdfPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _pdfController?.dispose();
      _pdfController = null;
      _currentPage = 1;
      _totalPages = 0;
      _error = null;
      if (widget.testController != null) {
        setState(() {
          _pdfController = widget.testController;
          _loading = false;
        });
      } else {
        setState(() => _loading = true);
        _initPdf();
      }
    }
  }

  Future<void> _initPdf() async {
    try {
      final doc = await PdfDocument.openFile(widget.filePath);
      final controller = PdfController(document: Future.value(doc));
      if (mounted) {
        setState(() {
          _pdfController = controller;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: Colors.grey.shade100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: widget.previewHeight,
              child: _buildViewer(),
            ),
            if (_totalPages > 0) _buildNavBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildViewer() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 32),
              const SizedBox(height: 8),
              Text(
                'Error loading PDF: $_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ],
          ),
        ),
      );
    }
    if (_loading || _pdfController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return PdfView(
      controller: _pdfController!,
      scrollDirection: Axis.horizontal,
      onDocumentLoaded: (doc) {
        if (mounted) setState(() => _totalPages = doc.pagesCount);
      },
      onPageChanged: (page) {
        if (mounted) setState(() => _currentPage = page);
      },
    );
  }

  Widget _buildNavBar() {
    return Container(
      color: Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed:
                _currentPage > 1
                    ? () => _pdfController?.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    )
                    : null,
          ),
          const SizedBox(width: 8),
          Text(
            'Page $_currentPage of $_totalPages',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed:
                _currentPage < _totalPages
                    ? () => _pdfController?.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    )
                    : null,
          ),
        ],
      ),
    );
  }
}
