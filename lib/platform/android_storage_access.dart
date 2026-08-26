import 'dart:io';

import 'package:flutter/services.dart';

class AndroidStorageAccess {
  const AndroidStorageAccess._();

  static const _channel = MethodChannel('mobile_agent/storage');

  static bool needsSharedStorageAccess(String path) {
    if (!Platform.isAndroid) return false;
    final normalized = path
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    const appExternalRoot =
        '/storage/emulated/0/Android/data/com.mobileagent.mobile_agent_v1';
    if (normalized == appExternalRoot ||
        normalized.startsWith('$appExternalRoot/')) {
      return false;
    }
    return normalized == '/storage/emulated/0' ||
        normalized.startsWith('/storage/emulated/0/') ||
        normalized == '/sdcard' ||
        normalized.startsWith('/sdcard/');
  }

  static Future<bool> ensureForPath(String path) async {
    if (!needsSharedStorageAccess(path)) return true;
    final hasAccess = await _channel.invokeMethod<bool>(
      'hasExternalStorageAccess',
    );
    if (hasAccess == true) return true;
    final granted = await _channel.invokeMethod<bool>(
      'requestExternalStorageAccess',
    );
    return granted == true;
  }
}
