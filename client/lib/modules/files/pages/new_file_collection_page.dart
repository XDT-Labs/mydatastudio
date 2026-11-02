import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/pages/rx_files_page.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_form.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/file_source_catalog.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/local_files_tab_view.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

typedef ExistingCollectionPaths = Future<Set<String>> Function();

Future<Set<String>> _loadExistingCollectionPaths() async {
  final all =
      await CollectionRepository(
        DatabaseManager.instance.database!,
      ).collections();
  return all.map((c) => c.path).whereType<String>().toSet();
}

/// "Add files" page: a catalog of file sources, each opening its own form.
class NewFileCollectionPage extends StatefulWidget {
  const NewFileCollectionPage({super.key, this.detector, this.existingPaths});

  /// Injectable for tests; defaults to a real [SyncFolderDetector].
  final SyncFolderDetector? detector;

  /// Paths already used by a collection (their sync folders are hidden).
  final ExistingCollectionPaths? existingPaths;

  @override
  State<NewFileCollectionPage> createState() => _NewFileCollectionPage();
}

class _NewFileCollectionPage extends State<NewFileCollectionPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _path = TextEditingController();

  late final Future<List<FileSource>> _found = _findFolders();

  /// The source whose form is open; null shows the catalog.
  FileSource? _selected;

  /// Detected sync folders as catalog sources; ones already covered by a
  /// collection are kept but marked [FileSource.alreadyAdded].
  Future<List<FileSource>> _findFolders() async {
    try {
      final detected = (widget.detector ?? SyncFolderDetector()).detect();
      final existing =
          (await (widget.existingPaths ?? _loadExistingCollectionPaths)())
              .map(_normalize)
              .toList();
      return [
        for (final f in detected)
          FileSource.detected(
            f,
            alreadyAdded: existing.any(
              (e) =>
                  _normalize(f.path) == e || p.isWithin(e, _normalize(f.path)),
            ),
          ),
      ];
    } catch (e, st) {
      AppLogger(
        null,
      ).e('Sync folder detection failed', error: e, stackTrace: st);
      return const [];
    }
  }

  static String _normalize(String path) {
    final n = p.normalize(path);
    return n.length > 1 && n.endsWith('/') ? n.substring(0, n.length - 1) : n;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  void _open(FileSource source) {
    _name.text = source.detected?.displayName ?? '';
    _path.text = source.detected?.path ?? '';
    setState(() => _selected = source);
  }

  void _backToCatalog() => setState(() => _selected = null);

  @override
  Widget build(BuildContext context) {
    final selected = _selected;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child:
                selected == null
                    ? FutureBuilder<List<FileSource>>(
                      future: _found,
                      builder:
                          (context, snap) => FileSourceCatalog(
                            sources: [...?snap.data, ...FileSource.catalog],
                            detecting:
                                snap.connectionState != ConnectionState.done,
                            onSelected: _open,
                          ),
                    )
                    : _buildSourceForm(context, selected),
          ),
        ),
      ],
    );
  }

  Widget _buildSourceForm(BuildContext context, FileSource source) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: _backToCatalog,
          icon: const Icon(Icons.arrow_back),
          label: const Text('All sources'),
        ),
        const SizedBox(height: 16),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            source.icon,
            size: 32,
            color: theme.colorScheme.primary,
          ),
          title: Text(source.title, style: theme.textTheme.titleLarge),
          subtitle: Text(source.subtitle),
        ),
        const SizedBox(height: 16),
        switch (source.form) {
          FileSourceForm.folder => LocalFilesTabView(
            formKey: _formKey,
            nameController: _name,
            pathController: _path,
            intro: source.folderPrompt,
            onBrowse: _browse,
            onSave: () => _save(context),
            onCancel: _backToCatalog,
          ),
          FileSourceForm.googleDrive => CloudAccountForm.googleDrive(),
          FileSourceForm.dropbox => CloudAccountForm.dropbox(),
          FileSourceForm.none => const SizedBox.shrink(),
        },
      ],
    );
  }

  Future<void> _browse() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      _name.text = result.split('/').last;
      _path.text = result;
    }
  }

  /// Single creation path for a local file collection, shared by every
  /// folder-based source (manual pick, detected sync folder, drives).
  void _createLocalCollection(String name, String selectedPath) {
    final fc = Collection(
      id: const Uuid().v4().toString(),
      name: name,
      path: selectedPath,
      localCopyPath: selectedPath,
      type: 'file',
      scanner: AppConstants.scannerFileLocal,
      scanStatus: 'pending',
      needsReAuth: false,
    );

    CollectionRepository(
      DatabaseManager.instance.database!,
    ).addCollection(fc).then((_) {
      GetCollectionsService.instance.invoke(GetCollectionsServiceCommand(null));
      ScannerManager.getInstance().startScanner(fc);
      RxFilesPage.selectedCollection.add(fc);
    });
  }

  void _save(BuildContext context) {
    // validate() both answers the question and paints the errors, which is
    // what the old markAllAsTouched() branch existed to do.
    if (_formKey.currentState?.validate() ?? false) {
      _createLocalCollection(_name.text, _path.text);
      GoRouter.of(context).go('/files');
    }
  }
}
