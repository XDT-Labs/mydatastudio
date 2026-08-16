import 'package:flutter/services.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:rxdart/rxdart.dart';

class SelectionService {
  static final SelectionService _instance = SelectionService._();
  static SelectionService get instance => _instance;

  SelectionService._();

  final BehaviorSubject<Set<String>> selectedIds =
      BehaviorSubject<Set<String>>.seeded({});
  final BehaviorSubject<bool> isSelectionMode = BehaviorSubject<bool>.seeded(
    false,
  );

  String? _lastSelectedId;
  String? get lastSelectedId => _lastSelectedId;

  void selectSingle(String fileId) {
    _lastSelectedId = fileId;
    selectedIds.add({fileId});
    isSelectionMode.add(true);
  }

  void toggle(String fileId) {
    _lastSelectedId = fileId;
    final current = Set<String>.from(selectedIds.value);
    if (current.contains(fileId)) {
      current.remove(fileId);
    } else {
      current.add(fileId);
    }
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }

  void selectAll(List<String> fileIds) {
    if (fileIds.isNotEmpty) {
      _lastSelectedId = fileIds.last;
    }
    final current = Set<String>.from(selectedIds.value);
    current.addAll(fileIds);
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }

  void deselectMany(Iterable<String> fileIds) {
    final current = Set<String>.from(selectedIds.value);
    current.removeAll(fileIds);
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }

  void deselectAll() {
    _lastSelectedId = null;
    selectedIds.add({});
    isSelectionMode.add(false);
  }

  void selectRange(String fromId, String toId, List<File> orderedFiles) {
    final fromIndex = orderedFiles.indexWhere((f) => f.id == fromId);
    final toIndex = orderedFiles.indexWhere((f) => f.id == toId);

    if (fromIndex == -1 || toIndex == -1) {
      selectSingle(toId);
      return;
    }

    final start = fromIndex < toIndex ? fromIndex : toIndex;
    final end = fromIndex < toIndex ? toIndex : fromIndex;

    final current = Set<String>.from(selectedIds.value);
    for (int i = start; i <= end; i++) {
      current.add(orderedFiles[i].id);
    }
    _lastSelectedId = toId;
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }

  /// Handles a user click on [file] given the current list of [orderedFiles].
  ///
  /// Automatically checks for modifier keys:
  /// - `Cmd` (macOS) / `Ctrl` (Windows/Linux): Toggles selection of [file].
  /// - `Shift`: Selects all files in [orderedFiles] between the last selected file and [file].
  /// - Normal click: Clears previous selection and selects [file].
  void handleTap(File file, List<File> orderedFiles) {
    final isCmdOrCtrl =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (isShift && _lastSelectedId != null) {
      selectRange(_lastSelectedId!, file.id, orderedFiles);
    } else if (isCmdOrCtrl) {
      toggle(file.id);
    } else {
      selectSingle(file.id);
    }
  }

  /// Handles a user click directly on a checkbox for [file] given [orderedFiles].
  ///
  /// - `Shift`: Selects all files between the last selected item and [file].
  /// - Standard click: Toggles selection of [file] and sets it as last selected.
  void handleCheckboxTap(File file, List<File> orderedFiles) {
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (isShift && _lastSelectedId != null) {
      selectRange(_lastSelectedId!, file.id, orderedFiles);
    } else {
      toggle(file.id);
    }
  }
}
