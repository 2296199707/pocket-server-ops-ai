import 'package:flutter/services.dart';

/// Calls the Android loopback WebView renderer and returns one viewport PNG.
class AndroidPreviewCapture {
  AndroidPreviewCapture({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'mobile_agent/preview_capture';

  final MethodChannel _channel;

  Future<Uint8List> capture({
    required String url,
    int width = 1024,
    int height = 768,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('capture', {
      'url': url,
      'width': width,
      'height': height,
    });
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Android preview capture returned no PNG bytes');
    }
    return bytes;
  }
}
