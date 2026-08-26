import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/models.dart';

class ProviderUsageClient {
  ProviderUsageClient({http.Client? client})
    : _client = client ?? http.Client();

  static const responseLimitBytes = 512 * 1024;
  static const timeout = Duration(seconds: 12);

  final http.Client _client;

  Future<ProviderUsageSnapshot> fetch(
    ProviderProfile profile,
    String apiKey,
  ) async {
    final endpoint = usageEndpoint(profile.baseUrl);
    try {
      final response = await _client
          .get(
            endpoint,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
          )
          .timeout(timeout);
      final body = response.body;
      if (utf8.encode(body).length > responseLimitBytes) {
        throw const ProviderUsageException('供应商额度响应过大');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ProviderUsageException(_statusMessage(response.statusCode));
      }
      final decoded = body.isEmpty
          ? const <String, Object?>{}
          : jsonDecode(body);
      if (decoded is! Map) {
        throw const ProviderUsageException('供应商额度接口返回格式不正确');
      }
      return _normalize(profile.id, Map<String, Object?>.from(decoded));
    } on ProviderUsageException {
      rethrow;
    } on FormatException {
      throw const ProviderUsageException('供应商未提供可识别的额度接口');
    } catch (_) {
      throw const ProviderUsageException('额度查询失败，请稍后重试');
    }
  }

