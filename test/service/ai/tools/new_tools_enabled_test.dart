import 'package:anx_reader/service/ai/tools/ai_tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a selection saved before the knowledge tool existed gets it switched on', () {
    final ids = AiToolRegistry.withNewTools(['calculator', 'notes_search'], null);
    expect(ids, containsAll(['calculator', 'notes_search', 'knowledge_lookup']));
    expect(ids, isNot(contains('current_time')));
  });

  test('a tool the user saw and switched off stays off', () {
    final all = AiToolRegistry.defaultEnabledToolIds().toSet();
    final ids = AiToolRegistry.withNewTools(['calculator'], all);
    expect(ids, ['calculator']);
  });

  test('unknown ids are dropped', () {
    final all = AiToolRegistry.defaultEnabledToolIds().toSet();
    expect(AiToolRegistry.withNewTools(['calculator', 'no_such_tool'], all), ['calculator']);
  });
}
