import 'dart:math';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

class PdfPreviewWidget extends StatefulWidget {
  const PdfPreviewWidget({
    super.key,
    required this.filePath,
    required this.previewHeight,
  });

  final String filePath;
  final double previewHeight;

  @override
  State<PdfPreviewWidget> createState() => _PdfPreviewWidgetState();
}

class _PdfPreviewWidgetState extends State<PdfPreviewWidget> {
  PdfViewerController _controller = PdfViewerController();
  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void didUpdateWidget(PdfPreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath) {
      _controller = PdfViewerController();
      _currentPage = 1;
      _totalPages = 0;
    }
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
            SizedBox(height: widget.previewHeight, child: _buildViewer()),
            if (_totalPages > 0)
              PdfPageNavBar(
                currentPage: _currentPage,
                totalPages: _totalPages,
                onGoToPage: _goToPage,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewer() {
    return PdfViewer.file(
      widget.filePath,
      key: ValueKey(widget.filePath),
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor: Colors.grey.shade100,
        layoutPages: layoutPagesInARow,
        loadingBannerBuilder:
            (context, bytesDownloaded, totalBytes) =>
                const Center(child: CircularProgressIndicator()),
        errorBannerBuilder:
            (context, error, stackTrace, documentRef) => Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.red,
                      size: 32,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Error loading PDF: $error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
        onViewerReady: (document, controller) {
          if (mounted) setState(() => _totalPages = document.pages.length);
        },
        onPageChanged: (page) {
          if (mounted && page != null) setState(() => _currentPage = page);
        },
      ),
    );
  }

  void _goToPage(int pageNumber) {
    _controller.goToPage(
      pageNumber: pageNumber,
      duration: const Duration(milliseconds: 300),
    );
  }
}

/// Keeps the preview's left-to-right paging; pdfrx stacks pages vertically
/// by default.
@visibleForTesting
PdfPageLayout layoutPagesInARow(List<PdfPage> pages, PdfViewerParams params) {
  final height =
      pages.fold(0.0, (tallest, page) => max(tallest, page.height)) +
      params.margin * 2;
  final layouts = <Rect>[];
  var x = params.margin;
  for (final page in pages) {
    layouts.add(
      Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height),
    );
    x += page.width + params.margin;
  }
  return PdfPageLayout(pageLayouts: layouts, documentSize: Size(x, height));
}

@visibleForTesting
class PdfPageNavBar extends StatelessWidget {
  const PdfPageNavBar({
    super.key,
    required this.currentPage,
    required this.totalPages,
    required this.onGoToPage,
  });

  final int currentPage;
  final int totalPages;
  final void Function(int pageNumber) onGoToPage;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed:
                currentPage > 1 ? () => onGoToPage(currentPage - 1) : null,
          ),
          const SizedBox(width: 8),
          Text(
            'Page $currentPage of $totalPages',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            iconSize: 20,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            onPressed:
                currentPage < totalPages
                    ? () => onGoToPage(currentPage + 1)
                    : null,
          ),
        ],
      ),
    );
  }
}
