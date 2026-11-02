import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

/// Lets the user choose which categories get a local copy, an optional size
/// cap, and whether the collection is indexed for search.
class ContentPolicyControls extends StatelessWidget {
  const ContentPolicyControls({
    super.key,
    required this.policy,
    required this.onChanged,
  });

  final ContentPolicy policy;
  final ValueChanged<ContentPolicy> onChanged;

  static const _labels = {
    ContentCategory.images: 'Images',
    ContentCategory.videos: 'Videos',
    ContentCategory.audio: 'Audio',
    ContentCategory.documents: 'Documents',
    ContentCategory.other: 'Other files',
  };

  static const _caps = <int?, String>{
    null: 'No size limit',
    10 * 1024 * 1024: 'Up to 10 MB',
    100 * 1024 * 1024: 'Up to 100 MB',
    1024 * 1024 * 1024: 'Up to 1 GB',
  };

  ContentPolicy _with({
    Set<ContentCategory>? categories,
    bool clearCap = false,
    int? cap,
    bool? index,
  }) => ContentPolicy(
    downloadCategories: categories ?? policy.downloadCategories,
    maxFileBytes: clearCap ? null : (cap ?? policy.maxFileBytes),
    index: index ?? policy.index,
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Save a local copy of',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        for (final c in ContentCategory.values)
          CheckboxListTile(
            key: ValueKey('category-${c.name}'),
            value: policy.downloadCategories.contains(c),
            onChanged: (on) {
              final next = {...policy.downloadCategories};
              on == true ? next.add(c) : next.remove(c);
              onChanged(_with(categories: next));
            },
            title: Text(_labels[c]!, style: const TextStyle(fontSize: 13)),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            visualDensity: VisualDensity.compact,
          ),
        const SizedBox(height: 4),
        DropdownButton<int?>(
          key: const ValueKey('size-cap'),
          value:
              _caps.containsKey(policy.maxFileBytes)
                  ? policy.maxFileBytes
                  : null,
          isExpanded: true,
          items: [
            for (final e in _caps.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(e.value, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged:
              (v) =>
                  onChanged(v == null ? _with(clearCap: true) : _with(cap: v)),
        ),
        SwitchListTile(
          key: const ValueKey('index-switch'),
          value: policy.index,
          onChanged: (v) => onChanged(_with(index: v)),
          title: const Text(
            'Index files for search',
            style: TextStyle(fontSize: 13),
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
