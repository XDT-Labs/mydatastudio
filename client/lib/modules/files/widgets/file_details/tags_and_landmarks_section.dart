import 'package:flutter/material.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pill_list_section.dart';

/// Shows [fileId]'s tags and landmarks (from the `file_tags`/
/// `file_landmarks` join tables — tags can come from `FileDescriptionIsolate`
/// or be typed in manually; landmarks are AI-detected only), each as a
/// dismissible pill.
///
/// Loads its own data and reloads whenever [fileId] changes. The Tags
/// section always renders (it carries the manual-add affordance even with
/// no tags yet); Landmarks only renders once there's at least one. Includes
/// its own leading spacing when there's anything to show, so a caller can
/// place it directly between two other sections.
class TagsAndLandmarksSection extends StatefulWidget {
  const TagsAndLandmarksSection({super.key, required this.fileId});

  final String fileId;

  @override
  State<TagsAndLandmarksSection> createState() =>
      _TagsAndLandmarksSectionState();
}

class _TagsAndLandmarksSectionState extends State<TagsAndLandmarksSection> {
  List<String> _tags = [];
  List<String> _landmarks = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(TagsAndLandmarksSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileId != widget.fileId) {
      setState(() {
        _tags = [];
        _landmarks = [];
      });
      _load();
    }
  }

  // The DB connection can close out from under an in-flight query — the
  // vault locking, the app closing, or (in tests) teardown racing this
  // widget's disposal. That's a normal thing to lose a race against, not a
  // bug worth crashing over, so each of these treats it as "couldn't load/
  // save right now" rather than letting the exception escape unhandled.

  Future<void> _load() async {
    try {
      final repo = DatabaseManager.instance.repository;
      if (repo == null) return;
      final tags = await repo.getFileTags(widget.fileId);
      final landmarks = await repo.getFileLandmarks(widget.fileId);
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _landmarks = landmarks;
      });
    } catch (_) {}
  }

  Future<void> _addTag(String tag) async {
    if (mounted) setState(() => _tags = [..._tags, tag]..sort());
    try {
      await DatabaseManager.instance.repository?.addFileTag(
        widget.fileId,
        tag,
      );
    } catch (_) {}
  }

  Future<void> _deleteTag(String tag) async {
    if (mounted) {
      setState(() => _tags = _tags.where((t) => t != tag).toList());
    }
    try {
      await DatabaseManager.instance.repository?.deleteFileTag(
        widget.fileId,
        tag,
      );
    } catch (_) {}
  }

  Future<void> _deleteLandmark(String landmark) async {
    if (mounted) {
      setState(
        () => _landmarks = _landmarks.where((l) => l != landmark).toList(),
      );
    }
    try {
      await DatabaseManager.instance.repository?.deleteFileLandmark(
        widget.fileId,
        landmark,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        PillListSection(
          title: 'Tags',
          icon: Icons.label_outline,
          items: _tags,
          onDelete: _deleteTag,
          onAdd: _addTag,
        ),
        if (_landmarks.isNotEmpty) ...[
          const SizedBox(height: 16),
          PillListSection(
            title: 'Landmarks',
            icon: Icons.place_outlined,
            items: _landmarks,
            onDelete: _deleteLandmark,
          ),
        ],
      ],
    );
  }
}
