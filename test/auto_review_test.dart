import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/auto_review.dart';

void main() {
  test('review input redacts credential fields and command secrets', () {
    final value = redactReviewInput({
      'command':
          'curl -H "Authorization: Bearer bearer-secret" --token flag-secret',
      'password': 'password-secret',
      'nested': [
        {'api_key': 'api-secret'},
      ],
    }) as Map;

    final command = value['command'] as String;
    expect(command, contains('Bearer [REDACTED]'));
    expect(command, isNot(contains('bearer-secret')));
    expect(command, isNot(contains('flag-secret')));
    expect(value['password'], '[REDACTED]');
    expect((value['nested'] as List).single['api_key'], '[REDACTED]');
  });

  test('parses a strict review decision from JSON or a code fence', () {
    expect(
      parseAgentReviewDecision('{"decision":"allow","reason":"ok"}').isAllow,
      isTrue,
    );
    expect(
      parseAgentReviewDecision(
        '```json\n{"decision":"deny","reason":"no"}\n```',
      ).isDeny,
      isTrue,
    );
  });

  test('rejects a review response without a supported decision', () {
    expect(
      () => parseAgentReviewDecision('{"decision":"maybe"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
