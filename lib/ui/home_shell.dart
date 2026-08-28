import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
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
  static const _compactDrawerDensity = VisualDensity(
    horizontal: -1,
    vertical: -2,
  );
  static const _drawerTitleStyle = TextStyle(fontSize: 13, height: 1.15);
  static const _drawerSubtitleStyle = TextStyle(fontSize: 11, height: 1.1);

  final _chatKey = GlobalKey<ChatPageState>();
  int _selectedIndex = 0;
  String? _activeTaskId;
  String? _pendingProjectId;
  String _draftWorkMode = 'chat';
  bool _didRestoreLastConversation = false;
  final Map<String, Future<void>> _agentConfirmationQueues = {};

  Task? get _activeTask {
    final id = _activeTaskId;
    if (id == null) return null;
    for (final task in widget.controller.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_restoreLastConversation);
    if (!widget.controller.isLoading) _restoreLastConversation();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_restoreLastConversation);
    super.dispose();
  }

  void _restoreLastConversation() {
    if (_didRestoreLastConversation ||
        widget.controller.isLoading ||
        widget.controller.loadError != null) {
      return;
    }
    _didRestoreLastConversation = true;
    final savedId = widget.controller.lastConversationTaskId;
    Task? task;
    if (savedId != null) {
      for (final candidate in widget.controller.tasks) {
        if (candidate.id == savedId) {
          task = candidate;
          break;
        }
      }
    }
    task ??= widget.controller.tasks.isEmpty
        ? null
        : widget.controller.tasks.first;
    if (task == null) return;
    final restoredTask = task;
    if (savedId != restoredTask.id) {
      unawaited(widget.controller.setLastConversationTask(restoredTask.id));
    }
    if (!mounted) return;
    setState(() {
      _activeTaskId = restoredTask.id;
      _pendingProjectId = restoredTask.projectId;
      _selectedIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final workMode = _activeTask?.effectiveWorkMode ?? _draftWorkMode;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _selectedIndex == 0
                  ? (_activeTask?.title ??
                        (_pendingProjectId == null ? '其他对话' : '新对话'))
                  : _selectedIndex == 1
                  ? '服务器'
                  : '设置',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (_selectedIndex == 0)
                IconButton(
                  tooltip: widget.controller.floatingCapsuleEnabled
                      ? '关闭悬浮窗'
                      : '开启悬浮窗',
                  onPressed: _toggleFloatingCapsule,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    widget.controller.floatingCapsuleEnabled
                        ? Icons.picture_in_picture_alt
                        : Icons.picture_in_picture_alt_outlined,
                    size: 18,
                  ),
                ),
              if (_selectedIndex == 0)
                IconButton(
                  tooltip: 'HTML预览',
                  onPressed: _hasPreviewProject
                      ? _openLocalPreviewFromAppBar
                      : null,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.preview_outlined, size: 18),
                ),
              if (_selectedIndex == 0)
                Tooltip(
                  message: '切换工作模式',
                  child: TextButton.icon(
                    onPressed: _openWorkModeFromAppBar,
                    icon: const Icon(Icons.sync_alt_rounded, size: 17),
                    label: Text(
                      workModeLabel(workMode),
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              if (_selectedIndex == 0)
                IconButton(
                  tooltip: _activeTask?.projectId == null
                      ? '在其他对话中新建'
                      : '在当前项目中新建对话',
                  onPressed: _startNewChatFromCurrent,
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
        );
      },
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
          key: _chatKey,
          controller: widget.controller,
          agentAutoExecute: widget.controller.agentAutoExecute,
          taskId: _activeTaskId,
          initialProjectId: _pendingProjectId,
          onTaskActivated: (taskId) {
            setState(() {
              _activeTaskId = taskId;
              _draftWorkMode = 'chat';
            });
            unawaited(widget.controller.setLastConversationTask(taskId));
          },
          onWorkModeChanged: (mode) {
            if (_activeTaskId == null && _draftWorkMode != mode) {
              setState(() => _draftWorkMode = mode);
            }
          },
          onOpenSettings: _openProviderSettings,
          onConfirmTool: _confirmAgentTool,
          onConfirmHostKey: _confirmAgentHostKey,
          onUserInfoRequest: _requestAgentUserInfo,
        );
    }
  }

  Widget _buildDrawer(BuildContext context) {
    final otherTasks = widget.controller.tasks
        .where((task) => task.projectId == null)
        .toList(growable: false);
    final drawerWidth = MediaQuery.sizeOf(context).width >= 600 ? 360.0 : null;
    return Drawer(
      width: drawerWidth,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: _DrawerActionButton(
                      icon: Icons.add_circle_outline,
                      label: '服务器添加',
                      onPressed: _openServerManagerFromDrawer,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _DrawerActionButton(
                      icon: Icons.dashboard_outlined,
                      label: '服务器仪表盘',
                      onPressed: _openDashboardFromDrawer,
                    ),
                  ),
                  const SizedBox(width: 4),
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
            ListTile(
              dense: true,
              visualDensity: _compactDrawerDensity,
              minTileHeight: 36,
              minVerticalPadding: 0,
              minLeadingWidth: 20,
              horizontalTitleGap: 6,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: const Icon(Icons.add_comment_outlined, size: 18),
              title: const Text('新对话', style: _drawerTitleStyle),
              selected: _selectedIndex == 0 && _activeTaskId == null,
              onTap: _openNewConversationPicker,
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ExpansionTile(
                    key: const PageStorageKey<String>('other-conversations'),
                    initiallyExpanded: widget.controller.sidebarSectionExpanded(
                      'other',
                    ),
                    dense: true,
                    visualDensity: _compactDrawerDensity,
                    minTileHeight: 36,
                    tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                    childrenPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.chat_bubble_outline, size: 18),
                    title: const Text('其他对话', style: _drawerTitleStyle),
                    onExpansionChanged: (expanded) => unawaited(
                      widget.controller.setSidebarSectionExpanded(
                        'other',
                        expanded,
                      ),
                    ),
                    children: [
                      if (otherTasks.isEmpty)
                        const ListTile(
                          dense: true,
                          visualDensity: _compactDrawerDensity,
                          minTileHeight: 32,
                          minVerticalPadding: 0,
                          contentPadding: EdgeInsets.only(left: 40),
                          title: Text('暂无对话', style: _drawerSubtitleStyle),
                        )
                      else
                        for (final task in otherTasks) _taskTile(context, task),
                    ],
                  ),
                  _drawerSectionTitle('项目'),
                  if (widget.controller.projects.isEmpty)
                    const ListTile(
                      dense: true,
                      visualDensity: _compactDrawerDensity,
                      minTileHeight: 32,
                      minVerticalPadding: 0,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      leading: Icon(Icons.folder_off_outlined, size: 18),
                      title: Text('暂无项目', style: _drawerSubtitleStyle),
                    )
                  else
                    for (final project in widget.controller.projects)
                      ExpansionTile(
                        key: PageStorageKey<String>('project-${project.id}'),
                        initiallyExpanded: widget.controller
                            .sidebarSectionExpanded('project:${project.id}'),
                        dense: true,
                        visualDensity: _compactDrawerDensity,
                        minTileHeight: 44,
                        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                        childrenPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined, size: 18),
                        title: Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _drawerTitleStyle,
                        ),
                        onExpansionChanged: (expanded) => unawaited(
                          widget.controller.setSidebarSectionExpanded(
                            'project:${project.id}',
                            expanded,
                          ),
                        ),
                        subtitle: Text(
                          project.localPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _drawerSubtitleStyle,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _DrawerItemIconButton(
                              tooltip: '在项目中新建对话',
                              onPressed: () =>
                                  _startNewChatInDrawer(project.id),
                              icon: Icons.add,
                            ),
                            _DrawerItemIconButton(
                              tooltip: '项目设置',
                              onPressed: () =>
                                  _openProjectSettingsFromDrawer(project),
                              icon: Icons.settings_outlined,
                            ),
                            _DrawerItemIconButton(
                              tooltip: '删除项目',
                              onPressed: () => _deleteProject(context, project),
                              icon: Icons.delete_outline,
                            ),
                            const Icon(Icons.expand_more, size: 18),
                          ],
                        ),
                        children: [
                          for (final task in widget.controller.tasks.where(
                            (task) => task.projectId == project.id,
                          ))
                            _taskTile(context, task, indent: 16),
                          if (!widget.controller.tasks.any(
                            (task) => task.projectId == project.id,
                          ))
                            const ListTile(
                              dense: true,
                              visualDensity: _compactDrawerDensity,
                              minTileHeight: 32,
                              minVerticalPadding: 0,
                              contentPadding: EdgeInsets.only(left: 40),
                              title: Text(
                                '暂无项目对话',
                                style: _drawerSubtitleStyle,
                              ),
                            ),
                        ],
                      ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              visualDensity: _compactDrawerDensity,
              minTileHeight: 36,
              minVerticalPadding: 0,
              minLeadingWidth: 20,
              horizontalTitleGap: 6,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: const Icon(Icons.tune_outlined, size: 18),
              title: const Text('设置', style: _drawerTitleStyle),
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

  Widget _drawerSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _taskTile(BuildContext context, Task task, {double indent = 0}) {
    return ListTile(
      dense: true,
      visualDensity: _compactDrawerDensity,
      minTileHeight: 38,
      minVerticalPadding: 2,
      minLeadingWidth: 18,
      horizontalTitleGap: 4,
      contentPadding: EdgeInsets.only(left: 12 + indent, right: 4),
      leading: Icon(
        _statusIcon(
          task.status,
          isRunning: widget.controller.isTaskRunning(task.id),
        ),
        size: 15,
        color: _statusColor(
          task.status,
          widget.controller.isTaskRunning(task.id),
        ),
      ),
      title: Text(
        task.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _drawerTitleStyle,
      ),
      subtitle: Text(
        _taskLabel(task),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _drawerSubtitleStyle,
      ),
      selected: _selectedIndex == 0 && _activeTaskId == task.id,
      onTap: () {
        Navigator.pop(context);
        setState(() {
          _selectedIndex = 0;
          _activeTaskId = task.id;
          _pendingProjectId = task.projectId;
          _draftWorkMode = 'chat';
        });
        unawaited(widget.controller.setLastConversationTask(task.id));
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DrawerItemIconButton(
            tooltip: '删除对话',
            onPressed: () => _deleteTask(context, task),
            icon: Icons.delete_outline,
          ),
          PopupMenuButton<String>(
            tooltip: '对话操作',
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            padding: EdgeInsets.zero,
            iconSize: 15,
            position: PopupMenuPosition.under,
            onSelected: (value) {
              if (value == 'rename') {
                _renameTask(context, task);
              } else {
                Clipboard.setData(ClipboardData(text: task.id));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('对话 ID 已复制')));
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('重命名')),
              PopupMenuItem(value: 'copy_id', child: Text('复制对话 ID')),
            ],
          ),
        ],
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

  void _openWorkModeFromAppBar() {
    final chat = _chatKey.currentState;
    if (chat != null) unawaited(chat.openWorkModePicker());
  }

  Future<void> _toggleFloatingCapsule() async {
    final enabled = !widget.controller.floatingCapsuleEnabled;
    final changed = await widget.controller.setFloatingCapsuleEnabled(enabled);
    if (!changed && enabled && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请允许悬浮窗权限后再开启')));
    }
  }

  bool get _hasPreviewProject =>
      widget.controller.projectFor(
        _activeTask?.projectId ?? _pendingProjectId,
      ) !=
      null;

  void _openLocalPreviewFromAppBar() {
    final chat = _chatKey.currentState;
    if (chat != null) unawaited(chat.openLocalPreview());
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
    final lastServerId = widget.controller.lastDashboardServerId;
    if (lastServerId != null) {
      for (final server in servers) {
        if (server.id == lastServerId) {
          _openDashboard(context, server);
          return;
        }
      }
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
    final workMode = task.effectiveWorkMode;
    if (workModeUsesServer(workMode)) {
      for (final server in widget.controller.servers) {
        if (server.id == task.serverId) {
          return '${workModeLabel(workMode)} · ${server.name}';
        }
      }
    }
    return workModeLabel(workMode);
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
    return _queueAgentConfirmation(task.id, () async {
      if (!mounted || !widget.controller.isTaskRunning(task.id)) return false;
      if (tool.definition.name == 'local.request_access') {
        return _requestLocalAccess(task, arguments);
      }
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

  Future<bool> _requestLocalAccess(
    Task task,
    Map<String, Object?> arguments,
  ) async {
    final requestedPath = arguments['path'];
    if (requestedPath is! String || requestedPath.trim().isEmpty) return false;
    final path = requestedPath.trim();
    final requestedWrite = arguments['write'] == true;
    if (await widget.controller.hasLocalAccess(
      task.id,
      path,
      write: requestedWrite,
    )) {
      return true;
    }
    if (!mounted) return false;
    final reason = arguments['reason'] is String
        ? (arguments['reason'] as String).trim()
        : '';
    final access = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('允许 Agent 访问手机文件？'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('请求路径：'),
              SelectableText(path),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('请求原因：'),
                Text(reason),
              ],
              const SizedBox(height: 12),
              Text(
                requestedWrite
                    ? '读写授权只对当前对话有效，任务结束后不会保存为永久权限。'
                    : '读取授权只对当前对话有效，任务结束后不会保存为永久权限。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'deny'),
            child: const Text('拒绝'),
          ),
          if (requestedWrite)
            OutlinedButton(
              onPressed: () => Navigator.pop(context, 'read'),
              child: const Text('仅允许读取'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'write'),
            child: Text(requestedWrite ? '允许读写' : '允许读取'),
          ),
        ],
      ),
    );
    if (access == null || access == 'deny' || !mounted) return false;
    try {
      await widget.controller.grantLocalAccess(
        task.id,
        path,
        canWrite: access == 'write',
      );
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法授权该路径：$error')));
      }
      return false;
    }
  }

  Future<bool> _confirmAgentHostKey(Task task, SshHostKey key) {
    return _queueAgentConfirmation(task.id, () async {
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
    return _queueAgentInteraction<List<String>?>(task.id, () async {
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

  Future<bool> _queueAgentConfirmation(
    String taskId,
    Future<bool> Function() confirmation,
  ) {
    return _queueAgentInteraction<bool>(taskId, confirmation, false);
  }

  Future<T> _queueAgentInteraction<T>(
    String taskId,
    Future<T> Function() interaction,
    T fallback,
  ) {
    final previous = _agentConfirmationQueues[taskId] ?? Future<void>.value();
    final result = previous.then<T>((_) => mounted ? interaction() : fallback);
    final settled = result.then<void>((_) {}, onError: (_, _) {});
    _agentConfirmationQueues[taskId] = settled;
    unawaited(
      settled.then<void>((_) {
        if (identical(_agentConfirmationQueues[taskId], settled)) {
          _agentConfirmationQueues.remove(taskId);
        }
      }),
    );
    return result;
  }

  void _openNewConversationPicker() {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_chooseNewConversationTarget());
    });
  }

  Future<void> _chooseNewConversationTarget() async {
    const other = '__other__';
    const create = '__create__';
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('新建对话'),
              subtitle: Text('选择对话归属；服务器和供应商仍在对话中单独设置'),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('其他对话'),
              subtitle: const Text('不绑定项目文件夹'),
              onTap: () => Navigator.pop(context, other),
            ),
            for (final project in widget.controller.projects)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(project.name),
                subtitle: Text(
                  project.localPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(context, project.id),
              ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('创建新项目并绑定'),
              onTap: () => Navigator.pop(context, create),
            ),
          ],
        ),
      ),
    );
    if (!mounted || target == null) return;
    if (target == create) {
      final project = await _showProjectEditor();
      if (project != null && mounted) _startNewChat(projectId: project.id);
      return;
    }
    _startNewChat(projectId: target == other ? null : target);
  }

  void _startNewChatFromCurrent() {
    _startNewChat(projectId: _activeTask?.projectId ?? _pendingProjectId);
  }

  void _startNewChatInDrawer(String projectId) {
    Navigator.pop(context);
    _startNewChat(projectId: projectId);
  }

  Future<void> _openProjectSettingsFromDrawer(Project project) async {
    Navigator.pop(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_showProjectEditor(existing: project));
    });
  }

  Future<Project?> _showProjectEditor({Project? existing}) async {
    final nameController = TextEditingController(text: existing?.name ?? '');
    String? selectedPath = existing?.localPath;
    final value = await showDialog<_ProjectFormValue>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '创建项目' : '项目设置'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: existing == null,
                  decoration: const InputDecoration(labelText: '项目名称'),
                ),
                const SizedBox(height: 12),
                Text(
                  selectedPath == null ? '未选择文件夹，将使用 App 的项目目录' : selectedPath!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: '选择项目文件夹',
                    );
                    if (path != null && context.mounted) {
                      setDialogState(() => selectedPath = path);
                    }
                  },
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('选择项目文件夹'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _ProjectFormValue(
                  name: nameController.text,
                  localPath: selectedPath,
                ),
              ),
              child: Text(existing == null ? '创建并绑定' : '保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    if (value == null || !mounted) return null;
    try {
      final project = existing == null
          ? await widget.controller.createProject(
              name: value.name,
              localPath: value.localPath,
            )
          : await widget.controller.updateProject(
              project: existing,
              name: value.name,
              localPath: value.localPath ?? existing.localPath,
            );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(existing == null ? '项目已创建' : '项目设置已保存')),
        );
      }
      return project;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存项目失败：$error')));
      }
      return null;
    }
  }

  void _startNewChat({String? projectId}) {
    setState(() {
      _selectedIndex = 0;
      _activeTaskId = null;
      _pendingProjectId = projectId;
      _draftWorkMode = 'chat';
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

  Future<void> _deleteProject(BuildContext context, Project project) async {
    final taskCount = widget.controller.tasks
        .where((task) => task.projectId == project.id)
        .length;
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('删除项目？'),
          content: taskCount != 0
              ? Text('项目下还有 $taskCount 个对话，请先删除这些对话后再删除项目。')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('只删除项目配置，不删除手机项目文件夹。\n\n${project.name}'),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: deleteFiles,
                      onChanged: (value) {
                        setDialogState(() => deleteFiles = value ?? false);
                      },
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('同时删除绑定文件夹内容'),
                      subtitle: const Text('永久删除文件夹内全部文件和子目录，保留文件夹本身'),
                    ),
                    if (deleteFiles)
                      Text(
                        '将清空：${project.localPath}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            if (taskCount == 0)
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(deleteFiles ? '删除项目和内容' : '删除项目'),
              ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.controller.deleteProject(project, deleteFiles: deleteFiles);
      if (mounted && _pendingProjectId == project.id) {
        setState(() => _pendingProjectId = null);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除项目失败：$error')));
      }
    }
  }
}

class _ProjectFormValue {
  const _ProjectFormValue({required this.name, required this.localPath});

  final String name;
  final String? localPath;
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
    return Tooltip(
      message: label,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          padding: const EdgeInsets.symmetric(horizontal: 5),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: Theme.of(context).colorScheme.onSurface,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow
              .withValues(alpha: 0.7),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 17),
            const SizedBox(width: 3),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItemIconButton extends StatelessWidget {
  const _DrawerItemIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        fixedSize: const Size(26, 26),
        minimumSize: Size.zero,
        maximumSize: const Size(26, 26),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
      ),
      icon: Icon(icon, size: 14),
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
              itemCount: 8,
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
                  return _FloatingCapsuleSettingsTile(controller: controller);
                }
                if (index == 2) {
                  return _FloatingCapsuleScaleSettingsTile(
                    controller: controller,
                  );
                }
                if (index == 3) {
                  return _VersionSettingsTile(controller: controller);
                }
                if (index == 4) {
                  return _FontScaleSettingsTile(controller: controller);
                }
                if (index == 5) {
                  return _StorageSettingsTile(controller: controller);
                }
                if (index == 6) {
                  return _PermissionsSettingsTile(controller: controller);
                }
                return _DeveloperSettingsTile(controller: controller);
              },
            ),
    );
  }
}

