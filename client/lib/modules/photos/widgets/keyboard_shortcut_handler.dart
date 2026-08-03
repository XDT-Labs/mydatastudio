import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart';

class OpenLightboxIntent extends Intent {
  const OpenLightboxIntent();
}

class ToggleInfoIntent extends Intent {
  const ToggleInfoIntent();
}

class EscapeIntent extends Intent {
  const EscapeIntent();
}

class ToggleFavoriteIntent extends Intent {
  const ToggleFavoriteIntent();
}

class DeleteSelectedIntent extends Intent {
  const DeleteSelectedIntent();
}

class SelectAllIntent extends Intent {
  const SelectAllIntent();
}

class ShowShortcutsIntent extends Intent {
  const ShowShortcutsIntent();
}

/// Wrapper widget that adds keyboard shortcut handling to the Photos module.
class KeyboardShortcutHandler extends StatefulWidget {
  final Widget child;
  final PhotosRepository? photosRepository;

  const KeyboardShortcutHandler({
    super.key,
    required this.child,
    this.photosRepository,
  });

  @override
  State<KeyboardShortcutHandler> createState() => _KeyboardShortcutHandlerState();
}

class _KeyboardShortcutHandlerState extends State<KeyboardShortcutHandler> {
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isEditing {
    final focusWidget = FocusManager.instance.primaryFocus?.context?.widget;
    return focusWidget is EditableText;
  }

  void _handleEscape() {
    if (ViewStateService.instance.lightboxMedia.value != null) {
      ViewStateService.instance.setLightboxMedia(null);
    } else if (ViewStateService.instance.isInfoOpen.value) {
      ViewStateService.instance.closeInfo();
    } else if (SelectionService.instance.selectedIds.value.isNotEmpty) {
      SelectionService.instance.deselectAll();
    }
  }

  void _handleOpenLightbox() {
    if (_isEditing) return;
    final lightbox = ViewStateService.instance.lightboxMedia.value;
    if (lightbox != null) {
      ViewStateService.instance.setLightboxMedia(null);
      return;
    }

    final files = PhotosService.instance.sink.valueOrNull ?? [];
    if (files.isEmpty) return;

    final selectedIds = SelectionService.instance.selectedIds.value;
    if (selectedIds.isNotEmpty) {
      final selectedFile = files.cast<File?>().firstWhere(
            (f) => f != null && selectedIds.contains(f.id),
            orElse: () => null,
          );
      if (selectedFile != null) {
        ViewStateService.instance.openLightbox(selectedFile);
        return;
      }
    }

    if (ViewStateService.instance.infoMedia.value != null) {
      ViewStateService.instance.openLightbox(ViewStateService.instance.infoMedia.value!);
      return;
    }

    ViewStateService.instance.openLightbox(files.first);
  }

  void _handleToggleInfo() {
    if (_isEditing) return;
    ViewStateService.instance.toggleInfo();
  }

  Future<void> _handleToggleFavorite() async {
    if (_isEditing) return;
    final repo = widget.photosRepository ?? PhotosRepository();
    final lightboxMedia = ViewStateService.instance.lightboxMedia.value;
    final infoMedia = ViewStateService.instance.infoMedia.value;
    final selectedIds = SelectionService.instance.selectedIds.value;

    if (lightboxMedia != null) {
      await repo.toggleFavorite(lightboxMedia.id);
      await PhotosService.instance.refresh();
    } else if (selectedIds.isNotEmpty) {
      await BatchActionService.instance.favoriteSelected(selectedIds);
      await PhotosService.instance.refresh();
    } else if (infoMedia != null) {
      await repo.toggleFavorite(infoMedia.id);
      await PhotosService.instance.refresh();
    }
  }

  Future<void> _handleDeleteSelected() async {
    if (_isEditing) return;
    final selectedIds = SelectionService.instance.selectedIds.value;
    if (selectedIds.isEmpty) return;

    final count = selectedIds.length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
        title: Text('Delete $count item(s)?'),
        content: const Text('Are you sure you want to move selected photos to trash?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await BatchActionService.instance.deleteSelected(selectedIds);
    }
  }

  void _handleSelectAll() {
    final files = PhotosService.instance.sink.valueOrNull ?? [];
    if (files.isNotEmpty) {
      SelectionService.instance.selectAll(files.map((f) => f.id).toList());
    }
  }

  void _handleShowShortcuts() {
    if (_isEditing) return;
    showDialog<void>(
      context: context,
      builder: (_) => const KeyboardShortcutsModal(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        LogicalKeySet(LogicalKeyboardKey.space): const OpenLightboxIntent(),
        LogicalKeySet(LogicalKeyboardKey.keyI): const ToggleInfoIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const EscapeIntent(),
        LogicalKeySet(LogicalKeyboardKey.keyF): const ToggleFavoriteIntent(),
        LogicalKeySet(LogicalKeyboardKey.delete): const DeleteSelectedIntent(),
        LogicalKeySet(LogicalKeyboardKey.backspace): const DeleteSelectedIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyA):
            const SelectAllIntent(),
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyA):
            const SelectAllIntent(),
        LogicalKeySet(LogicalKeyboardKey.question): const ShowShortcutsIntent(),
        LogicalKeySet(LogicalKeyboardKey.shift, LogicalKeyboardKey.slash):
            const ShowShortcutsIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenLightboxIntent: CallbackAction<OpenLightboxIntent>(
            onInvoke: (_) => _handleOpenLightbox(),
          ),
          ToggleInfoIntent: CallbackAction<ToggleInfoIntent>(
            onInvoke: (_) => _handleToggleInfo(),
          ),
          EscapeIntent: CallbackAction<EscapeIntent>(
            onInvoke: (_) => _handleEscape(),
          ),
          ToggleFavoriteIntent: CallbackAction<ToggleFavoriteIntent>(
            onInvoke: (_) => _handleToggleFavorite(),
          ),
          DeleteSelectedIntent: CallbackAction<DeleteSelectedIntent>(
            onInvoke: (_) => _handleDeleteSelected(),
          ),
          SelectAllIntent: CallbackAction<SelectAllIntent>(
            onInvoke: (_) => _handleSelectAll(),
          ),
          ShowShortcutsIntent: CallbackAction<ShowShortcutsIntent>(
            onInvoke: (_) => _handleShowShortcuts(),
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: widget.child,
        ),
      ),
    );
  }
}
