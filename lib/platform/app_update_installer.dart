import 'dart:io';

import 'package:flutter/services.dart';

class AppUpdateInstaller {
  const AppUpdateInstaller({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('mobile_agent/update');

  final MethodChannel _channel;

  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> requestInstallPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestInstallPermission') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> install(File apk) async {
    if (!Platform.isAndroid) {
      throw StateError('当前平台不支持直接安装 APK');
    }
    try {
      await _channel.invokeMethod<void>('installApk', {'path': apk.path});
    } on PlatformException catch (error) {
      if (error.code == 'install_permission_required') {
        throw StateError('请允许本应用安装未知应用，然后再次点击安装');
      }
      throw StateError(error.message ?? '无法启动系统安装器');
    }
  }
}