class _FloatingCapsuleSettingsTile extends StatelessWidget {
  const _FloatingCapsuleSettingsTile({required this.controller});

  final AppController controller;

  Future<void> _toggle(BuildContext context, bool enabled) async {
    final changed = await controller.setFloatingCapsuleEnabled(enabled);
    if (!changed && enabled && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请在系统设置中允许悬浮窗权限，再重新打开此开关')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: const Icon(Icons.picture_in_picture_alt_outlined),
      title: const Text('后台悬浮胶囊'),
      subtitle: const Text('在其他 App 上显示当前任务状态，可拖到屏幕边缘半隐藏'),
      value: controller.floatingCapsuleEnabled,
      onChanged: (value) => unawaited(_toggle(context, value)),
    );
  }
}

class _FloatingCapsuleScaleSettingsTile extends StatelessWidget {
  const _FloatingCapsuleScaleSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final percent = (controller.floatingCapsuleScale * 100).round();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(child: Icon(Icons.open_in_full_outlined)),
      title: const Text('悬浮窗大小'),
      subtitle: Text('$percent% · 调整悬浮胶囊的显示大小'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        var value = controller.floatingCapsuleScale;
        await showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('悬浮窗大小'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${(value * 100).round()}%'),
                  Slider(
                    min: 0.75,
                    max: 1.4,
                    divisions: 13,
                    value: value,
                    label: '${(value * 100).round()}%',
                    onChanged: (next) => setState(() => value = next),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    unawaited(controller.setFloatingCapsuleScale(value));
                    Navigator.pop(context);
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FontScaleSettingsTile extends StatelessWidget {
  const _FontScaleSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final percent = (controller.fontScale * 100).round();
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(child: Icon(Icons.text_fields_outlined)),
      title: const Text('字体大小'),
      subtitle: Text('$percent% · 调整对话和设置页面文字'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        var value = controller.fontScale;
        await showDialog<void>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: const Text('字体大小'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${(value * 100).round()}%'),
                  Slider(
                    min: 0.85,
                    max: 1.15,
                    divisions: 6,
                    value: value,
                    label: '${(value * 100).round()}%',
                    onChanged: (next) => setState(() => value = next),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    unawaited(controller.setFontScale(value));
                    Navigator.pop(context);
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        );
      },
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

class _StorageSettingsTile extends StatelessWidget {
  const _StorageSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(
        child: Icon(Icons.cleaning_services_outlined),
      ),
      title: const Text('清理空间'),
      subtitle: const Text('清理未被对话引用的附件和残留临时文件，不删除对话或项目文件'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('清理空间？'),
            content: const Text(
              '将清理未被历史对话引用的附件和残留临时文件。\n'
              '已被对话引用的图片、文件和项目文件不会删除。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清理'),
              ),
            ],
          ),
        );
        if (confirmed != true || !context.mounted) return;
        try {
          final result = await controller.cleanupStorage();
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.removedFiles == 0
                    ? '没有可清理的文件'
                    : '已清理 ${result.removedFiles} 个文件，释放 ${_formatBytes(result.removedBytes)}',
              ),
            ),
          );
        } catch (error) {
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('清理失败：$error')));
          }
        }
      },
    );
  }
}

