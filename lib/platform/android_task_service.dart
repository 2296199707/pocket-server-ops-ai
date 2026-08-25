import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidTaskService {
  const AndroidTaskService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mobile_agent/foreground');

  final MethodChannel _channel;

  Future<void> start(String taskId) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start', {'taskId': taskId});
    } on MissingPluginException {
      // Keep local development and tests usable without the Android channel.
    }
  }

  Future<void> stop(String taskId) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop', {'taskId': taskId});
    } on MissingPluginException {
      // Keep local development and tests usable without the Android channel.
    }
  }
}
