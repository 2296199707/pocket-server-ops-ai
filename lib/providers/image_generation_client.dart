import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ImageGenerationResult {
  const ImageGenerationResult({this.b64Json, this.url, this.revisedPrompt});

  /// Base64-encoded image data returned by the provider, when available.
  final String? b64Json;

  /// Image URL returned by the provider, when available.
  final String? url;

  /// The provider's rewritten prompt, when available.
  final String? revisedPrompt;

  bool get hasBase64 => b64Json != null;

  bool get hasUrl => url != null;
}

class DownloadedImage {
  const DownloadedImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}

class ImageGenerationException implements Exception {
  const ImageGenerationException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ImageGenerationHttpException extends ImageGenerationException {
  ImageGenerationHttpException({required int statusCode, required this.body})
    : super(
        '图片生成请求失败（HTTP $statusCode）${body.isEmpty ? '' : '：$body'}',
        statusCode: statusCode,
      );

  /// The already-redacted and truncated provider error body.
  final String body;
}

class ImageGenerationInvalidResponseException extends ImageGenerationException {
  const ImageGenerationInvalidResponseException(super.message);
}

class ImageGenerationResponseTooLarge extends ImageGenerationException {
  ImageGenerationResponseTooLarge(this.limit) : super('图片生成响应超过 $limit 字节');

  final int limit;
}

class ImageGenerationCancelled implements Exception {
  const ImageGenerationCancelled();

  @override
  String toString() => '图片生成请求已取消';
}

class ImageGenerationClient {
  factory ImageGenerationClient({
    required String baseUrl,
    required String apiKey,
    http.Client? client,
    Duration timeout = const Duration(minutes: 2),
    int? maxResponseBytes,
  }) {
    return ImageGenerationClient._(
      _normalizeBaseUrl(baseUrl),
      apiKey,
      client ?? http.Client(),
      timeout,
      maxResponseBytes,
    );
  }

  ImageGenerationClient._(
    this.baseUrl,
    this._apiKey,
    this._client,
    this.timeout,
    this.maxResponseBytes,
  ) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final responseLimit = maxResponseBytes;
    if (responseLimit != null && responseLimit <= 0) {
      throw ArgumentError.value(
        responseLimit,
        'maxResponseBytes',
        'must be positive',
      );
    }
  }

  static const _maxErrorBodyBytes = 64 * 1024;
  static const _maxErrorMessageCharacters = 2_000;

  final String baseUrl;
  final String _apiKey;
  final http.Client _client;
  final Duration timeout;
  final int? maxResponseBytes;

  Future<ImageGenerationResult> generate({
    required String prompt,
    required String model,
    required String size,
    String? responseFormat,
    Future<void>? cancellation,
  }) async {
    final request = http.Request('POST', generationsEndpoint(baseUrl));
    request.headers['Accept'] = 'application/json';
    request.headers['Content-Type'] = 'application/json';
    if (_apiKey.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $_apiKey';
    }
    final requestBody = <String, Object?>{
      'prompt': prompt,
      'model': model,
      'size': size,
    };
    if (responseFormat != null) {
      requestBody['response_format'] = responseFormat;
    }
    request.body = jsonEncode(requestBody);

    final response = await _awaitCancellation(
      _client.send(request).timeout(timeout),
      cancellation,
    );
    final isError = response.statusCode < 200 || response.statusCode >= 300;
    final bodyLimit = isError ? _maxErrorBodyBytes : maxResponseBytes;
    final body = await _awaitCancellation(
      _readLimitedText(response.stream, maxBytes: bodyLimit).timeout(timeout),
      cancellation,
    );

    if (isError) {
      throw ImageGenerationHttpException(
        statusCode: response.statusCode,
        body: _redactAndLimitError(body),
      );
    }
    return _parseResult(body);
  }