class _PermissionsSettingsTile extends StatelessWidget {
  const _PermissionsSettingsTile({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const CircleAvatar(child: Icon(Icons.security_outlined)),
      title: const Text('APP 权限'),
      subtitle: const Text('管理悬浮窗、通知、文件访问和更新安装权限'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AppPermissionsPage(controller: controller),
          ),
        );
      },
    );
  }
}

class AppPermissionsPage extends StatefulWidget {
  const AppPermissionsPage({required this.controller, super.key});

  final AppController controller;

  @override
  State<AppPermissionsPage> createState() => _AppPermissionsPageState();
}

class _AppPermissionsPageState extends State<AppPermissionsPage>
    with WidgetsBindingObserver {
  bool? _overlayGranted;
  bool? _notificationGranted;
  bool? _storageGranted;
  bool? _installGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final values = await Future.wait<bool>([
      widget.controller.canDrawOverlays(),
      widget.controller.canPostNotifications(),
      widget.controller.hasExternalStorageAccess(),
      widget.controller.canInstallPackages(),
    ]);
    if (!mounted) return;
    setState(() {
      _overlayGranted = values[0];
      _notificationGranted = values[1];
      _storageGranted = values[2];
      _installGranted = values[3];
    });
  }

  Future<void> _request(Future<bool> Function() action) async {
    await action();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('APP 权限')),
      body: ListView(
        children: [
          _PermissionTile(
            icon: Icons.picture_in_picture_alt_outlined,
            title: '悬浮窗',
            description: '用于在其他 App 前显示任务进度',
            granted: _overlayGranted,
            onRequest: () =>
                _request(widget.controller.requestOverlayPermission),
          ),
          const Divider(height: 1),
          _PermissionTile(
            icon: Icons.notifications_none_outlined,
            title: '通知',
            description: '用于后台任务和文件传输的系统通知',
            granted: _notificationGranted,
            onRequest: () =>
                _request(widget.controller.requestNotificationPermission),
          ),
          const Divider(height: 1),
          _PermissionTile(
            icon: Icons.folder_open_outlined,
            title: '文件访问',
            description: '用于读取和保存手机项目文件',
            granted: _storageGranted,
            onRequest: () =>
                _request(widget.controller.requestExternalStorageAccess),
          ),
          const Divider(height: 1),
          _PermissionTile(
            icon: Icons.system_update_alt_outlined,
            title: '安装更新',
            description: '用于在 APP 内安装已下载的新版本',
            granted: _installGranted,
            onRequest: () =>
                _request(widget.controller.requestInstallPermission),
          ),
        ],
      ),
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.description,
    required this.granted,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool? granted;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final trailing = granted == null
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : granted!
        ? const Icon(Icons.check_circle, color: Colors.green)
        : TextButton(onPressed: onRequest, child: const Text('去设置'));
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(description),
      trailing: trailing,
      onTap: granted == false ? onRequest : null,
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
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

