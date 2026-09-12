import 'package:anx_reader/service/ai/tools/bookshelf_organize_tool.dart';
import 'package:anx_reader/service/ai/tools/input/bookshelf_organize_group_spec.dart';
import 'package:flutter_test/flutter_test.dart';

BookshelfOrganizeGroupSpec g(int id, List<int> books, {bool? createNew}) =>
    BookshelfOrganizeGroupSpec(groupId: id, bookIds: books, createNew: createNew);

void main() {
  test('an existing group keeps its id', () {
    final r = normalizeOrganizeGroups([g(5, [12, 7])], {5});
    expect(r.groups.single.groupId, 5);
    expect(r.groups.single.createNew, isFalse);
    expect(r.remapped, isEmpty);
  });

  test('a new group already named after a member book is left alone', () {
    final r = normalizeOrganizeGroups([g(12, [12, 7])], {});
    expect(r.groups.single.groupId, 12);
    expect(r.groups.single.createNew, isTrue);
    expect(r.remapped, isEmpty);
  });

  test('made-up group ids become member book ids, as measured on Qwen3.5-2B', () {
    // The model's actual plan: groups 8, 9, 10 for books 12, 7, 3.
    final r = normalizeOrganizeGroups(
      [g(8, [12]), g(9, [7]), g(10, [3])],
      {},
    );
    expect(r.groups.map((x) => x.groupId), [12, 7, 3]);
    expect(r.groups.every((x) => x.createNew == true), isTrue);
    expect(r.remapped, {8: 12, 9: 7, 10: 3});
  });

  test('a replacement never collides with an existing group', () {
    // Book 12 happens to share its id with group 12.
    final r = normalizeOrganizeGroups([g(99, [12, 7])], {12});
    expect(r.groups.single.groupId, 7);
    expect(r.remapped, {99: 7});
  });

  test('two new groups never share a replacement id', () {
    final r = normalizeOrganizeGroups([g(1, [3, 4]), g(2, [3, 5])], {});
    final ids = r.groups.map((x) => x.groupId).toList();
    expect(ids.toSet(), hasLength(2));
  });

  test('an existing id claimed as new is moved off the existing group', () {
    final r = normalizeOrganizeGroups([g(5, [21, 25], createNew: true)], {5});
    expect(r.groups.single.groupId, 21);
    expect(r.groups.single.createNew, isTrue);
  });

  test('nothing sound to substitute is left for validation to reject', () {
    final r = normalizeOrganizeGroups([g(0, [])], {});
    expect(r.groups.single.groupId, 0);
    expect(r.remapped, isEmpty);
  });
}
