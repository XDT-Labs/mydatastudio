import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/section_widget.dart';

/// A [SectionWidget] of small pill-shaped chips, each with a delete (×)
/// button. Shared by the tags and landmarks sections — same look, different
/// data and delete callback.
///
/// When [onAdd] is provided, an extra "+" pill is appended that expands
/// into an inline text field for typing a new entry — so the section
/// renders (just the "+" pill) even with an empty [items]. Without [onAdd]
/// (landmarks, which are AI-detected only), the section renders nothing
/// when [items] is empty.
class PillListSection extends StatelessWidget {
  const PillListSection({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    required this.onDelete,
    this.onAdd,
  });

  final String title;
  final IconData icon;
  final List<String> items;
  final void Function(String item) onDelete;
  final void Function(String item)? onAdd;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && onAdd == null) return const SizedBox.shrink();

    return SectionWidget(
      title: title,
      icon: icon,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final item in items)
              _Pill(label: item, onDelete: () => onDelete(item)),
            if (onAdd != null) _AddPill(existing: items, onAdd: onAdd!),
          ],
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onDelete});

  final String label;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: 10, right: 4, top: 3, bottom: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.6,
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 11)),
          const SizedBox(width: 2),
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(999),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.close, size: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// A "+" pill that expands into a small inline text field for typing a new
/// entry, and collapses back once it's submitted or loses focus.
///
/// Deliberately understated — no persistent button, no dialog, just one
/// more pill until it's tapped — so it doesn't compete for attention with
/// the AI-generated tags sitting next to it.
class _AddPill extends StatefulWidget {
  const _AddPill({required this.existing, required this.onAdd});

  final List<String> existing;
  final void Function(String item) onAdd;

  @override
  State<_AddPill> createState() => _AddPillState();
}

class _AddPillState extends State<_AddPill> {
  bool _editing = false;
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) _commitAndClose();
  }

  void _commitAndClose() {
    final text = _controller.text.trim();
    // Case-insensitive dedup: the AI and the user might tag the same thing
    // with different casing ("Beach" vs "beach"), and that shouldn't
    // produce two visually-identical pills.
    final isDuplicate = widget.existing.any(
      (e) => e.toLowerCase() == text.toLowerCase(),
    );
    if (text.isNotEmpty && !isDuplicate) widget.onAdd(text);
    if (mounted) {
      setState(() {
        _editing = false;
        _controller.clear();
      });
    }
  }

  void _startEditing() {
    setState(() => _editing = true);
    // The field doesn't exist yet on this frame — focus it once it does.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!_editing) {
      return InkWell(
        onTap: _startEditing,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(
            Icons.add,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      );
    }

    return SizedBox(
      width: 96,
      height: 22,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        style: const TextStyle(fontSize: 11),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          hintText: 'New tag',
          hintStyle: const TextStyle(fontSize: 11),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.6,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(999),
            borderSide: BorderSide.none,
          ),
        ),
        onSubmitted: (_) => _commitAndClose(),
      ),
    );
  }
}