  static Uri usageEndpoint(String baseUrl) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw const ProviderUsageException('供应商地址无效');
    }
    final host = base.host.toLowerCase();
    final origin = base.replace(path: '', query: '', fragment: '');
    if (host == 'api.deepseek.com' || host.endsWith('.deepseek.com')) {
      return origin.replace(path: '/user/balance');
    }
    if (host == 'opencode.ai' && base.path.toLowerCase().contains('/zen/go')) {
      return _appendPath(base, 'usage');
    }
    final isGateway =
        host == 'wflapi.cloud' ||
        host.endsWith('.wflapi.cloud') ||
        host == 'ai-pixel.online' ||
        host.endsWith('.ai-pixel.online');
    if (isGateway) {
      final path = base.path.replaceFirst(RegExp(r'/+$'), '');
      final versioned = path.endsWith('/v1') ? path : '$path/v1';
      return base.replace(path: '$versioned/usage', query: '', fragment: '');
    }
    return _appendPath(base, 'usage');
  }

  static ProviderUsageSnapshot _normalize(
    String providerId,
    Map<String, Object?> payload,
  ) {
    final windows = _usageWindows(payload);
    if (windows.isNotEmpty) {
      final limited = windows.any(
        (window) =>
            const {'limited', 'exhausted', 'blocked'}.contains(window.status),
      );
      return ProviderUsageSnapshot(
        providerId: providerId,
        status: payload['isValid'] == false
            ? 'invalid'
            : limited
            ? 'limited'
            : 'ok',
        windows: windows,
        planName: _text(
          payload['planName'] ??
              (payload['plan'] is Map
                  ? (payload['plan'] as Map)['name']
                  : null),
        ),
        mode: _text(payload['mode']),
      );
    }

    final deepSeek = _deepSeekBalance(payload);
    if (deepSeek != null) {
      return ProviderUsageSnapshot(
        providerId: providerId,
        status: payload['is_available'] == false ? 'invalid' : 'ok',
        balance: deepSeek,
      );
    }

    final gatewayBalance = _gatewayBalance(payload);
    if (gatewayBalance != null) {
      final usage = payload['usage'];
      final today = usage is Map && usage['today'] is Map
          ? Map<Object?, Object?>.from(usage['today'] as Map)
          : null;
      return ProviderUsageSnapshot(
        providerId: providerId,
        status: payload['isValid'] == false ? 'invalid' : 'ok',
        balance: gatewayBalance,
        planName: _text(payload['planName']),
        mode: _text(payload['mode']),
        todayRequests: _integer(today?['requests']),
        todayCost: _number(today?['actual_cost'] ?? today?['cost']),
      );
    }

    throw const ProviderUsageException('供应商未提供可识别的额度接口');
  }

  static List<ProviderUsageWindow> _usageWindows(Map<String, Object?> payload) {
    Object? source =
        payload['usage'] ??
        payload['rateLimits'] ??
        payload['rate_limits'] ??
        payload['limits'] ??
        payload['quota'];
    final nested = payload['data'];
    if (source is! Map && nested is Map) {
      source =
          nested['usage'] ??
          nested['rateLimits'] ??
          nested['rate_limits'] ??
          nested['limits'] ??
          nested['quota'];
    }
    if (source is! Map) return const [];
    final result = <ProviderUsageWindow>[];
    for (final entry in source.entries) {
      final value = entry.value is List && (entry.value as List).isNotEmpty
          ? (entry.value as List).first
          : entry.value;
      if (value is! Map) continue;
      final percent = _percent(value);
      if (percent == null) continue;
      final rawStatus = '${value['status'] ?? 'ok'}'.toLowerCase();
      final status = percent >= 100 && rawStatus == 'ok'
          ? 'exhausted'
          : const {'ok', 'limited', 'exhausted', 'blocked'}.contains(rawStatus)
          ? rawStatus
          : 'ok';
      result.add(
        ProviderUsageWindow(
          label: _windowLabel('${entry.key}', value),
          usedPercent: percent.clamp(0, 100).toDouble(),
          status: status,
          resetsAt: _dateTime(
            value['resetsAt'] ?? value['resetAt'] ?? value['reset_at'],
          ),
        ),
      );
      if (result.length == 8) break;
    }
    return result;
  }

  static ProviderBalance? _deepSeekBalance(Map<String, Object?> payload) {
    final values = payload['balance_infos'];
    if (values is! List) return null;
    for (final value in values) {
      if (value is! Map) continue;
      final amount = _number(value['total_balance']);
      if (amount == null) continue;
      return ProviderBalance(
        amount: amount,
        remaining: amount,
        currency: _text(value['currency']) ?? '未知',
        granted: _number(value['granted_balance']),
        toppedUp: _number(value['topped_up_balance']),
      );
    }
    return null;
  }

  static ProviderBalance? _gatewayBalance(Map<String, Object?> payload) {
    final amount = _number(payload['balance']);
    final remaining = _number(payload['remaining']);
    if (amount == null && remaining == null) return null;
    return ProviderBalance(
      amount: amount ?? remaining!,
      remaining: remaining ?? amount!,
      currency: _text(payload['unit']) ?? '未知',
    );
  }

  static double? _percent(Map value) {
    var percent = _number(
      value['percent'] ??
          value['usedPercent'] ??
          value['used_percent'] ??
          value['usagePercent'] ??
          value['usage_percent'] ??
          value['utilization'],
    );
    if (percent != null && value['utilization'] != null && percent <= 1) {
      percent *= 100;
    }
    if (percent == null) {
      final used = _number(
        value['used'] ?? value['consumed'] ?? value['usedAmount'],
      );
      final limit = _number(value['limit'] ?? value['max'] ?? value['total']);
      final remaining = _number(value['remaining'] ?? value['left']);
      if (used != null && limit != null && limit > 0) {
        percent = used / limit * 100;
      } else if (remaining != null && limit != null && limit > 0) {
        percent = (limit - remaining) / limit * 100;
      }
    }
    return percent == null || !percent.isFinite ? null : percent;
  }

  static String _windowLabel(String key, Map value) {
    final normalized = key.toLowerCase().replaceAll('-', '_');
    final duration = _number(
      value['windowDurationMins'] ??
          value['window_duration_mins'] ??
          value['durationMins'],
    );
    if (const {
          'rolling',
          'five_hour',
          'five_hours',
          '5h',
          '5_hour',
        }.contains(normalized) ||
        duration == 300) {
      return '5 小时';
    }
    if (const {
          'weekly',
          'seven_day',
          'seven_days',
          '7d',
          '7_day',
        }.contains(normalized) ||
        duration == 10080) {
      return '7 天';
    }
    if (const {'monthly', 'month', '30d', '30_day'}.contains(normalized)) {
      return '本月';
    }
    return key;
  }

  static Uri _appendPath(Uri base, String suffix) {
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(path: '$path/$suffix', query: '', fragment: '');
  }

  static String? _text(Object? value) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? null : text;
  }

  static double? _number(Object? value) {
    if (value == null || value == '') return null;
    final number = double.tryParse('$value');
    return number != null && number.isFinite ? number : null;
  }

  static int? _integer(Object? value) {
    final number = _number(value);
    return number == null || number < 0 ? null : number.floor();
  }

  static DateTime? _dateTime(Object? value) {
    if (value == null) return null;
    final number = value is num ? value.toDouble() : double.tryParse('$value');
    if (number != null && number.isFinite) {
      return DateTime.fromMillisecondsSinceEpoch(
        (number < 10000000000 ? number * 1000 : number).round(),
        isUtc: true,
      );
    }
    return DateTime.tryParse('$value')?.toUtc();
  }

  static String _statusMessage(int statusCode) {
    if (statusCode == 404) return '供应商未提供可识别的额度接口';
    if (statusCode == 401 || statusCode == 403) return '供应商拒绝额度查询，可能需要额外权限';
    if (statusCode == 429) return '供应商额度查询受到限流';
    if (statusCode >= 500) return '供应商额度服务暂时不可用';
    return '供应商额度查询失败（HTTP $statusCode）';
  }

  void close() => _client.close();
}

class ProviderUsageException implements Exception {
  const ProviderUsageException(this.message);

  final String message;

  @override
  String toString() => message;
}
