import 'dart:convert';

final _reviewSecretFieldPattern = RegExp(
  r'(?:password|passwd|passphrase|token|secret|api[_-]?key|private[_-]?key|credential)',
  caseSensitive: false,
);
final _reviewSecretOptionPattern = RegExp(
  r'--?(?:password|passwd|passphrase|token|secret|api[_-]?key|private[_-]?key)\s+[^\s]+',
  caseSensitive: false,
);
final _reviewSecretAssignmentPattern = RegExp(
  r'(?:password|passwd|passphrase|token|secret|api[_-]?key|private[_-]?key)\s*[=:]\s*[^\s]+',
  caseSensitive: false,
);
final _reviewBearerPattern = RegExp(r'Bearer\s+[^\s]+', caseSensitive: false);
final _reviewSshpassPattern = RegExp(
  r'sshpass\s+-p\s+[^\s]+',
  caseSensitive: false,
);

/// Removes common credential values before a tool call is sent to the review
/// model. The command itself remains available for risk classification.
Object? redactReviewInput(Object? value) {
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': _reviewSecretFieldPattern.hasMatch('${entry.key}')
            ? '[REDACTED]'
            : redactReviewInput(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) redactReviewInput(item)];
  }
  if (value is String) {
    var result = value;
    result = result.replaceAllMapped(
      _reviewSecretOptionPattern,
      (_) => '[REDACTED]',
    );
    result = result.replaceAllMapped(
      _reviewSecretAssignmentPattern,
      (_) => '[REDACTED]',
    );
    result = result.replaceAllMapped(
      _reviewBearerPattern,
      (_) => 'Bearer [REDACTED]',
    );
    return result.replaceAllMapped(
      _reviewSshpassPattern,
      (_) => 'sshpass -p [REDACTED]',
    );
  }
  return value;
}

/// The result of the independent model that reviews one gated tool call.
class AgentReviewDecision {
  const AgentReviewDecision({
    required this.decision,
    required this.reason,
    this.failureCode,
  });

  final String decision;
  final String reason;
  final String? failureCode;

  bool get isAllow => decision == 'allow';
  bool get isAskUser => decision == 'ask_user';
  bool get isDeny => decision == 'deny';
  bool get isFailure => failureCode != null;

  factory AgentReviewDecision.allow(String reason) {
    return AgentReviewDecision(decision: 'allow', reason: reason);
  }

  factory AgentReviewDecision.askUser(String reason) {
    return AgentReviewDecision(decision: 'ask_user', reason: reason);
  }

  factory AgentReviewDecision.deny(String reason) {
    return AgentReviewDecision(decision: 'deny', reason: reason);
  }

  factory AgentReviewDecision.failure(
    String reason, {
    String code = 'review_failed',
  }) {
    return AgentReviewDecision(
      decision: 'ask_user',
      reason: reason,
      failureCode: code,
    );
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
