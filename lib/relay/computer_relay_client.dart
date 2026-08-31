import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ComputerRelayException implements Exception {
  const ComputerRelayException(
    this.statusCode,
    this.message, {
    this.transportFailure = false,
    this.agentOffline = false,
  });

  final int statusCode;
  final String message;
  final bool transportFailure;
  final bool agentOffline;

  String get userMessage {
    if (agentOffline) {
      return '中转服务器连接成功，但 Windows Agent 未在线';
    }
    if (transportFailure) {
      return '连接中转服务器失败：$message';
    }
    if (statusCode == 401 || statusCode == 403) {
      return '中转服务器鉴权失败，请检查中转 API Token';
    }
    if (statusCode == 404 && message == 'device not registered') {
      return '中转服务器连接成功，但电脑尚未完成配对登记';
    }
    return '中转服务器返回 HTTP $statusCode：$message';
  }

  @override
  String toString() => userMessage;
}

class _PendingComputerCall {
  _PendingComputerCall({
    required this.deviceId,
    required this.operation,
    required this.payload,
  });

  final String deviceId;
  final String operation;
  final Map<String, Object?> payload;
  final Completer<Map<String, Object?>> completer =
      Completer<Map<String, Object?>>();
  var sent = false;
}

/// Client for one paired Windows Agent.
///
/// The phone and Agent use separate WebSocket connections to the relay. The
/// relay token is sent only in the phone WebSocket handshake; the device token
/// is never sent to the AI or included in a tool result. A disconnected call is
/// is never executed again after a disconnect because the command may already
/// have run. The same request id may be re-attached to the relay instead.
class ComputerRelayClient {
  ComputerRelayClient({
    required String baseUrl,
    required this.apiToken,
    http.Client? client,
  }) : _baseUrl = _normalizeBaseUrl(baseUrl),
       _client = client ?? http.Client();

  final String _baseUrl;
  final String apiToken;
  final http.Client _client;
  final Map<String, _PendingComputerCall> _pending = {};
  var _sequence = 0;
  WebSocket? _socket;
  Future<WebSocket>? _socketFuture;
  String? _socketFutureDeviceId;
  Completer<void>? _hello;
  String? _connectedDeviceId;
  Timer? _reconnectTimer;
  Future<void>? _reconnectFuture;
  var _reconnectDelay = const Duration(seconds: 1);
  var _closing = false;

  String? get connectedDeviceId => _connectedDeviceId;

  Future<Map<String, Object?>> deviceStatus(String deviceId) async {
    final response = await _rest(
      'GET',
      '/v1/devices/${Uri.encodeComponent(deviceId)}/status',
    );
    return _decodeObject(response);
  }

  Future<Map<String, Object?>> registerDevice({
    required String deviceId,
    required String name,
    required String deviceToken,
  }) async {
    final response = await _rest(
      'POST',
      '/v1/devices/${Uri.encodeComponent(deviceId)}/register',
      body: {'name': name, 'device_token': deviceToken},
    );
    return _decodeObject(response);
  }

