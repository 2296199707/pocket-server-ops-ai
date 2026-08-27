import 'dart:math' as math;

import '../domain/models.dart';

/// Provider usage normalized to the fields used by Codex's TokenUsage model.
/// A provider may use either Responses names or Chat Completions names.
class TokenUsageSnapshot {
  const TokenUsageSnapshot({
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.outputTokens,
    required this.reasoningOutputTokens,
    required this.totalTokens,
  });

  final int inputTokens;
  final int cachedInputTokens;
  final int outputTokens;
  final int reasoningOutputTokens;
  final int totalTokens;

  static TokenUsageSnapshot? fromProviderUsage(Map<String, Object?>? usage) {
    if (usage == null) return null;
    final input = _firstInt(usage, const ['input_tokens', 'prompt_tokens']);
    final output = _firstInt(usage, const [
      'output_tokens',
      'completion_tokens',
    ]);
    final totalValue = _firstInt(usage, const ['total_tokens']);
    final cached =
        _firstInt(usage, const ['cached_input_tokens']) ??
        _nestedInt(usage, 'input_tokens_details', 'cached_tokens') ??
        _nestedInt(usage, 'prompt_tokens_details', 'cached_tokens') ??
        0;
    final reasoning =
        _firstInt(usage, const [
          'reasoning_output_tokens',
          'reasoning_tokens',
        ]) ??
        _nestedInt(usage, 'output_tokens_details', 'reasoning_tokens') ??
        0;
    if (input == null && output == null && totalValue == null) return null;
    final inputTokens = input ?? 0;
    final outputTokens = output ?? 0;
    return TokenUsageSnapshot(
      inputTokens: inputTokens,
      cachedInputTokens: cached,
      outputTokens: outputTokens,
      reasoningOutputTokens: reasoning,
      totalTokens: totalValue ?? inputTokens + outputTokens,
    );
  }

  factory TokenUsageSnapshot.fromMap(Map<String, Object?> map) {
    return TokenUsageSnapshot(
      inputTokens: _firstInt(map, const ['input_tokens']) ?? 0,
      cachedInputTokens: _firstInt(map, const ['cached_input_tokens']) ?? 0,
      outputTokens: _firstInt(map, const ['output_tokens']) ?? 0,
      reasoningOutputTokens:
          _firstInt(map, const ['reasoning_output_tokens']) ?? 0,
      totalTokens: _firstInt(map, const ['total_tokens']) ?? 0,
    );
  }

  Map<String, Object?> toMap() => {
    'input_tokens': inputTokens,
    'cached_input_tokens': cachedInputTokens,
    'output_tokens': outputTokens,
    'reasoning_output_tokens': reasoningOutputTokens,
    'total_tokens': totalTokens,
  };

  TokenUsageSnapshot operator +(TokenUsageSnapshot other) {
    return TokenUsageSnapshot(
      inputTokens: inputTokens + other.inputTokens,
      cachedInputTokens: cachedInputTokens + other.cachedInputTokens,
      outputTokens: outputTokens + other.outputTokens,
      reasoningOutputTokens:
          reasoningOutputTokens + other.reasoningOutputTokens,
      totalTokens: totalTokens + other.totalTokens,
    );
  }
}

/// Durable context status for one conversation. [last] is the latest active
/// context usage, while [total] is the accumulated usage across requests.
/// This mirrors Codex's last_token_usage/total_token_usage distinction.
class TaskContextUsage {
  const TaskContextUsage({
    this.last,
    this.total,
    this.model,
    this.rawContextWindow,
    this.effectiveContextWindow,
    this.autoCompactTokenLimit,
    this.compactionCount = 0,
    this.metadataSource,
  });

  final TokenUsageSnapshot? last;
  final TokenUsageSnapshot? total;
  final String? model;
  final int? rawContextWindow;
  final int? effectiveContextWindow;
  final int? autoCompactTokenLimit;
  final int compactionCount;
  final String? metadataSource;

  factory TaskContextUsage.fromMap(Map<String, Object?> map) {
    // Accept the short names written by the first implementation as well as
    // the Codex names used by newer events.
    final rawLast = map['last_token_usage'] ?? map['last'];
    final rawTotal = map['total_token_usage'] ?? map['total'];
    return TaskContextUsage(
      last: rawLast is Map
          ? TokenUsageSnapshot.fromMap(Map<String, Object?>.from(rawLast))
          : null,
      total: rawTotal is Map
          ? TokenUsageSnapshot.fromMap(Map<String, Object?>.from(rawTotal))
          : null,
      model: map['model'] as String?,
      rawContextWindow: _firstInt(map, const ['raw_context_window']),
      effectiveContextWindow: _firstInt(map, const [
        'effective_context_window',
        'model_context_window',
      ]),
      autoCompactTokenLimit: _firstInt(map, const ['auto_compact_token_limit']),
      compactionCount: _firstInt(map, const ['compaction_count']) ?? 0,
      metadataSource: map['metadata_source'] as String?,
    );
  }

  Map<String, Object?> toMap() => {
    if (last != null) 'last_token_usage': last!.toMap(),
    if (total != null) 'total_token_usage': total!.toMap(),
    if (model != null) 'model': model,
    if (rawContextWindow != null) 'raw_context_window': rawContextWindow,
    if (effectiveContextWindow != null)
      'effective_context_window': effectiveContextWindow,
    if (effectiveContextWindow != null)
      'model_context_window': effectiveContextWindow,
    if (autoCompactTokenLimit != null)
      'auto_compact_token_limit': autoCompactTokenLimit,
    'compaction_count': compactionCount,
    if (metadataSource != null) 'metadata_source': metadataSource,
  };

  TaskContextUsage withMetadata(
    ProviderModelMetadata? metadata, {
    String? selectedModel,
    String contextWindowMode = defaultContextWindowMode,
  }) {
    return TaskContextUsage(
      last: last,
      total: total,
      model: selectedModel ?? model,
      rawContextWindow: metadata?.resolveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      effectiveContextWindow: metadata?.resolveEffectiveContextWindowTokens(
        contextWindowMode: contextWindowMode,
      ),
      autoCompactTokenLimit: metadata?.resolveAutoCompactTokenLimit(
        contextWindowMode: contextWindowMode,
      ),
      compactionCount: compactionCount,
      metadataSource: metadata?.source,
    );
  }

  int? get remainingPercent {
    final window = effectiveContextWindow;
    final used = last?.totalTokens;
    if (window == null || used == null) return null;

    // Match Codex's status-card calculation. The effective window leaves a
    // 12k baseline for instructions and fixed overhead, so both the window
    // and current usage are measured after that baseline.
    if (window <= _codexContextBaselineTokens) return 0;
    final usableWindow = window - _codexContextBaselineTokens;
    final active = math.max(used - _codexContextBaselineTokens, 0);
    return ((math.max(usableWindow - active, 0) / usableWindow) * 100)
        .round()
        .clamp(0, 100);
  }

  int? get usedPercent {
    final remaining = remainingPercent;
    return remaining == null ? null : 100 - remaining;
  }
}

const _codexContextBaselineTokens = 12000;

int? _firstInt(Map<String, Object?> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
  }
  return null;
}

int? _nestedInt(Map<String, Object?> map, String parent, String key) {
  final value = map[parent];
  if (value is! Map) return null;
  return _firstInt(Map<String, Object?>.from(value), [key]);
}
