import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidTaskService {
  const AndroidTaskService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mobile_agent/foreground');

  final MethodChannel _channel;

  Future<void> start(
    String taskId, {
    bool overlayEnabled = false,
    double overlayScale = 1.0,
    double overlayLengthScale = 1.0,
    String? title,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('start', {
        'taskId': taskId,
        'overlayEnabled': overlayEnabled,
        'overlayScale': overlayScale,
        'overlayLengthScale': overlayLengthScale,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
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

  Future<void> setOverlayScale(double scale) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setOverlayScale', {'scale': scale});
    } catch (_) {
      // The task can continue with the previous overlay size.
    }
  }

  Future<void> setOverlayLengthScale(double scale) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setOverlayLengthScale', {
        'scale': scale,
      });
    } catch (_) {
      // The task can continue with the previous overlay length.
    }
  }

  Future<void> setOverlayApproval(
    String taskId, {
    String? label,
    bool allowReadOnly = false,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setOverlayApproval', {
        'taskId': taskId,
        if (label != null && label.trim().isNotEmpty) 'label': label.trim(),
        if (label != null && label.trim().isNotEmpty)
          'allowReadOnly': allowReadOnly,
      });
    } catch (_) {
      // The foreground task can continue with the in-app approval dialog.
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

  Future<bool> canPostNotifications() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('canPostNotifications') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
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

  Future<void> finish(String taskId, String status) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('finish', {
        'taskId': taskId,
        'status': status,
      });
    } catch (_) {
      // The optional overlay may already have been removed by Android.
    }
  }
}
