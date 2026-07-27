import 'package:mydatastudio/models/tables/email_folder.dart';

/// One row in the flattened folder tree: the folder plus how deep to indent it.
class EmailFolderNode {
  final EmailFolder folder;
  final int depth;
  const EmailFolderNode(this.folder, this.depth);
}

/// Flattens [folders] into sidebar display order, depth-first, so a parent is
/// immediately followed by its children.
///
/// PST archives are the reason this exists: their folder trees come from the
/// file and are genuinely nested (mail sitting three levels down under a
/// container folder), and rendering them flat loses the structure the user
/// organised their mail with.
///
/// [folders] must already be sorted by name; siblings inherit that order.
///
/// Nothing in [folders] is ever dropped. A folder whose `parentId` is null —
/// or points at a folder not in this list, which happens when the parent was
/// pinned as Inbox/Trash or filtered out for being empty — is shown at the top
/// level. A `parentId` cycle would otherwise recurse forever, so each folder is
/// emitted at most once and any folder left stranded by a cycle is appended
/// flat.
List<EmailFolderNode> buildEmailFolderTree(List<EmailFolder> folders) {
  final byId = {for (final f in folders) f.id: f};
  final childrenByParent = <String, List<EmailFolder>>{};
  final roots = <EmailFolder>[];

  for (final f in folders) {
    final parentId = f.parentId;
    if (parentId != null && parentId != f.id && byId.containsKey(parentId)) {
      childrenByParent.putIfAbsent(parentId, () => []).add(f);
    } else {
      roots.add(f);
    }
  }

  final result = <EmailFolderNode>[];
  final visited = <String>{};

  void walk(EmailFolder folder, int depth) {
    if (!visited.add(folder.id)) return;
    result.add(EmailFolderNode(folder, depth));
    for (final child in childrenByParent[folder.id] ?? const <EmailFolder>[]) {
      walk(child, depth + 1);
    }
  }

  for (final root in roots) {
    walk(root, 0);
  }

  for (final f in folders) {
    if (visited.add(f.id)) {
      result.add(EmailFolderNode(f, 0));
    }
  }

  return result;
}
