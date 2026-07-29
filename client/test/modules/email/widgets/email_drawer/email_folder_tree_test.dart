import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer/email_folder_tree.dart';

EmailFolder folder(String id, {String? parentId, String? name}) => EmailFolder(
  id: id,
  collectionId: 'c1',
  name: name ?? id,
  parentId: parentId,
);

void main() {
  group('buildEmailFolderTree', () {
    test('nests children directly under their parent, depth-first', () {
      // The shape mnimer_digitalchef.pst actually imports: everything hangs off
      // a container folder that holds no mail of its own.
      final nodes = buildEmailFolderTree([
        folder('nonAllaire'),
        folder('digitalChef', parentId: 'nonAllaire'),
        folder('bugs', parentId: 'digitalChef'),
        folder('feedback', parentId: 'digitalChef'),
      ]);

      expect(
        nodes.map((n) => '${n.folder.id}@${n.depth}').toList(),
        ['nonAllaire@0', 'digitalChef@1', 'bugs@2', 'feedback@2'],
      );
    });

    test('preserves the caller-supplied order among siblings', () {
      // The drawer sorts by name before calling; siblings must not be reordered
      // by the grouping, or the sidebar stops being alphabetical.
      final nodes = buildEmailFolderTree([
        folder('root'),
        folder('apple', parentId: 'root'),
        folder('banana', parentId: 'root'),
        folder('cherry', parentId: 'root'),
      ]);

      expect(nodes.map((n) => n.folder.id).toList(), [
        'root',
        'apple',
        'banana',
        'cherry',
      ]);
    });

    test('promotes a folder whose parent is not in the list', () {
      // Happens routinely: the parent was pinned as the Inbox/Trash tile, or was
      // filtered out for being empty. The child must still be reachable — a
      // folder holding mail may never vanish from the sidebar.
      final nodes = buildEmailFolderTree([
        folder('orphan', parentId: 'pinnedInbox'),
        folder('normal'),
      ]);

      expect(nodes.length, 2);
      expect(nodes.every((n) => n.depth == 0), isTrue);
      expect(nodes.map((n) => n.folder.id), containsAll(['orphan', 'normal']));
    });

    test('emits every folder exactly once when parentIds form a cycle', () {
      // A corrupt or hand-edited archive could produce this. The walk must not
      // recurse forever, and must not silently drop the folders in the cycle.
      final nodes = buildEmailFolderTree([
        folder('a', parentId: 'b'),
        folder('b', parentId: 'a'),
        folder('standalone'),
      ]);

      expect(nodes.map((n) => n.folder.id).toList()..sort(), [
        'a',
        'b',
        'standalone',
      ]);
    });

    test('treats a folder parented to itself as a root', () {
      final nodes = buildEmailFolderTree([folder('self', parentId: 'self')]);

      expect(nodes.length, 1);
      expect(nodes.single.depth, 0);
    });

    test('returns an empty list for no folders', () {
      expect(buildEmailFolderTree([]), isEmpty);
    });
  });
}
