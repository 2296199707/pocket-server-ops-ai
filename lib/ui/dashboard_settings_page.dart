import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';

class DashboardSettingsPage extends StatelessWidget {
  const DashboardSettingsPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('仪表盘设置')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
          children: [
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              secondary: const Icon(Icons.data_usage_outlined),
              title: const Text('流量监控'),
              subtitle: const Text('显示 HY2、SSH 端口流量及合计，默认关闭'),
              value: controller.dashboardTrafficEnabled,
              onChanged: (value) {
                unawaited(controller.setDashboardTrafficEnabled(value));
              },
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 16, 4, 0),
              child: Text(
                '开启后，在需要监控的服务器仪表盘中点击“配置端口”安装统计。'
                '关闭后隐藏流量区域并停止 App 采集，服务器已有统计及累计值会保留。',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
