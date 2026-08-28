import 'dart:io';

import 'package:flutter/services.dart';

class AndroidFileOpener {
  const AndroidFileOpener._();

  static const _channel = MethodChannel('mobile_agent/file');

  static Future<void> open(String path) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('当前平台不支持调用系统文件打开器');
    }
    await _channel.invokeMethod<void>('openFile', {'path': path});
  }
}
