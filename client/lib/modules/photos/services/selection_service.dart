import 'package:mydatastudio/models/tables/file.dart';
import 'package:rxdart/rxdart.dart';

class SelectionService {
  static final SelectionService _instance = SelectionService._();
  static SelectionService get instance => _instance;
  
  SelectionService._();

  final BehaviorSubject<Set<String>> selectedIds = BehaviorSubject<Set<String>>.seeded({});
  final BehaviorSubject<bool> isSelectionMode = BehaviorSubject<bool>.seeded(false);

  void selectSingle(String fileId) {
    selectedIds.add({fileId});
    isSelectionMode.add(true);
  }

  void toggle(String fileId) {
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
    final current = Set<String>.from(selectedIds.value);
    current.addAll(fileIds);
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }

  void deselectAll() {
    selectedIds.add({});
    isSelectionMode.add(false);
  }

  void selectRange(String fromId, String toId, List<File> orderedFiles) {
    final fromIndex = orderedFiles.indexWhere((f) => f.id == fromId);
    final toIndex = orderedFiles.indexWhere((f) => f.id == toId);
    
    if (fromIndex == -1 || toIndex == -1) return;

    final start = fromIndex < toIndex ? fromIndex : toIndex;
    final end = fromIndex < toIndex ? toIndex : fromIndex;

    final current = Set<String>.from(selectedIds.value);
    for (int i = start; i <= end; i++) {
      current.add(orderedFiles[i].id);
    }
    selectedIds.add(current);
    isSelectionMode.add(current.isNotEmpty);
  }
}
