import 'dart:convert';

/// The result of the independent model that reviews one gated tool call.
class AgentReviewDecision {
  const AgentReviewDecision({required this.decision, required this.reason});

  final String decision;
  final String reason;

  bool get isAllow => decision == 'allow';
  bool get isAskUser => decision == 'ask_user';
  bool get isDeny => decision == 'deny';

  factory AgentReviewDecision.allow(String reason) {
    return AgentReviewDecision(decision: 'allow', reason: reason);
  }

  factory AgentReviewDecision.askUser(String reason) {
    return AgentReviewDecision(decision: 'ask_user', reason: reason);
  }

  factory AgentReviewDecision.deny(String reason) {
    return AgentReviewDecision(decision: 'deny', reason: reason);
  }
}

AgentReviewDecision parseAgentReviewDecision(String content) {
  final value = content.trim();
  if (value.isEmpty) throw const FormatException('审查模型没有返回决定');

  final candidates = <String>[value];
  if (value.startsWith('```')) {
    final firstLine = value.indexOf('\n');
    final lastFence = value.lastIndexOf('```');
    if (firstLine > 0 && lastFence > firstLine) {
      candidates.add(value.substring(firstLine + 1, lastFence).trim());
    }
  }
  final start = value.indexOf('{');
  final end = value.lastIndexOf('}');
  if (start >= 0 && end > start) {
    candidates.add(value.substring(start, end + 1));
  }

  Object? decoded;
  for (final candidate in candidates) {
    try {
      decoded = jsonDecode(candidate);
      break;
    } on FormatException {
      // Try the next common model response shape.
    }
  }
  if (decoded is! Map) {
    throw const FormatException('审查模型返回的不是 JSON 对象');
  }
  final map = Map<String, Object?>.from(decoded);
  final decision = map['decision'];
  if (decision is! String ||
      (decision != 'allow' && decision != 'ask_user' && decision != 'deny')) {
    throw const FormatException('审查决定必须是 allow、ask_user 或 deny');
  }
  final reason = map['reason'];
  return AgentReviewDecision(
    decision: decision,
    reason: reason is String && reason.trim().isNotEmpty
        ? reason.trim()
        : '审查模型未提供原因',
  );
}
