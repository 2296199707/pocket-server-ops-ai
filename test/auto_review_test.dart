import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_agent/agent/auto_review.dart';

void main() {
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
