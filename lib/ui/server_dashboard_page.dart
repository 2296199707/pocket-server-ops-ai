import 'dart:async';

import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';
import 'file_manager_page.dart';
import 'terminal_page.dart';

class ServerDashboardPage extends StatefulWidget {
  const ServerDashboardPage({
    required this.controller,
    required this.server,
    super.key,
  });

  final AppController controller;
  final ServerProfile server;

  @override
  State<ServerDashboardPage> createState() => _ServerDashboardPageState();
}

class _ServerDashboardPageState extends State<ServerDashboardPage> {
  late ServerProfile _server;
  ServerDashboard? _dashboard;
  bool _loading = false;
  bool _installing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _server = widget.server;
    unawaited(widget.controller.setLastDashboardServer(_server.id));
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant ServerDashboardPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.server.id != oldWidget.server.id) {
      _server = widget.server;
      _dashboard = null;
      unawaited(widget.controller.setLastDashboardServer(_server.id));
      unawaited(_load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _dashboard;
    return Scaffold(
      appBar: AppBar(
        title: const Text('服务器状态'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '切换服务器',
            icon: const Icon(Icons.swap_horiz_rounded),
            onSelected: _switchServer,
            itemBuilder: (context) => [
              for (final server in widget.controller.servers)
                PopupMenuItem(
                  value: server.id,
                  child: Row(
                    children: [
                      Icon(
                        server.id == _server.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: Text(server.name)),
                    ],
                  ),
                ),
            ],
          ),
          IconButton(
            tooltip: '终端',
            onPressed: () => _openTerminal(context),
            icon: const Icon(Icons.terminal_outlined),
          ),
          IconButton(
            tooltip: '文件管理',
            onPressed: () => _openFiles(context),
            icon: const Icon(Icons.folder_outlined),
          ),
          IconButton(
            tooltip: '刷新状态',
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
          children: [
            _ServerHeader(server: _server, dashboard: dashboard),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ErrorNotice(text: _error!),
            ],
            if (_loading && dashboard == null)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (dashboard != null) ...[
              const SizedBox(height: 12),
              _SystemOverviewCard(dashboard: dashboard),
              const SizedBox(height: 12),
              _MemoryCard(dashboard: dashboard),
              const SizedBox(height: 12),
              _StorageCard(dashboard: dashboard),
              const SizedBox(height: 12),
              _NetworkCard(dashboard: dashboard),
              const SizedBox(height: 12),
              _StatusScriptPanel(
                installed: dashboard.statusScriptInstalled,
                installing: _installing,
                onInstall: _install,
              ),
            ] else if (_error == null)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(child: Text('暂无服务器状态')),
              ),
          ],
        ),
      ),
    );
  }

  void _switchServer(String id) {
    if (id == _server.id || _loading) return;
    final selected = widget.controller.servers.firstWhere(
      (server) => server.id == id,
    );
    setState(() {
      _server = selected;
      _dashboard = null;
      _error = null;
    });
    unawaited(widget.controller.setLastDashboardServer(selected.id));
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final dashboard = await widget.controller.loadServerDashboard(
        _server,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) setState(() => _dashboard = dashboard);
    } catch (error) {
      if (mounted) setState(() => _error = '读取服务器状态失败：$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      await widget.controller.installServerStatusScript(
        _server,
        onFirstHostKey: _confirmHostKey,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('状态脚本已安装到用户目录')));
      }
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '安装状态脚本失败：$error');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _openTerminal(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TerminalPage(controller: widget.controller, server: _server),
      ),
    );
  }

  void _openFiles(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileManagerPage(controller: widget.controller, server: _server),
      ),
    );
  }

  Future<bool> _confirmHostKey(SshHostKey key) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认主机指纹'),
            content: SelectableText('${key.type}\n${key.fingerprint}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('信任并保存'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _ServerHeader extends StatelessWidget {
  const _ServerHeader({required this.server, required this.dashboard});

  final ServerProfile server;
  final ServerDashboard? dashboard;

  @override
  Widget build(BuildContext context) {
    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: const Icon(Icons.dns_outlined),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${server.username}@${server.host}:${server.port}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.swap_horiz_rounded),
            ],
          ),
          if (dashboard != null) ...[
            const Divider(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _InfoChip(icon: Icons.computer_outlined, text: dashboard!.os),
                _InfoChip(icon: Icons.code_outlined, text: dashboard!.kernel),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SystemOverviewCard extends StatelessWidget {
  const _SystemOverviewCard({required this.dashboard});

  final ServerDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    return _DashboardCard(
      title: '系统概览',
      icon: Icons.insights_outlined,
      child: Column(
        children: [
          _ValueRow(label: '运行时间', value: dashboard.uptime),
          _ValueRow(label: '系统负载（1 / 5 / 15 分钟）', value: dashboard.load),
          _ValueRow(label: '处理器', value: dashboard.cpu),
          _ValueRow(
            label: '进程数',
            value: dashboard.processCount?.toString() ?? '暂无数据',
          ),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.dashboard});

  final ServerDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final percent = _percentageFrom(dashboard.memory);
    return _DashboardCard(
      title: '内存',
      icon: Icons.memory_outlined,
      trailing: Text(dashboard.memory),
      child: percent == null
          ? const Text('供应商未返回可计算的内存占用比例')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    minHeight: 10,
                    value: percent,
                    color: _usageColor(context, percent),
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 8),
                Text('${(percent * 100).round()}% 已使用'),
              ],
            ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.dashboard});

  final ServerDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final disks = dashboard.disks;
    return _DashboardCard(
      title: '磁盘',
      icon: Icons.storage_outlined,
      child: disks.isEmpty
          ? _ValueRow(label: '系统盘', value: dashboard.disk)
          : Column(
              children: [
                for (var index = 0; index < disks.length; index++) ...[
                  if (index > 0) const Divider(height: 22),
                  _DiskRow(disk: disks[index]),
                ],
              ],
            ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  const _DiskRow({required this.disk});

  final ServerDisk disk;

  @override
  Widget build(BuildContext context) {
    final percent = disk.usedPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.folder_open_outlined, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                disk.mount,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('${disk.used} / ${disk.total}'),
          ],
        ),
        const SizedBox(height: 8),
        if (percent != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: percent / 100,
              color: _usageColor(context, percent / 100),
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest,
            ),
          ),
        const SizedBox(height: 6),
        Text('可用 ${disk.available}${percent == null ? '' : ' · 已用 $percent%'}'),
      ],
    );
  }
}