  Future<DownloadedImage> download(
    String url, {
    Future<void>? cancellation,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const ImageGenerationInvalidResponseException('图片供应商返回的 URL 无效');
    }
    final response = await _awaitCancellation(
      _client.send(http.Request('GET', uri)).timeout(timeout),
      cancellation,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await _awaitCancellation(
        _readLimitedText(
          response.stream,
          maxBytes: _maxErrorBodyBytes,
        ).timeout(timeout),
        cancellation,
      );
      throw ImageGenerationHttpException(
        statusCode: response.statusCode,
        body: _redactAndLimitError(body),
      );
    }
    final bytes = await _awaitCancellation(
      _readLimitedBytes(
        response.stream,
        maxBytes: maxResponseBytes,
      ).timeout(timeout),
      cancellation,
    );
    final contentType = response.headers['content-type']
        ?.split(';')
        .first
        .trim();
    return DownloadedImage(
      bytes: bytes,
      mimeType: contentType?.startsWith('image/') == true
          ? contentType!
          : 'image/png',
    );
  }

  static Uri generationsEndpoint(String baseUrl) {
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', 'must be a valid URL');
    }
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(
      path: '$path/images/generations',
      query: '',
      fragment: '',
    );
  }

  static String _normalizeBaseUrl(String value) {
    final base = Uri.tryParse(value.trim());
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'must be a valid URL');
    }
    final path = base.path.replaceFirst(RegExp(r'/+$'), '');
    return base.replace(path: path, query: '', fragment: '').toString();
  }

  static ImageGenerationResult _parseResult(String body) {
    final decoded = _decodeJson(body);
    if (decoded is! Map) {
      throw const ImageGenerationInvalidResponseException('图片生成响应格式不正确');
    }
    final data = decoded['data'];
    if (data is! List || data.isEmpty || data.first is! Map) {
      throw const ImageGenerationInvalidResponseException('图片生成响应缺少 data[0]');
    }
    final first = data.first as Map;
    final b64Json = _nonEmptyString(first['b64_json']);
    final url = _nonEmptyString(first['url']);
    if (b64Json == null && url == null) {
      throw const ImageGenerationInvalidResponseException(
        '图片生成响应缺少 b64_json 或 url',
      );
    }
    return ImageGenerationResult(
      b64Json: b64Json,
      url: url,
      revisedPrompt: _nonEmptyString(first['revised_prompt']),
    );
  }

  static Object? _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const ImageGenerationInvalidResponseException('图片生成响应不是有效 JSON');
    }
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  String _redactAndLimitError(String body) {
    var safe = body.trim();
    if (_apiKey.isNotEmpty) {
      safe = safe.replaceAll(_apiKey, '[REDACTED]');
    }
    if (safe.isEmpty) return '';
    if (safe.length <= _maxErrorMessageCharacters) return safe;
    return '${safe.substring(0, _maxErrorMessageCharacters)}...';
  }

  Future<T> _awaitCancellation<T>(
    Future<T> operation,
    Future<void>? cancellation,
  ) {
    if (cancellation == null) return operation;
    final cancelled = cancellation.then<T>((_) {
      close();
      throw const ImageGenerationCancelled();
    });
    return Future.any<T>([operation, cancelled]);
  }

  static Future<String> _readLimitedText(
    Stream<List<int>> stream, {
    required int? maxBytes,
  }) async {
    final result = StringBuffer();
    await for (final chunk in _limitedBytes(
      stream,
      maxBytes: maxBytes,
    ).transform(const Utf8Decoder(allowMalformed: true))) {
      result.write(chunk);
    }
    return result.toString();
  }

  static Future<Uint8List> _readLimitedBytes(
    Stream<List<int>> stream, {
    required int? maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in _limitedBytes(stream, maxBytes: maxBytes)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Stream<List<int>> _limitedBytes(
    Stream<List<int>> stream, {
    required int? maxBytes,
  }) async* {
    var received = 0;
    await for (final chunk in stream) {
      received += chunk.length;
      if (maxBytes != null && received > maxBytes) {
        throw ImageGenerationResponseTooLarge(maxBytes);
      }
      yield chunk;
    }
  }

  void close() => _client.close();
}
