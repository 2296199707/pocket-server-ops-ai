import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent_tools.dart';
import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';
import 'chat_page.dart';
import 'file_manager_page.dart';
import 'profile_sheets.dart';
import 'providers_page.dart';
import 'server_dashboard_page.dart';
import 'terminal_page.dart';
import 'updates_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({required this.controller, super.key});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;
  String? _activeTaskId;
  int _chatRevision = 0;
  Future<void> _agentConfirmationQueue = Future<void>.value();

  Task? get _activeTask {
    final id = _activeTaskId;
    if (id == null) return null;
    for (final task in widget.controller.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(
            _selectedIndex == 0
                ? (_activeTask?.title ?? '新对话')
                : _selectedIndex == 1
                ? '服务器'
                : '设置',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            if (_selectedIndex == 0)
              IconButton(
                tooltip: '新对话',
                onPressed: _startNewChat,
                icon: const Icon(Icons.add_comment_outlined),
              ),
          ],
        ),
        drawer: _buildDrawer(context),
        body: widget.controller.loadError == null
            ? _buildPage()
            : _LoadError(
                message: widget.controller.loadError!,
                onRetry: widget.controller.load,
              ),
      ),
    );
  }

  Widget _buildPage() {
    switch (_selectedIndex) {
      case 1:
        return ServersPage(controller: widget.controller);
      case 2:
        return SettingsPage(controller: widget.controller);
      default:
        return ChatPage(
          key: ValueKey('$_chatRevision-${widget.controller.agentAutoExecute}'),
          controller: widget.controller,
          taskId: _activeTaskId,
          onTaskActivated: (taskId) => setState(() => _activeTaskId = taskId),
          onOpenSettings: _openProviderSettings,
          onConfirmTool: _confirmAgentTool,
          onConfirmHostKey: _confirmAgentHostKey,
          onUserInfoRequest: _requestAgentUserInfo,
        );
    }
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('PocketServerOps AI'),
              subtitle: Text(
                _runningAgentCount == 0
                    ? '手机直接连接目标服务器'
                    : '$_runningAgentCount 个 Agent 正在运行',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_comment_outlined),
              title: const Text('新对话'),
              selected: _selectedIndex == 0 && _activeTaskId == null,
              onTap: () {
                Navigator.pop(context);
                _startNewChat();
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: _DrawerActionButton(
                      icon: Icons.add_circle_outline,
                      label: '服务器添加',
                      onPressed: _openServerManagerFromDrawer,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DrawerActionButton(
                      icon: Icons.dashboard_outlined,
                      label: '服务器仪表盘',
                      onPressed: _openDashboardFromDrawer,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _DrawerActionButton(
                      icon: Icons.smart_toy_outlined,
                      label: '供应商设置',
                      onPressed: _openProviderSettingsFromDrawer,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('对话记录'),
              ),
            ),
            Expanded(
              child: widget.controller.tasks.isEmpty
                  ? const Center(child: Text('暂无对话'))
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: widget.controller.tasks.length,
                      itemBuilder: (context, index) {
                        final task = widget.controller.tasks[index];
                        return ListTile(
                          leading: Icon(_statusIcon(task.status)),
                          title: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _taskLabel(task),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected:
                              _selectedIndex == 0 && _activeTaskId == task.id,
                          onTap: () {
                            Navigator.pop(context);
                            setState(() {
                              _selectedIndex = 0;
                              _activeTaskId = task.id;
                            });
                          },
                          trailing: PopupMenuButton<String>(
                            tooltip: '对话操作',
                            onSelected: (value) {
                              if (value == 'rename') {
                                _renameTask(context, task);
                              } else if (value == 'copy_id') {
                                Clipboard.setData(ClipboardData(text: task.id));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('对话 ID 已复制')),
                                );
                              } else {
                                _deleteTask(context, task);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(
                                value: 'copy_id',
                                child: Text('复制对话 ID'),
                              ),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.tune_outlined),
              title: const Text('设置'),
              selected: _selectedIndex == 2,
              onTap: () {
                Navigator.pop(context);
                setState(() => _selectedIndex = 2);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openServerManagerFromDrawer() {
    Navigator.pop(context);
    setState(() => _selectedIndex = 1);
  }

  void _openProviderSettingsFromDrawer() {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openProviderSettings();
    });
  }

  void _openProviderSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProvidersPage(controller: widget.controller),
      ),
    );
  }

  void _openDashboardFromDrawer() {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_chooseDashboardServer());
    });
  }

  Future<void> _chooseDashboardServer() async {
    final servers = widget.controller.servers;
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在“服务器添加”中添加服务器')));
      return;
    }
    final server = servers.length == 1
        ? servers.single
        : await showModalBottomSheet<ServerProfile>(
            context: context,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text('选择服务器'),
                    subtitle: Text('打开服务器仪表盘'),
                  ),
                  for (final server in servers)
                    ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(server.name),
                      subtitle: Text(
                        '${server.username}@${server.host}:${server.port}',
                      ),
                      onTap: () => Navigator.pop(context, server),
                    ),
                ],
              ),
            ),
          );
    if (server != null && mounted) _openDashboard(context, server);
  }

  void _openDashboard(BuildContext context, ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ServerDashboardPage(controller: widget.controller, server: server),
      ),
    );
  }

  String _taskLabel(Task task) {
    if (task.mode == 'chat') return '普通对话';
    for (final server in widget.controller.servers) {
      if (server.id == task.serverId) return 'Agent · ${server.name}';
    }
    return '手机 Agent';
  }

  int get _runningAgentCount => widget.controller.tasks
      .where(
        (task) =>
            task.mode == 'agent' && widget.controller.isTaskRunning(task.id),
      )
      .length;

  Future<bool> _confirmAgentTool(
    Task task,
    AgentTool tool,
    Map<String, Object?> arguments,
  ) {
    return _queueAgentConfirmation(() async {
      if (!mounted || !widget.controller.isTaskRunning(task.id)) return false;
      final value = jsonEncode(arguments);
      final preview = value.length <= _maxToolPreviewCharacters
          ? value
          : '${value.substring(0, _maxToolPreviewCharacters ~/ 2)}\n'
                '…中间参数过长，已省略；以下为结尾…\n'
                '${value.substring(value.length - _maxToolPreviewCharacters ~/ 2)}';
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('${task.title} 请求执行 ${tool.definition.name}'),
              content: SingleChildScrollView(child: SelectableText(preview)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('执行'),
                ),
              ],
            ),
          ) ??
          false;
    });
  }

  Future<bool> _confirmAgentHostKey(Task task, SshHostKey key) {
    return _queueAgentConfirmation(() async {
      if (!mounted || !widget.controller.isTaskRunning(task.id)) return false;
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('${task.title}：确认主机指纹'),
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
    });
  }

  Future<List<String>?> _requestAgentUserInfo(
    Task task,
    SshUserInfoRequest request,
  ) {
    return _queueAgentInteraction<List<String>?>(() async {
      if (!mounted || !widget.controller.isTaskRunning(task.id)) return null;
      if (request.prompts.isEmpty) return const <String>[];
      final controllers = [
        for (final _ in request.prompts) TextEditingController(),
      ];
      try {
        return await showDialog<List<String>>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: Text(
              '${task.title}：${request.name.isEmpty ? 'SSH 需要输入' : request.name}',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (request.instruction.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(request.instruction),
                    ),
                  for (
                    var index = 0;
                    index < request.prompts.length;
                    index++
                  ) ...[
                    if (index > 0) const SizedBox(height: 12),
                    TextField(
                      controller: controllers[index],
                      autofocus: index == 0,
                      obscureText: !request.prompts[index].echo,
                      decoration: InputDecoration(
                        labelText: request.prompts[index].text.trim().isEmpty
                            ? '输入'
                            : request.prompts[index].text.trim(),
                      ),
                      onSubmitted: (_) {
                        if (index == request.prompts.length - 1) {
                          Navigator.pop(context, [
                            for (final controller in controllers)
                              controller.text,
                          ]);
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消连接'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, [
                  for (final controller in controllers) controller.text,
                ]),
                child: const Text('提交'),
              ),
            ],
          ),
        );
      } finally {
        for (final controller in controllers) {
          controller.dispose();
        }
      }
    }, null);
  }

  Future<bool> _queueAgentConfirmation(Future<bool> Function() confirmation) {
    return _queueAgentInteraction<bool>(confirmation, false);
  }

  Future<T> _queueAgentInteraction<T>(
    Future<T> Function() interaction,
    T fallback,
  ) {
    final result = _agentConfirmationQueue.then<T>(
      (_) => mounted ? interaction() : fallback,
    );
    _agentConfirmationQueue = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  void _startNewChat() {
    setState(() {
      _selectedIndex = 0;
      _activeTaskId = null;
      _chatRevision++;
    });
  }

  Future<void> _renameTask(BuildContext context, Task task) async {
    final editor = TextEditingController(text: task.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: editor,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editor.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    editor.dispose();
    if (title == null || !context.mounted) return;
    try {
      await widget.controller.renameTask(task, title);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重命名失败：$error')));
      }
    }
  }

  Future<void> _deleteTask(BuildContext context, Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话？'),
        content: Text(task.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deleteTask(task);
      if (mounted && _activeTaskId == task.id) _startNewChat();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }
}

class _DrawerActionButton extends StatelessWidget {
  const _DrawerActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

const _maxToolPreviewCharacters = 12_000;

class ServersPage extends StatelessWidget {
  const ServersPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: controller.isLoading
          ? const Center(child: CircularProgressIndicator())
          : controller.servers.isEmpty
          ? const _EmptyState(icon: Icons.dns_outlined, label: '还没有目标服务器')
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              itemCount: controller.servers.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final server = controller.servers[index];
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.dns_outlined)),
                  title: Text(server.name),
                  subtitle: Text(
                    '${server.username}@${server.host}:${server.port}',
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: '服务器操作',
                    onSelected: (value) {
                      switch (value) {
                        case 'test':
                          _testServer(context, server);
                        case 'dashboard':
                          _openDashboard(context, server);
                        case 'files':
                          _openFiles(context, server);
                        case 'terminal':
                          _openTerminal(context, server);
                        case 'edit':
                          showServerEditor(context, controller, server);
                        case 'delete':
                          _deleteServer(context, server);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'test', child: Text('测试连接')),
                      PopupMenuItem(value: 'dashboard', child: Text('服务器仪表盘')),
                      PopupMenuItem(value: 'files', child: Text('文件管理')),
                      PopupMenuItem(value: 'terminal', child: Text('打开终端')),
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showServerEditor(context, controller),
        tooltip: '添加服务器',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _testServer(BuildContext context, ServerProfile server) async {
    try {
      final key = await controller.testServer(
        server,
        onFirstHostKey: (value) => _confirmHostKey(context, value),
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('连接成功：${key.fingerprint}')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('连接失败：$error')));
      }
    }
  }

  void _openTerminal(BuildContext context, ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TerminalPage(controller: controller, server: server),
      ),
    );
  }

  void _openDashboard(BuildContext context, ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ServerDashboardPage(controller: controller, server: server),
      ),
    );
  }

  void _openFiles(BuildContext context, ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileManagerPage(controller: controller, server: server),
      ),
    );
  }

  Future<void> _deleteServer(BuildContext context, ServerProfile server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除服务器？'),
        content: Text(server.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.deleteServer(server);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: controller.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              itemCount: 3,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: const Text('Agent 自动执行工具'),
                    subtitle: const Text('新建手机 Agent 默认自动执行；关闭后需要确认的工具逐次确认。'),
                    value: controller.agentAutoExecute,
                    onChanged: (value) {
                      unawaited(controller.setAgentAutoExecute(value));
                    },
                  );
                }
                if (index == 1) {
                  return _VersionSettingsTile(controller: controller);
                }
                return _DeveloperSettingsTile(controller: controller);
              },
            ),
    );
  }
}