class _NetworkCard extends StatelessWidget {
  const _NetworkCard({required this.dashboard});

  final ServerDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final network = dashboard.network;
    return _DashboardCard(
      title: '网络',
      icon: Icons.language_outlined,
      trailing: network == null ? null : Text(network.interfaceName),
      child: network == null
          ? const Text('状态探针未返回网络累计流量')
          : Row(
              children: [
                Expanded(
                  child: _NetworkValue(
                    icon: Icons.download_outlined,
                    label: '接收',
                    value: _formatBytes(network.receivedBytes),
                  ),
                ),
                Expanded(
                  child: _NetworkValue(
                    icon: Icons.upload_outlined,
                    label: '发送',
                    value: _formatBytes(network.transmittedBytes),
                  ),
                ),
              ],
            ),
    );
  }
}

class _NetworkValue extends StatelessWidget {
  const _NetworkValue({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 7),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ],
    );
  }
}

class _StatusScriptPanel extends StatelessWidget {
  const _StatusScriptPanel({
    required this.installed,
    required this.installing,
    required this.onInstall,
  });

  final bool installed;
  final bool installing;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return _DashboardCard(
      title: '状态采集',
      icon: installed ? Icons.check_circle_outline : Icons.info_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(installed ? '轻量状态脚本已安装' : '当前使用一次性基础命令读取状态'),
          const SizedBox(height: 5),
          Text(
            '脚本位于 ~/.local/bin/mobile-agent-status，不运行后台服务。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: installing ? null : onInstall,
            icon: installing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
            label: Text(installed ? '更新状态脚本' : '一键安装状态脚本'),
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.child,
    this.title,
    this.icon,
    this.trailing,
  });

  final Widget child;
  final String? title;
  final IconData? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 21, color: colors.primary),
                  const SizedBox(width: 8),
                ],
                Text(title!, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                ?trailing,
              ],
            ),
            const Divider(height: 22),
          ],
          child,
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 17),
      label: Text(text),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text),
    );
  }
}

double? _percentageFrom(String value) {
  final match = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(value);
  final number = double.tryParse(match?.group(1) ?? '');
  if (number == null) return null;
  return (number / 100).clamp(0, 1).toDouble();
}

Color _usageColor(BuildContext context, double value) {
  if (value >= 0.9) return Theme.of(context).colorScheme.error;
  if (value >= 0.75) return Colors.orange;
  return Colors.green;
}

String _formatBytes(int value) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var number = value.toDouble();
  var unit = 0;
  while (number >= 1024 && unit < units.length - 1) {
    number /= 1024;
    unit++;
  }
  final digits = number >= 10 || unit == 0 ? 0 : 1;
  return '${number.toStringAsFixed(digits)} ${units[unit]}';
}