IconData _statusIcon(String status, {bool isRunning = false}) {
  if (isRunning && status != 'waiting' && status != 'stopping') {
    return Icons.sync;
  }
  switch (status) {
    case 'queued':
      return Icons.schedule_outlined;
    case 'running':
      return Icons.sync;
    case 'waiting':
      return Icons.hourglass_top_outlined;
    case 'completed':
      return Icons.check_circle_outline;
    case 'failed':
      return Icons.error_outline;
    case 'stopping':
      return Icons.stop_circle_outlined;
    case 'cancelled':
    case 'canceled':
      return Icons.stop_circle_outlined;
    case 'interrupted':
    case 'unknown':
      return Icons.help_outline;
    default:
      return Icons.chat_bubble_outline;
  }
}

Color _statusColor(String status, bool isRunning) {
  if (isRunning && status != 'waiting' && status != 'stopping') {
    return Colors.blue;
  }
  switch (status) {
    case 'queued':
    case 'waiting':
      return Colors.orange;
    case 'completed':
      return Colors.green;
    case 'failed':
      return Colors.red;
    case 'running':
      return Colors.blue;
    case 'stopping':
      return Colors.orange;
    case 'cancelled':
    case 'canceled':
    case 'interrupted':
    case 'unknown':
      return Colors.grey;
    default:
      return Colors.grey;
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