  Future<Map<String, Object?>> call({
    required String deviceId,
    required String operation,
    Map<String, Object?> payload = const {},
    Duration timeout = const Duration(minutes: 10),
    Future<void>? cancellation,
  }) async {
    final requestId =
        'mobile-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final pending = _PendingComputerCall(
      deviceId: deviceId,
      operation: operation,
      payload: payload,
    );
    _pending[requestId] = pending;
    var cancelRequested = false;
    try {
      final socket = await _ensureSocket(deviceId);
      _sendRequest(socket, requestId, pending);
      if (cancellation == null) {
        return await pending.completer.future.timeout(timeout);
      }
      return await Future.any<Map<String, Object?>>([
        pending.completer.future,
        cancellation.then<Map<String, Object?>>((_) {
          cancelRequested = true;
          throw const ComputerRelayException(499, '电脑请求已取消');
        }),
      ]).timeout(timeout);
    } on TimeoutException {
      cancelRequested = true;
      _pending.remove(requestId);
      _sendCancel(deviceId, requestId);
      throw TimeoutException('电脑请求等待超时：$operation', timeout);
    } catch (_) {
      if (_pending.remove(requestId) != null && cancelRequested) {
        _sendCancel(deviceId, requestId);
      }
      rethrow;
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<WebSocket> _ensureSocket(String deviceId) async {
    if (_closing) throw StateError('电脑中转客户端正在关闭');
    final current = _socket;
    if (current != null &&
        current.readyState == WebSocket.open &&
        _connectedDeviceId == deviceId) {
      return current;
    }
    if (_connectedDeviceId != null && _connectedDeviceId != deviceId) {
      await _closeSocket(
        const ComputerRelayException(409, '客户端已切换电脑'),
        preservePending: false,
      );
    }
    final pending = _socketFuture;
    if (pending != null && _socketFutureDeviceId == deviceId) return pending;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    late Future<WebSocket> future;
    future = _openSocket(deviceId);
    _socketFuture = future;
    _socketFutureDeviceId = deviceId;
    try {
      return await future;
    } finally {
      if (identical(_socketFuture, future)) {
        _socketFuture = null;
        _socketFutureDeviceId = null;
      }
    }
  }

  Future<WebSocket> _openSocket(String deviceId) async {
    if (apiToken.trim().isEmpty) {
      throw const ComputerRelayException(401, '未配置中转服务器 API Token');
    }
    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        _webSocketUrl(deviceId),
        headers: {'Authorization': 'Bearer $apiToken'},
      ).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const ComputerRelayException(
        0,
        '中转服务器连接超时',
        transportFailure: true,
      );
    } on SocketException catch (error) {
      throw ComputerRelayException(
        0,
        '无法建立网络连接：${error.message}',
        transportFailure: true,
      );
    } on WebSocketException catch (error) {
      throw ComputerRelayException(
        0,
        'WebSocket 连接失败：${error.message}',
        transportFailure: true,
      );
    }
    if (_closing) {
      await socket.close();
      throw StateError('电脑中转客户端正在关闭');
    }
    _socket = socket;
    _connectedDeviceId = deviceId;
    _hello = Completer<void>();
    socket.pingInterval = const Duration(seconds: 20);
    socket.listen(
      _handleMessage,
      onError: (Object error, StackTrace stack) {
        unawaited(_closeSocket(error, expectedSocket: socket));
      },
      onDone: () {
        unawaited(
          _closeSocket(
            const ComputerRelayException(503, '电脑中转连接已断开'),
            expectedSocket: socket,
          ),
        );
      },
      cancelOnError: false,
    );
    final hello = _hello!;
    try {
      socket.add(
        jsonEncode({
          'type': 'hello',
          'device_id': deviceId,
          'pending_request_ids': [
            for (final entry in _pending.entries)
              if (entry.value.deviceId == deviceId) entry.key,
          ],
        }),
      );
    } on Object catch (error) {
      await _closeSocket(error, expectedSocket: socket);
      rethrow;
    }
    try {
      await hello.future.timeout(const Duration(seconds: 10));
    } on Object {
      await _closeSocket(
        const ComputerRelayException(503, '中转服务握手失败'),
        expectedSocket: socket,
      );
      rethrow;
    }
    return socket;
  }

  void _handleMessage(dynamic raw) {
    Map<String, Object?> message;
    try {
      final decoded = jsonDecode(
        raw is String ? raw : utf8.decode(raw as List<int>),
      );
      if (decoded is! Map) throw const FormatException('响应不是对象');
      message = Map<String, Object?>.from(decoded);
    } on Object catch (error) {
      unawaited(_closeSocket(error));
      return;
    }
    final type = message['type'];
    if (type == 'authenticated') {
      if (message['device_id'] != _connectedDeviceId) {
        unawaited(_closeSocket(const ComputerRelayException(409, '中转服务设备不一致')));
        return;
      }
      final hello = _hello;
      if (hello != null && !hello.isCompleted) hello.complete();
      return;
    }
    if (type != 'result') return;
    final requestId = message['request_id'];
    if (requestId is! String) return;
    final pending = _pending[requestId];
    if (pending == null || pending.completer.isCompleted) return;
    if (message['ok'] == true) {
      final result = message['result'];
      if (result is Map) {
        pending.completer.complete(Map<String, Object?>.from(result));
      } else {
        pending.completer.complete(<String, Object?>{'value': result});
      }
    } else {
      final errorText = _errorText(message['error']);
      final agentOffline = errorText.startsWith('Windows Agent 离线');
      pending.completer.completeError(
        ComputerRelayException(
          agentOffline ? 503 : 502,
          errorText,
          agentOffline: agentOffline,
        ),
      );
    }
  }

  void _sendRequest(
    WebSocket socket,
    String requestId,
    _PendingComputerCall pending,
  ) {
    if (socket.readyState != WebSocket.open) {
      throw const ComputerRelayException(503, '电脑中转连接已断开');
    }
    // Mark before add: after a socket write starts, retrying with the same
    // request id is the only safe way to resume without duplicating a command.
    pending.sent = true;
    try {
      socket.add(
        jsonEncode({
          'type': 'request',
          'request_id': requestId,
          'operation': pending.operation,
          'payload': pending.payload,
        }),
      );
    } on Object catch (error) {
      unawaited(_closeSocket(error, expectedSocket: socket));
      rethrow;
    }
  }

  Future<void> _closeSocket(
    Object error, {
    WebSocket? expectedSocket,
    bool preservePending = true,
  }) async {
    final socket = _socket;
    if (expectedSocket != null && !identical(socket, expectedSocket)) {
      if (expectedSocket.readyState == WebSocket.open) {
        try {
          await expectedSocket.close();
        } catch (_) {}
      }
      return;
    }
    final deviceId = _connectedDeviceId;
    _socket = null;
    _connectedDeviceId = null;
    final hello = _hello;
    _hello = null;
    if (hello != null && !hello.isCompleted) hello.completeError(error);
    if (_closing || !preservePending) {
      _failPending(error, deviceId: preservePending ? null : deviceId);
    } else if (deviceId != null && _hasPending(deviceId, sentOnly: true)) {
      _scheduleReconnect(deviceId);
    }
    if (socket != null && socket.readyState == WebSocket.open) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  void _failPending(Object error, {String? deviceId}) {
    final ids = [
      for (final entry in _pending.entries)
        if (deviceId == null || entry.value.deviceId == deviceId) entry.key,
    ];
    for (final requestId in ids) {
      final pending = _pending.remove(requestId);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
  }

  bool _hasPending(String deviceId, {bool sentOnly = false}) =>
      _pending.values.any(
        (pending) =>
            pending.deviceId == deviceId && (!sentOnly || pending.sent),
      );

  void _scheduleReconnect(String deviceId) {
    if (_closing || !_hasPending(deviceId, sentOnly: true)) return;
    if (_reconnectTimer != null || _reconnectFuture != null) return;
    final delay = _reconnectDelay;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      unawaited(_runReconnect(deviceId));
    });
  }

  Future<void> _runReconnect(String deviceId) async {
    if (_closing ||
        !_hasPending(deviceId, sentOnly: true) ||
        _reconnectFuture != null) {
      return;
    }
    late Future<void> future;
    future = _tryReconnect(deviceId);
    _reconnectFuture = future;
    try {
      await future;
    } finally {
      if (identical(_reconnectFuture, future)) _reconnectFuture = null;
    }
  }

  Future<void> _tryReconnect(String deviceId) async {
    if (_closing || !_hasPending(deviceId, sentOnly: true)) return;
    try {
      final socket = await _ensureSocket(deviceId);
      _reconnectDelay = const Duration(seconds: 1);
      final calls = [
        for (final entry in _pending.entries)
          if (entry.value.deviceId == deviceId && entry.value.sent)
            (entry.key, entry.value),
      ];
      for (final (requestId, pending) in calls) {
        if (!pending.completer.isCompleted &&
            identical(_pending[requestId], pending)) {
          _sendRequest(socket, requestId, pending);
        }
      }
    } catch (_) {
      if (_closing || !_hasPending(deviceId, sentOnly: true)) return;
      final milliseconds = (_reconnectDelay.inMilliseconds * 2).clamp(
        1_000,
        30_000,
      );
      _reconnectDelay = Duration(milliseconds: milliseconds.toInt());
      _scheduleReconnect(deviceId);
    }
  }

  void _sendCancel(String deviceId, String requestId) {
    final socket = _socket;
    if (socket == null ||
        socket.readyState != WebSocket.open ||
        _connectedDeviceId != deviceId) {
      return;
    }
    try {
      socket.add(jsonEncode({'type': 'cancel', 'request_id': requestId}));
    } catch (_) {}
  }

  Future<http.Response> _rest(
    String method,
    String path, {
    Object? body,
  }) async {
    final request = http.Request(method, Uri.parse('$_baseUrl$path'));
    request.headers['Accept'] = 'application/json';
    request.headers['Authorization'] = 'Bearer $apiToken';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 15));
      final result = await http.Response.fromStream(response);
      if (result.statusCode < 200 || result.statusCode >= 300) {
        throw ComputerRelayException(
          result.statusCode,
          _responseErrorText(result.body),
        );
      }
      return result;
    } on ComputerRelayException {
      rethrow;
    } on TimeoutException {
      throw const ComputerRelayException(
        0,
        '中转服务器连接超时',
        transportFailure: true,
      );
    } on SocketException catch (error) {
      throw ComputerRelayException(
        0,
        '无法建立网络连接：${error.message}',
        transportFailure: true,
      );
    } on http.ClientException catch (error) {
      throw ComputerRelayException(
        0,
        '网络请求失败：${error.message}',
        transportFailure: true,
      );
    }
  }

  static Map<String, Object?> _decodeObject(http.Response response) {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw const FormatException('中转响应不是对象');
    return Map<String, Object?>.from(decoded);
  }

  static String _errorText(Object? value) {
    final text = value is String
        ? value
        : value is Map && value['message'] is String
        ? value['message'] as String
        : value is Map && value['error'] is String
        ? value['error'] as String
        : '电脑请求失败';
    return text.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
  }

  static String _responseErrorText(String body) {
    if (body.trim().isEmpty) return '中转服务器未返回错误信息';
    try {
      return _errorText(jsonDecode(body));
    } on FormatException {
      return _errorText(body);
    }
  }

  String _webSocketUrl(String deviceId) {
    final uri = Uri.parse(_baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    return uri
        .replace(
          scheme: scheme,
          path:
              '${uri.path.replaceFirst(RegExp(r'/+$'), '')}/v1/devices/${Uri.encodeComponent(deviceId)}/ws',
        )
        .toString();
  }

  static String _normalizeBaseUrl(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw ArgumentError('中转服务器地址必须是有效的 http 或 https URL');
    }
    if (uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      throw ArgumentError('中转服务器地址不能包含账号、查询参数或片段');
    }
    return normalized;
  }

  Future<void> close() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _closeSocket(const ComputerRelayException(499, '电脑中转客户端已关闭'));
    _client.close();
  }
}
