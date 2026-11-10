import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/aichat/services/chat_tool_support.dart';
import 'package:mydatastudio/modules/search/services/search_detail_repository.dart';
import 'package:mydatastudio/modules/search/widgets/search_email_reader.dart';
import 'package:mydatastudio/modules/search/widgets/search_lightbox.dart';

/// The archive items an answer was built from, one click from opening.
///
/// Opens in the same reader and lightbox the search page uses, so an item
/// looks the same whichever way the user reached it.
class ToolSourcesRow extends StatelessWidget {
  const ToolSourcesRow({super.key, required this.sources});

  final List<ToolSource> sources;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final source in sources)
            ActionChip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                source.isEmail ? Icons.mail_outline : Icons.description_outlined,
                size: 16,
                color: cs.onSurfaceVariant,
              ),
              label: Text(
                source.date == null ? source.title : '${source.title} · ${source.date}',
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall,
              ),
              tooltip: 'Open ${source.title}',
              onPressed: () => _open(context, source),
            ),
        ],
      ),
    );
  }

  static Future<void> _open(BuildContext context, ToolSource source) async {
    const repo = SearchDetailRepository();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    Widget? viewer;
    void close() => navigator.pop();
    if (source.isEmail) {
      final email = await repo.emailById(source.rowId);
      if (email != null) viewer = SearchEmailReader(email: email, onClose: close);
    } else {
      final file = await repo.fileById(source.rowId);
      final collection =
          file == null ? null : await repo.collectionById(file.collectionId);
      if (file != null && collection != null) {
        viewer = SearchLightbox(file: file, collection: collection, onClose: close);
      }
    }

    if (viewer == null) {
      messenger.showSnackBar(
        SnackBar(content: Text('“${source.title}” is no longer in your archive.')),
      );
      return;
    }
    final page = viewer;
    await navigator.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(body: page),
      ),
    );
  }
}