class _VersionSettingsTile extends StatelessWidget {
  const _VersionSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(child: Icon(Icons.system_update_outlined)),
      title: const Text('版本与更新'),
      subtitle: const Text('检查新版本、查看历史版本和回退下载'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                UpdatesPage(includePrereleases: controller.betaUpdatesEnabled),
          ),
        );
      },
    );
  }
}

class _DeveloperSettingsTile extends StatelessWidget {
  const _DeveloperSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(child: Icon(Icons.bug_report_outlined)),
      title: const Text('开发者调试'),
      subtitle: Text(controller.betaUpdatesEnabled ? '测试版更新已开启' : '仅显示正式版更新'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DeveloperSettingsPage(controller: controller),
          ),
        );
      },
    );
  }
}

class DeveloperSettingsPage extends StatelessWidget {
  const DeveloperSettingsPage({required this.controller, super.key});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('开发者调试')),
        body: ListView(
          children: [
            SwitchListTile(
              title: const Text('接收测试版更新'),
              subtitle: const Text('在版本与更新中显示 GitHub 的 Beta/预发布版本。'),
              value: controller.betaUpdatesEnabled,
              onChanged: (value) {
                unawaited(controller.setBetaUpdatesEnabled(value));
              },
            ),
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('测试版只用于验证新功能，可能存在问题。关闭后不会影响已安装版本，也不会删除任何数据。'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool> _confirmHostKey(BuildContext context, SshHostKey key) async {
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

IconData _statusIcon(String status) {
  switch (status) {
    case 'running':
      return Icons.sync;
    case 'completed':
      return Icons.check_circle_outline;
    case 'failed':
      return Icons.error_outline;
    case 'cancelled':
      return Icons.stop_circle_outlined;
    case 'unknown':
      return Icons.help_outline;
    default:
      return Icons.chat_bubble_outline;
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(label),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 42),
            const SizedBox(height: 12),
            const Text('读取本地数据失败'),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
