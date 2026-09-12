import 'package:anx_reader/service/ai/langchain_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final guidance = localAgentGuidance(
    today: DateTime(2026, 9, 2),
    languageName: '简体中文',
  );

  test('carries today, zero-padded', () {
    // Without it a "last seven days" question was filled with dates from 2024.
    expect(guidance, contains('Today is 2026-09-02'));
  });

  test('names the reply language outright', () {
    expect(guidance, contains('Reply in 简体中文'));
  });

  test('steers towards the digest before any tool', () {
    expect(guidance, contains('Call a tool only when'));
    expect(guidance, contains('Never invent'));
  });

  test('stays a fraction of the full agent guidance', () {
    // The full guidance is about 2,900 characters and measured worse.
    expect(guidance.length, lessThan(900));
  });
}
