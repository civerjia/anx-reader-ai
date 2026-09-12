import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/models/tb_group.dart';

class GroupsRepository {
  const GroupsRepository();

  Future<Map<int, TbGroup>> fetchByIds(Iterable<int> ids) async {
    final idList = ids.where((id) => id > 0).toSet().toList();
    if (idList.isEmpty) {
      return const <int, TbGroup>{};
    }

    final db = await DBHelper().database;
    final placeholders = List.filled(idList.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM tb_groups WHERE id IN ($placeholders)',
      idList,
    );

    final map = <int, TbGroup>{};
    for (final row in rows) {
      final group = _fromRow(row);
      map[group.id] = group;
    }
    return map;
  }

  /// Every group that has not been deleted.
  Future<List<TbGroup>> fetchAll() async {
    final db = await DBHelper().database;
    final rows = await db.rawQuery(
      'SELECT * FROM tb_groups WHERE is_deleted = 0 ORDER BY id',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  TbGroup _fromRow(Map<String, Object?> row) => TbGroup(
        id: row['id'] as int,
        name: row['name'] as String,
        parentId: row['parent_id'] as int?,
        isDeleted: row['is_deleted'] as int? ?? 0,
        createTime: row['create_time'] as String?,
        updateTime: row['update_time'] as String?,
      );
}
