import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidTaskService {
  const AndroidTaskService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mobile_agent/foreground');

  final MethodChannel _channel;

  Future<void> start(String taskId, {bool overlayEnabled = false}) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start', {
        'taskId': taskId,
        'overlayEnabled': overlayEnabled,
      });
    } catch (_) {
      // The foreground service is optional and must not fail the AI task.
    }
  }

  Future<void> updateProgress(String taskId, String label) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateProgress', {
        'taskId': taskId,
        'label': label,
      });
    } catch (_) {
      // Progress is best effort and must not interrupt a running task.
    }
  }

  Future<void> setOverlayEnabled(bool enabled) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setOverlayEnabled', {
        'enabled': enabled,
      });
    } catch (_) {
      // The task can continue without the optional overlay.
    }
  }

  Future<bool> canDrawOverlays() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('canDrawOverlays') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestOverlayPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop(String taskId) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop', {'taskId': taskId});
    } catch (_) {
      // The foreground service may already have been stopped by Android.
    }
  }
}
