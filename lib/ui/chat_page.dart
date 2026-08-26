import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';

import '../agent/agent_tools.dart';
import '../agent/ai_protocol.dart';
import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';
import 'file_manager_page.dart';
import 'local_preview_page.dart';
import 'project_file_manager_page.dart';
import 'server_dashboard_page.dart';
import 'terminal_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    required this.controller,
    this.agentAutoExecute,
    required this.taskId,
    this.initialProjectId,
    required this.onTaskActivated,
    required this.onOpenSettings,
    required this.onConfirmTool,
    required this.onConfirmHostKey,
    required this.onUserInfoRequest,
    super.key,
  });

  final AppController controller;
  final bool? agentAutoExecute;
  final String? taskId;
  final String? initialProjectId;
  final ValueChanged<String> onTaskActivated;
  final VoidCallback onOpenSettings;
  final Future<bool> Function(
    Task task,
    AgentTool tool,
    Map<String, Object?> arguments,
  )
  onConfirmTool;
  final Future<bool> Function(Task task, SshHostKey key) onConfirmHostKey;
  final Future<List<String>?> Function(Task task, SshUserInfoRequest request)
  onUserInfoRequest;

  @override
  ChatPageState createState() => ChatPageState();
}

class ChatPageState extends State<ChatPage> {
  static const _maxAttachmentBytes = 20 * 1024 * 1024;

  final _prompt = TextEditingController();
  final _scroll = ScrollController();
  String? _taskId;
  String? _projectId;
  String? _providerId;
  String? _reviewProviderId;
  String? _reviewModelOverride;
  String? _serverId;
  String _mode = 'chat';
  String _workMode = 'chat';
  String _executionMode = 'confirm';
  String? _workingDirectory;
  String? _modelOverride;
  String? _reasoningEffortOverride;
  bool _loadingModels = false;
  bool _sending = false;
  List<AiAttachment> _pendingAttachments = const [];
  int _sendingGeneration = 0;
  int _lastEventCount = -1;
  bool _loadingEarlier = false;
  String? _usageRequestedFor;

  bool get _agentAutoExecute =>
      widget.agentAutoExecute ?? widget.controller.agentAutoExecute;

  @override
  void initState() {
    super.initState();
    _taskId = widget.taskId;
    _projectId = widget.initialProjectId;
    _executionMode = _agentAutoExecute ? 'auto' : 'confirm';
    _ensureTaskEvents();
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final conversationChanged =
        (widget.taskId != oldWidget.taskId && widget.taskId != _taskId) ||
        (widget.initialProjectId != oldWidget.initialProjectId &&
            widget.taskId == null);
    if (conversationChanged) {
      setState(() {
        _taskId = widget.taskId;
        _projectId = widget.initialProjectId;
        _providerId = null;
        _reviewProviderId = null;
        _reviewModelOverride = null;
        _serverId = null;
        _workMode = 'chat';
        _mode = 'chat';
        _executionMode = _agentAutoExecute ? 'auto' : 'confirm';
        _workingDirectory = null;
        _modelOverride = null;
        _reasoningEffortOverride = null;
        _pendingAttachments = const [];
      });
      _ensureTaskEvents();
    } else if (_agentAutoExecute !=
            (oldWidget.agentAutoExecute ??
                oldWidget.controller.agentAutoExecute) &&
        _currentTask == null) {
      setState(() => _executionMode = _agentAutoExecute ? 'auto' : 'confirm');
    }
  }

  Future<void> openWorkModePicker() => _selectWorkMode();

  void _ensureTaskEvents() {
    final taskId = _taskId;
    if (taskId == null) return;
    unawaited(
      widget.controller
          .ensureTaskEventsLoaded(taskId)
          .then((_) {
            if (mounted && _taskId == taskId) setState(() {});
          })
          .catchError((Object error, StackTrace stack) {
            if (mounted && _taskId == taskId) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('历史记录加载失败：$error')));
            }
          }),
    );
  }

  @override
  void dispose() {
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final task = _currentTask;
    final events = task == null
        ? const <TaskEvent>[]
        : widget.controller.eventsFor(task.id);
    final presentations = _eventPresentations(events);
    final hasEarlier =
        task != null && widget.controller.hasEarlierTaskEvents(task.id);
    final running = task != null && widget.controller.isTaskRunning(task.id);
    final streamingText = task == null
        ? ''
        : widget.controller.streamingAssistantText(task.id);
    final provider = _providerFor(task?.providerId ?? _effectiveProviderId);
    if (provider != null && _usageRequestedFor != provider.id) {
      _usageRequestedFor = provider.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.controller.loadProviderUsage(provider));
      });
    }
    final workMode =
        task?.effectiveWorkMode ??
        resolveWorkMode(
          workMode: _workMode,
          mode: _mode,
          projectId: _projectId,
          serverId: _serverId,
        );
    final usesLocal = workModeUsesLocal(workMode);
    final usesServer = workModeUsesServer(workMode);
    final projectId = task == null ? _projectId : task.projectId;
    final serverId = task == null ? _serverId : task.serverId;
    final project = widget.controller.projectFor(projectId);
    final activeProject = usesLocal ? project : null;
    final boundServer = usesServer ? _serverFor(serverId) : null;
    if (_lastEventCount != events.length && !_loadingEarlier) {
      _lastEventCount = events.length;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }

    return Column(
      children: [
        _ContextBar(
          project: activeProject,
          server: boundServer,
          workMode: workMode,
          provider: provider,
          usage: provider == null
              ? null
              : widget.controller.providerUsageFor(provider.id),
          onProviderTap: running ? null : _selectProvider,
          onEdit: running ? null : _editContext,
          onShowContext: () => _showContextStatus(events),
        ),
        if (task?.status == 'unknown')
          const _Notice(
            icon: Icons.help_outline,
            text: '上次任务在手机端中断，执行结果未知。继续前先让 AI 检查服务器状态。',
          ),
        if (task?.status == 'failed')
          const _Notice(icon: Icons.error_outline, text: '任务执行失败，可以补充消息继续处理。'),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              widget.controller.providers.isEmpty
                  ? _MissingProvider(onOpenSettings: widget.onOpenSettings)
                  : task != null &&
                        !widget.controller.taskEventsLoaded(task.id) &&
                        presentations.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : presentations.isEmpty
                  ? streamingText.isEmpty
                        ? const _EmptyConversation()
                        : ListView(
                            controller: _scroll,
                            padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                            children: [_StreamingTile(text: streamingText)],
                          )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                      itemCount:
                          presentations.length +
                          (hasEarlier ? 1 : 0) +
                          (streamingText.isEmpty ? 0 : 1),
                      itemBuilder: (context, index) {
                        if (hasEarlier && index == 0) {
                          return _LoadEarlierTile(
                            loading: _loadingEarlier,
                            onPressed: _loadingEarlier ? null : _loadEarlier,
                          );
                        }
                        final contentIndex = index - (hasEarlier ? 1 : 0);
                        if (contentIndex == presentations.length) {
                          return _StreamingTile(text: streamingText);
                        }
                        return _EventTile(
                          controller: widget.controller,
                          presentation: presentations[contentIndex],
                          key: ValueKey(
                            '${presentations[contentIndex].event.eventId}-$contentIndex',
                          ),
                        );
                      },
                    ),
              if (task != null)
                Positioned(
                  right: 12,
                  bottom: 6,
                  child: IgnorePointer(
                    child: _TaskStatusBar(task: task, events: events),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_pendingAttachments.isNotEmpty)
                  _AttachmentStrip(
                    attachments: _pendingAttachments,
                    onRemove: (attachment) {
                      setState(() {
                        _pendingAttachments = [
                          for (final item in _pendingAttachments)
                            if (!identical(item, attachment)) item,
                        ];
                      });
                    },
                  ),
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.48),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
                  child: Column(
                    children: [
                      TextField(
                        controller: _prompt,
                        minLines: 2,
                        maxLines: 6,
                        enabled:
                            widget.controller.providers.isNotEmpty &&
                            !running &&
                            !_sending,
                        decoration: InputDecoration(
                          hintText: task?.mode == 'agent' || _mode == 'agent'
                              ? '告诉手机 Agent 要完成什么'
                              : '发消息',
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 4,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: '附件、图片和项目文件',
                            visualDensity: VisualDensity.compact,
                            onPressed:
                                widget.controller.providers.isEmpty ||
                                    running ||
                                    _sending
                                ? null
                                : _openComposerActions,
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                          const Spacer(),
                          Flexible(
                            child: _ModelReasoningPill(
                              model:
                                  task?.modelOverride ??
                                  _modelOverride ??
                                  provider?.model,
                              reasoningEffort:
                                  task?.reasoningEffortOverride ??
                                  _reasoningEffortOverride ??
                                  provider?.reasoningEffort ??
                                  'default',
                              onTap: running || _loadingModels
                                  ? null
                                  : _selectModelAndReasoning,
                            ),
                          ),
                          _ChatUtilityBar(
                            hasProject: activeProject != null,
                            hasServers:
                                usesServer &&
                                widget.controller.servers.isNotEmpty,
                            onProjectFiles: activeProject == null
                                ? null
                                : _openProjectFiles,
                            onServerFiles:
                                !usesServer || widget.controller.servers.isEmpty
                                ? null
                                : _openFilesFromTools,
                            onTerminal:
                                !usesServer || widget.controller.servers.isEmpty
                                ? null
                                : _openTerminalFromTools,
                          ),
                          const SizedBox(width: 2),
                          if (running)
                            IconButton.filled(
                              tooltip: '停止',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  widget.controller.stopTask(task.id),
                              icon: const Icon(Icons.stop),
                            )
                          else
                            IconButton.filled(
                              tooltip: '发送',
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  _sending ||
                                      widget.controller.providers.isEmpty
                                  ? null
                                  : _send,
                              icon: _sending
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.send_outlined),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _ConversationFooter(
                  controller: widget.controller,
                  server: boundServer,
                  task: task,
                  executionMode: task?.executionMode ?? _executionMode,
                  onOpenDashboard: boundServer == null
                      ? null
                      : () => _openServerDashboard(boundServer),
                  onFirstHostKey: task == null
                      ? null
                      : (key) => widget.onConfirmHostKey(task, key),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Task? get _currentTask {
    final id = _taskId;
    if (id == null) return null;
    for (final task in widget.controller.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  String? get _effectiveProviderId {
    if (_providerId != null) return _providerId;
    for (final provider in widget.controller.providers) {
      if (provider.isDefault) return provider.id;
    }
    return widget.controller.providers.isEmpty
        ? null
        : widget.controller.providers.first.id;
  }

  ProviderProfile? _providerFor(String? id) {
    if (id == null) return null;
    for (final provider in widget.controller.providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  Future<void> _loadEarlier() async {
    final taskId = _taskId;
    if (!mounted || taskId == null || _loadingEarlier) return;
    final oldOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    final oldMaxExtent = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    setState(() => _loadingEarlier = true);
    try {
      await widget.controller.loadEarlierTaskEvents(taskId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('历史记录加载失败：$error')));
      }
      return;
    } finally {
      if (mounted) {
        setState(() {
          _loadingEarlier = false;
          _lastEventCount = widget.controller.eventsFor(taskId).length;
        });
      }
    }
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final addedExtent = _scroll.position.maxScrollExtent - oldMaxExtent;
      final target = (oldOffset + addedExtent)
          .clamp(0.0, _scroll.position.maxScrollExtent)
          .toDouble();
      _scroll.jumpTo(target);
    });
  }

  Future<void> _showContextStatus(List<TaskEvent> events) {
    return showDialog<void>(
      context: context,
      builder: (_) => _ContextStatusDialog(
        usage: _latestUsage(events),
        compactionCount: _compactionCount(events),
      ),
    );
  }

  ServerProfile? _serverFor(String? id) {
    if (id == null) return null;
    for (final server in widget.controller.servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  ServerProfile? get _toolServer {
    final task = _currentTask;
    final taskServer =
        task != null && workModeUsesServer(task.effectiveWorkMode)
        ? _serverFor(task.serverId)
        : null;
    if (taskServer != null) return taskServer;
    final selectedWorkMode = resolveWorkMode(
      workMode: _workMode,
      mode: _mode,
      projectId: _projectId,
      serverId: _serverId,
    );
    final selectedServer = workModeUsesServer(selectedWorkMode)
        ? _serverFor(_serverId)
        : null;
    if (selectedServer != null) return selectedServer;
    return widget.controller.servers.length == 1
        ? widget.controller.servers.single
        : null;
  }

  Future<ServerProfile?> _resolveToolServer() async {
    final selected = _toolServer;
    if (selected != null) return selected;
    final servers = widget.controller.servers;
    if (servers.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('请先添加目标服务器')));
      }
      return null;
    }
    return showModalBottomSheet<ServerProfile>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('选择服务器'),
              subtitle: Text('此选择只用于打开服务器工具，不会改变当前对话模式'),
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
  }

  Future<void> _openTerminalFromTools() async {
    final server = await _resolveToolServer();
    if (server == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TerminalPage(controller: widget.controller, server: server),
      ),
    );
  }

  Future<void> _openFilesFromTools() async {
    final server = await _resolveToolServer();
    if (server == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FileManagerPage(controller: widget.controller, server: server),
      ),
    );
  }

  Future<void> _openProjectFiles() async {
    final project = widget.controller.projectFor(
      _currentTask?.projectId ?? _projectId,
    );
    if (project == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProjectFileManagerPage(
          controller: widget.controller,
          project: project,
        ),
      ),
    );
  }

  Future<void> _openLocalPreview() async {
    final project = widget.controller.projectFor(
      _currentTask?.projectId ?? _projectId,
    );
    if (project == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            LocalPreviewPage(controller: widget.controller, project: project),
      ),
    );
  }

  void _openServerDashboard(ServerProfile server) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ServerDashboardPage(controller: widget.controller, server: server),
      ),
    );
  }

  Future<void> _openComposerActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('添加到消息'),
              subtitle: Text('附件会随本次消息发送给当前供应商'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_outlined),
              title: const Text('上传文件或图片'),
              onTap: () => Navigator.pop(context, 'attachment'),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('让 AI 生成图片'),
              subtitle: const Text('生成请求会作为普通消息发送，由 Agent 自行调用生图工具'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            if (widget.controller.projectFor(
                  _currentTask?.projectId ?? _projectId,
                ) !=
                null)
              ListTile(
                leading: const Icon(Icons.folder_special_outlined),
                title: const Text('选择手机项目文件'),
                onTap: () => Navigator.pop(context, 'project'),
              ),
            if (widget.controller.projectFor(
                  _currentTask?.projectId ?? _projectId,
                ) !=
                null)
              ListTile(
                leading: const Icon(Icons.preview_outlined),
                title: const Text('打开本地网页预览'),
                subtitle: const Text('查看页面、控制台日志并检查本地资源'),
                onTap: () => Navigator.pop(context, 'preview'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'attachment') {
      await _pickAttachments();
    } else if (action == 'project') {
      await _openProjectFiles();
    } else if (action == 'image') {
      await _requestImagePrompt();
    } else if (action == 'preview') {
      await _openLocalPreview();
    }
  }

  Future<void> _requestImagePrompt() async {
    final editor = TextEditingController();
    final prompt = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('生成图片'),
        content: TextField(
          controller: editor,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '描述你想生成的图片'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, editor.text.trim()),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    editor.dispose();
    if (prompt == null || prompt.isEmpty || !mounted) return;
    _prompt.text = '请生成图片：$prompt';
    await _send();
  }

  Future<void> _selectProvider() async {
    if (widget.controller.providers.isEmpty) {
      widget.onOpenSettings();
      return;
    }
    final current = _currentTask?.providerId ?? _effectiveProviderId;
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('切换 AI 供应商'),
              subtitle: Text('只影响当前对话；不会修改供应商配置'),
            ),
            for (final provider in widget.controller.providers)
              ListTile(
                leading: Icon(
                  provider.id == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(provider.name),
                subtitle: Text(
                  '${wireApiLabel(provider.wireApi)} · '
                  '${_providerUsageText(widget.controller.providerUsageFor(provider.id))}',
                ),
                onTap: () => Navigator.pop(context, provider.id),
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('供应商设置'),
              onTap: () {
                Navigator.pop(context);
                widget.onOpenSettings();
              },
            ),
          ],
        ),
      ),
    );
    if (selected == null || selected == current || !mounted) return;
    final task = _currentTask;
    try {
      if (task == null) {
        setState(() {
          _providerId = selected;
          _modelOverride = null;
          _reasoningEffortOverride = null;
          _usageRequestedFor = null;
        });
      } else {
        final updated = await widget.controller.updateTaskConfiguration(
          taskId: task.id,
          mode: task.mode,
          workMode: task.effectiveWorkMode,
          serverId: task.serverId,
          providerId: selected,
          workingDirectory: task.workingDirectory,
          executionMode: task.executionMode,
          modelOverride: '',
          reasoningEffortOverride: '',
        );
        if (!mounted) return;
        setState(() {
          _providerId = updated.providerId;
          _modelOverride = null;
          _reasoningEffortOverride = null;
          _usageRequestedFor = null;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换供应商失败：$error')));
      }
    }
  }

  Future<void> _selectWorkMode() async {
    final task = _currentTask;
    if (task != null && widget.controller.isTaskRunning(task.id)) return;
    final current =
        task?.effectiveWorkMode ??
        resolveWorkMode(
          workMode: _workMode,
          mode: _mode,
          projectId: _projectId,
          serverId: _serverId,
        );
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('切换工作模式'),
              subtitle: Text('决定当前对话可以使用哪些 Agent 工具'),
            ),
            for (final mode in workModeOptions)
              ListTile(
                leading: Icon(_workModeIcon(mode)),
                title: Text(workModeLabel(mode)),
                subtitle: Text(workModeDescription(mode)),
                trailing: mode == current
                    ? const Icon(Icons.check_circle_outline)
                    : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected == current || !mounted) return;

    final serverId = task == null ? _serverId : task.serverId;
    if (workModeUsesServer(selected) &&
        (serverId == null || serverId.isEmpty)) {
      await _editContext(workModeOverride: selected);
      return;
    }

    if (task == null) {
      setState(() {
        _workMode = selected;
        _mode = taskModeForWorkMode(selected);
      });
      return;
    }

    try {
      final updated = await widget.controller.updateTaskConfiguration(
        taskId: task.id,
        mode: taskModeForWorkMode(selected),
        workMode: selected,
        projectId: task.projectId,
        serverId: task.serverId,
        providerId: task.providerId,
        reviewProviderId: task.reviewProviderId,
        reviewModelOverride: task.reviewModelOverride,
        workingDirectory: task.workingDirectory,
        executionMode: task.executionMode,
      );
      if (!mounted) return;
      setState(() {
        _workMode = updated.effectiveWorkMode;
        _mode = updated.mode;
        _serverId = updated.serverId;
        _executionMode = updated.executionMode;
        _workingDirectory = updated.workingDirectory;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换工作模式失败：$error')));
      }
    }
  }

  Future<void> _editContext({String? workModeOverride}) async {
    final task = _currentTask;
    final initialWorkMode =
        workModeOverride ??
        task?.effectiveWorkMode ??
        resolveWorkMode(
          workMode: _workMode,
          mode: _mode,
          projectId: _projectId,
          serverId: _serverId,
        );
    final result = await showModalBottomSheet<_ConversationConfig>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ConversationSetupSheet(
        controller: widget.controller,
        initial: _ConversationConfig(
          taskId: task?.id,
          providerId: task?.providerId ?? _effectiveProviderId,
          serverId: task == null ? _serverId : task.serverId,
          reviewProviderId: task?.reviewProviderId,
          reviewModelOverride: task?.reviewModelOverride,
          mode: taskModeForWorkMode(initialWorkMode),
          workMode: initialWorkMode,
          executionMode: task?.executionMode ?? _executionMode,
          workingDirectory: task?.workingDirectory ?? _workingDirectory,
          hasProject: task?.projectId != null || _projectId != null,
          localAccessCount: task == null
              ? 0
              : widget.controller.localAccessCount(task.id),
        ),
      ),
    );
    if (result == null || !mounted) return;

    if (task != null) {
      final providerChanged = result.providerId != task.providerId;
      try {
        final updated = await widget.controller.updateTaskConfiguration(
          taskId: task.id,
          mode: result.mode,
          workMode: result.workMode,
          projectId: task.projectId,
          serverId: result.serverId,
          providerId: result.providerId,
          reviewProviderId: result.reviewProviderId ?? '',
          reviewModelOverride: result.reviewModelOverride ?? '',
          workingDirectory: result.workingDirectory,
          executionMode: result.executionMode,
          modelOverride: providerChanged ? '' : null,
          reasoningEffortOverride: providerChanged ? '' : null,
        );
        if (!mounted) return;
        setState(() {
          _providerId = updated.providerId;
          _reviewProviderId = updated.reviewProviderId;
          _reviewModelOverride = updated.reviewModelOverride;
          _serverId = updated.serverId;
          _mode = updated.mode;
          _workMode = updated.effectiveWorkMode;
          _executionMode = updated.executionMode;
          _workingDirectory = updated.workingDirectory;
          _modelOverride = null;
          _reasoningEffortOverride = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              updated.providerId != task.providerId ||
                      updated.serverId != task.serverId ||
                      updated.mode != task.mode ||
                      updated.effectiveWorkMode != task.effectiveWorkMode
                  ? '对话配置已更新，后续任务将使用新的上下文'
                  : '对话配置已更新',
            ),
          ),
        );
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('更新对话配置失败：$error')));
        }
      }
      return;
    }

    final providerChanged = result.providerId != _providerId;
    setState(() {
      _providerId = result.providerId;
      _reviewProviderId = result.reviewProviderId;
      _reviewModelOverride = result.reviewModelOverride;
      _serverId = result.serverId;
      _mode = result.mode;
      _workMode = result.workMode;
      _executionMode = result.executionMode;
      _workingDirectory = result.workingDirectory;
      if (providerChanged) {
        _modelOverride = null;
        _reasoningEffortOverride = null;
      }
    });
  }

  Future<void> _selectModelAndReasoning() async {
    final task = _currentTask;
    final provider = _providerFor(task?.providerId ?? _effectiveProviderId);
    if (provider == null) {
      widget.onOpenSettings();
      return;
    }
    setState(() => _loadingModels = true);
    try {
      final loaded = await widget.controller.loadProviderModels(provider);
      if (!mounted) return;
      final models = <String>[
        provider.model,
        for (final model in loaded)
          if (model != provider.model) model,
      ];
      var selectedModel =
          task?.modelOverride ?? _modelOverride ?? provider.model;
      var selectedReasoningEffort =
          task?.reasoningEffortOverride ??
          _reasoningEffortOverride ??
          provider.reasoningEffort;
      final selected = await showModalBottomSheet<_ModelReasoningSelection>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setSheetState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('模型与推理强度'),
                    subtitle: Text(
                      '${_shortModelName(selectedModel)} '
                      '$selectedReasoningEffort',
                    ),
                  ),
                  const Divider(),
                  ExpansionTile(
                    initiallyExpanded: false,
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('AI 模型'),
                    subtitle: Text(
                      _shortModelName(selectedModel),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    children: [
                      for (final model in models)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            model == selectedModel
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                          ),
                          title: Text(model),
                          subtitle: model == provider.model
                              ? const Text('供应商默认模型')
                              : null,
                          onTap: () =>
                              setSheetState(() => selectedModel = model),
                        ),
                    ],
                  ),
                  const Divider(),
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text('推理强度'),
                  ),
                  for (final effort in reasoningEffortOptions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        effort == selectedReasoningEffort
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text('${reasoningEffortLabel(effort)}（$effort）'),
                      subtitle: effort == provider.reasoningEffort
                          ? const Text('供应商默认设置')
                          : null,
                      onTap: () =>
                          setSheetState(() => selectedReasoningEffort = effort),
                    ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(
                      context,
                      _ModelReasoningSelection(
                        model: selectedModel,
                        reasoningEffort: selectedReasoningEffort,
                      ),
                    ),
                    child: const Text('应用'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (selected == null || !mounted) return;
      await _saveModelAndReasoningSelection(provider, selected);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取模型或推理设置失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _saveModelAndReasoningSelection(
    ProviderProfile provider,
    _ModelReasoningSelection selected,
  ) async {
    final task = _currentTask;
    final modelOverride = selected.model == provider.model
        ? ''
        : selected.model;
    final reasoningEffortOverride =
        selected.reasoningEffort == provider.reasoningEffort
        ? ''
        : selected.reasoningEffort;
    if (task == null) {
      setState(() {
        _modelOverride = modelOverride.isEmpty ? null : modelOverride;
        _reasoningEffortOverride = reasoningEffortOverride.isEmpty
            ? null
            : reasoningEffortOverride;
      });
      return;
    }
    try {
      await widget.controller.updateTaskConfiguration(
        taskId: task.id,
        mode: task.mode,
        workMode: task.effectiveWorkMode,
        serverId: task.serverId,
        providerId: task.providerId,
        workingDirectory: task.workingDirectory,
        executionMode: task.executionMode,
        modelOverride: modelOverride,
        reasoningEffortOverride: reasoningEffortOverride,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('更新模型设置失败：$error')));
      }
    }
  }

  Future<void> _send() async {
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty && _pendingAttachments.isEmpty) return;
    final attachments = List<AiAttachment>.unmodifiable(_pendingAttachments);
    final providerId = _effectiveProviderId;
    if (providerId == null) {
      widget.onOpenSettings();
      return;
    }
    var workMode =
        _currentTask?.effectiveWorkMode ??
        resolveWorkMode(
          workMode: _workMode,
          mode: _mode,
          projectId: _projectId,
          serverId: _serverId,
        );
    if (workModeUsesServer(workMode) &&
        (_currentTask?.serverId ?? _serverId) == null) {
      await _editContext(workModeOverride: workMode);
      if (!mounted) return;
      workMode =
          _currentTask?.effectiveWorkMode ??
          resolveWorkMode(
            workMode: _workMode,
            mode: _mode,
            projectId: _projectId,
            serverId: _serverId,
          );
      if (workModeUsesServer(workMode) &&
          (_currentTask?.serverId ?? _serverId) == null) {
        return;
      }
    }
    _prompt.clear();
    setState(() => _pendingAttachments = const []);
    final sendingGeneration = ++_sendingGeneration;
    setState(() => _sending = true);
    try {
      var task = _currentTask;
      if (task == null) {
        task = await widget.controller.createTask(
          mode: taskModeForWorkMode(workMode),
          workMode: workMode,
          projectId: _projectId,
          serverId: _serverId,
          providerId: providerId,
          reviewProviderId: _reviewProviderId,
          reviewModelOverride: _reviewModelOverride,
          modelOverride: _modelOverride,
          reasoningEffortOverride: _reasoningEffortOverride,
          title: _titleFromPrompt(prompt),
          workingDirectory: _workingDirectory,
          executionMode: _executionMode,
        );
        if (mounted) {
          setState(() => _taskId = task!.id);
          widget.onTaskActivated(task.id);
        }
      }
      final activeTask = task;
      final run = widget.controller.runTask(
        activeTask,
        prompt: prompt,
        attachments: attachments,
        confirm: (tool, arguments) =>
            widget.onConfirmTool(activeTask, tool, arguments),
        onFirstHostKey: (key) => widget.onConfirmHostKey(activeTask, key),
        onUserInfoRequest: (request) =>
            widget.onUserInfoRequest(activeTask, request),
      );
      if (mounted && sendingGeneration == _sendingGeneration) {
        setState(() => _sending = false);
      }
      await run;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('任务失败：$error')));
      }
    } finally {
      if (mounted && sendingGeneration == _sendingGeneration) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _pickAttachments() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null || !mounted) return;
    final selected = <AiAttachment>[];
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法读取文件：${file.name}')));
        continue;
      }
      if (bytes.length > _maxAttachmentBytes) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件过大（单个附件上限 20MB）：${file.name}')),
        );
        continue;
      }
      selected.add(
        AiAttachment(
          name: file.name,
          mimeType: _mimeTypeForName(file.name),
          byteLength: bytes.length,
          base64Data: base64Encode(bytes),
        ),
      );
    }
    if (selected.isNotEmpty) {
      setState(
        () => _pendingAttachments = [..._pendingAttachments, ...selected],
      );
    }
  }
}

class _ConversationConfig {
  const _ConversationConfig({
    required this.taskId,
    required this.providerId,
    required this.serverId,
    required this.reviewProviderId,
    required this.reviewModelOverride,
    required this.mode,
    required this.workMode,
    required this.executionMode,
    required this.workingDirectory,
    required this.hasProject,
    required this.localAccessCount,
  });

  final String? taskId;
  final String? providerId;
  final String? serverId;
  final String? reviewProviderId;
  final String? reviewModelOverride;
  final String mode;
  final String workMode;
  final String executionMode;
  final String? workingDirectory;
  final bool hasProject;
  final int localAccessCount;
}

class _ConversationSetupSheet extends StatefulWidget {
  const _ConversationSetupSheet({
    required this.controller,
    required this.initial,
  });

  final AppController controller;
  final _ConversationConfig initial;

  @override
  State<_ConversationSetupSheet> createState() =>
      _ConversationSetupSheetState();
}

class _ConversationSetupSheetState extends State<_ConversationSetupSheet> {
  late final ScrollController _scroll = ScrollController();
  late String? _providerId = widget.initial.providerId;
  late String? _serverId = widget.initial.serverId;
  late String? _reviewProviderId = widget.initial.reviewProviderId;
  late String _reviewModelOverride = widget.initial.reviewModelOverride ?? '';
  late String _workMode = widget.initial.workMode;
  late String _executionMode = widget.initial.executionMode;
  late int _localAccessCount = widget.initial.localAccessCount;
  late final TextEditingController _directory = TextEditingController(
    text: widget.initial.workingDirectory,
  );
  List<String> _reviewModels = const [];
  bool _loadingReviewModels = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReviewModels());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _directory.dispose();
    super.dispose();
  }

  ProviderProfile? _reviewProvider() {
    final id = _reviewProviderId;
    if (id == null || id.isEmpty) return null;
    for (final provider in widget.controller.providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  Future<void> _loadReviewModels() async {
    final provider = _reviewProvider();
    if (provider == null) {
      if (mounted) setState(() => _reviewModels = const []);
      return;
    }
    final providerId = provider.id;
    setState(() => _loadingReviewModels = true);
    try {
      final loaded = await widget.controller.loadProviderModels(provider);
      if (!mounted || _reviewProviderId != providerId) return;
      final models = <String>[
        if (_reviewModelOverride.isNotEmpty) _reviewModelOverride,
        provider.model,
        for (final model in loaded)
          if (model != provider.model && model != _reviewModelOverride) model,
      ];
      setState(() => _reviewModels = models);
    } catch (_) {
      if (mounted && _reviewProviderId == providerId) {
        setState(
          () => _reviewModels = [
            if (_reviewModelOverride.isNotEmpty) _reviewModelOverride,
            provider.model,
          ],
        );
      }
    } finally {
      if (mounted && _reviewProviderId == providerId) {
        setState(() => _loadingReviewModels = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        (mediaQuery.size.height - mediaQuery.viewInsets.bottom - 36)
            .clamp(0.0, mediaQuery.size.height * 0.82)
            .toDouble();
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: availableHeight),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            children: [
              Text('对话设置', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _providerId,
                decoration: const InputDecoration(labelText: 'AI 供应商'),
                items: [
                  for (final provider in widget.controller.providers)
                    DropdownMenuItem(
                      value: provider.id,
                      child: Text(provider.name),
                    ),
                ],
                onChanged: (value) => setState(() => _providerId = value),
              ),
              DropdownButtonFormField<String>(
                initialValue: _workMode,
                decoration: const InputDecoration(labelText: '工作模式'),
                items: [
                  for (final mode in workModeOptions)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(workModeLabel(mode)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _workMode = value;
                    });
                  }
                },
              ),
              if (_workMode != 'chat') ...[
                const SizedBox(height: 8),
                Text(
                  '${workModeLabel(_workMode)} Agent',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (workModeUsesServer(_workMode)) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _serverId ?? '',
                    decoration: const InputDecoration(labelText: '目标服务器'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('选择目标服务器')),
                      for (final server in widget.controller.servers)
                        DropdownMenuItem(
                          value: server.id,
                          child: Text(server.name),
                        ),
                    ],
                    onChanged: (value) => setState(
                      () => _serverId = value == null || value.isEmpty
                          ? null
                          : value,
                    ),
                  ),
                  TextField(
                    controller: _directory,
                    decoration: const InputDecoration(labelText: '工作目录（可选）'),
                  ),
                ],
                DropdownButtonFormField<String>(
                  initialValue: _executionMode,
                  decoration: const InputDecoration(labelText: '工具审批'),
                  items: const [
                    DropdownMenuItem(value: 'confirm', child: Text('每次执行前确认')),
                    DropdownMenuItem(
                      value: 'auto_review',
                      child: Text('自动审查后执行'),
                    ),
                    DropdownMenuItem(value: 'auto', child: Text('自由执行（不询问）')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _executionMode = value);
                    }
                  },
                ),
                if (_executionMode == 'auto_review') ...[
                  DropdownButtonFormField<String>(
                    initialValue: _reviewProviderId ?? '',
                    decoration: const InputDecoration(labelText: '审查供应商'),
                    items: [
                      const DropdownMenuItem(
                        value: '',
                        child: Text('未选择（转人工确认）'),
                      ),
                      for (final provider in widget.controller.providers)
                        DropdownMenuItem(
                          value: provider.id,
                          child: Text(provider.name),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _reviewProviderId = value == null || value.isEmpty
                            ? null
                            : value;
                        _reviewModelOverride = '';
                        _reviewModels = const [];
                      });
                      unawaited(_loadReviewModels());
                    },
                  ),
                  if (_reviewProvider() != null)
                    DropdownButtonFormField<String>(
                      initialValue: _reviewModelOverride.isEmpty
                          ? null
                          : _reviewModelOverride,
                      decoration: InputDecoration(
                        labelText: '审查模型',
                        suffixIcon: _loadingReviewModels
                            ? const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      items: [
                        for (final model in _reviewModels)
                          DropdownMenuItem(value: model, child: Text(model)),
                      ],
                      onChanged: (value) =>
                          setState(() => _reviewModelOverride = value ?? ''),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '自动审查只处理需要审批的工具；审查失败会转为人工确认，不会更换协议或供应商。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (workModeUsesLocal(_workMode))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: const Text('项目外手机文件'),
                    subtitle: Text(
                      _localAccessCount == 0
                          ? '默认禁止，Agent 请求时由你临时授权'
                          : '当前对话已授权 $_localAccessCount 个范围',
                    ),
                    trailing: _localAccessCount == 0
                        ? null
                        : TextButton(
                            onPressed: widget.initial.taskId == null
                                ? null
                                : () {
                                    widget.controller.revokeLocalAccess(
                                      widget.initial.taskId!,
                                    );
                                    setState(() => _localAccessCount = 0);
                                  },
                            child: const Text('清除'),
                          ),
                  ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  if (workModeUsesServer(_workMode) && _serverId == null) {
                    return;
                  }
                  Navigator.pop(
                    context,
                    _ConversationConfig(
                      taskId: widget.initial.taskId,
                      providerId: _providerId,
                      serverId: _serverId,
                      reviewProviderId: _workMode != 'chat'
                          ? _reviewProviderId
                          : null,
                      reviewModelOverride:
                          _workMode != 'chat' &&
                              _reviewModelOverride.trim().isNotEmpty
                          ? _reviewModelOverride.trim()
                          : null,
                      mode: taskModeForWorkMode(_workMode),
                      workMode: _workMode,
                      executionMode: _executionMode,
                      workingDirectory:
                          !workModeUsesServer(_workMode) ||
                              _directory.text.trim().isEmpty
                          ? null
                          : _directory.text.trim(),
                      hasProject: widget.initial.hasProject,
                      localAccessCount: _localAccessCount,
                    ),
                  );
                },
                child: const Text('应用'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _workModeIcon(String value) {
  switch (value) {
    case 'collaborative':
      return Icons.sync_alt_rounded;
    case 'local':
      return Icons.phone_android_outlined;
    case 'server':
      return Icons.dns_outlined;
    case 'chat':
      return Icons.chat_rounded;
    default:
      return Icons.swap_horiz_rounded;
  }
}

class _ContextBar extends StatelessWidget {
  const _ContextBar({
    required this.project,
    required this.server,
    required this.workMode,
    required this.provider,
    required this.usage,
    required this.onProviderTap,
    required this.onEdit,
    required this.onShowContext,
  });

  final Project? project;
  final ServerProfile? server;
  final String workMode;
  final ProviderProfile? provider;
  final ProviderUsageSnapshot? usage;
  final VoidCallback? onProviderTap;
  final VoidCallback? onEdit;
  final VoidCallback onShowContext;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final contextName = workModeUsesServer(workMode)
        ? (server?.name ?? '未选择服务器')
        : workMode == 'chat'
        ? '普通对话'
        : '手机 Agent';
    final contextLabel = project == null
        ? contextName
        : '$contextName · ${project!.name}';
    final usageText = _providerCompactUsageText(usage);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 3, 8, 3),
      child: Column(
        children: [
          Row(
            children: [
              Icon(_workModeIcon(workMode), size: 18, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  contextLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 2),
            child: Row(
              children: [
                Expanded(
                  child: provider != null
                      ? _ContextPill(
                          icon: Icons.hub_outlined,
                          label: provider!.name,
                          onTap: onProviderTap,
                        )
                      : _ContextPill(
                          icon: Icons.hub_outlined,
                          label: '配置供应商',
                          onTap: onProviderTap,
                        ),
                ),
                if (usageText.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    usageText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '上下文状态',
                  onPressed: onShowContext,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.data_usage_outlined, size: 17),
                ),
                IconButton(
                  tooltip: '对话设置',
                  onPressed: onEdit,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.tune_outlined, size: 17),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextPill extends StatelessWidget {
  const _ContextPill({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
          ],
        ],
      ),
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: content,
      ),
    );
  }
}

class _ModelReasoningPill extends StatelessWidget {
  const _ModelReasoningPill({
    required this.model,
    required this.reasoningEffort,
    required this.onTap,
  });

  final String? model;
  final String reasoningEffort;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final modelText = _shortModelName(model ?? '未配置模型');
    final effortText = reasoningEffort == 'default'
        ? 'default'
        : reasoningEffort;
    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_outlined, size: 14),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  '$modelText $effortText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 2),
                const Icon(Icons.keyboard_arrow_down_rounded, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelReasoningSelection {
  const _ModelReasoningSelection({
    required this.model,
    required this.reasoningEffort,
  });

  final String model;
  final String reasoningEffort;
}

class _ContextStatusDialog extends StatelessWidget {
  const _ContextStatusDialog({
    required this.usage,
    required this.compactionCount,
  });

  final Map<String, Object?>? usage;
  final int compactionCount;

  @override
  Widget build(BuildContext context) {
    final inputTokens = _usageNumber(usage, 'input_tokens');
    final outputTokens = _usageNumber(usage, 'output_tokens');
    final totalTokens = _usageNumber(usage, 'total_tokens');
    return AlertDialog(
      title: const Text('上下文状态'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              usage == null ? '供应商未返回 Token 用量' : '最近一次 AI 响应',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _ContextStat(label: '输入 Token', value: _formatUsage(inputTokens)),
            _ContextStat(label: '输出 Token', value: _formatUsage(outputTokens)),
            _ContextStat(label: '总 Token', value: _formatUsage(totalTokens)),
            _ContextStat(label: '已记录压缩次数', value: '$compactionCount 次'),
            const SizedBox(height: 12),
            Text(
              '上下文窗口总量和百分比需要供应商提供，应用不会用估算值冒充真实数据。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _ContextStat extends StatelessWidget {
  const _ContextStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}

Map<String, Object?>? _latestUsage(List<TaskEvent> events) {
  for (final event in events.reversed) {
    if (event.type != 'assistant.completed') continue;
    final value = event.payload['usage'];
    if (value is Map) return Map<String, Object?>.from(value);
  }
  return null;
}

int _compactionCount(List<TaskEvent> events) {
  var count = 0;
  for (final event in events) {
    if (event.type != 'assistant.completed') continue;
    final items = event.payload['responses_output_items'];
    if (items is! List) continue;
    count += items
        .where((item) => item is Map && item['type'] == 'compaction')
        .length;
  }
  return count;
}

int? _usageNumber(Map<String, Object?>? usage, String key) {
  final value = usage?[key];
  return value is num ? value.toInt() : null;
}

String _formatUsage(int? value) {
  if (value == null) return '暂无数据';
  final text = '$value';
  final buffer = StringBuffer();
  for (var index = 0; index < text.length; index++) {
    if (index > 0 && (text.length - index) % 3 == 0) buffer.write(',');
    buffer.write(text[index]);
  }
  return buffer.toString();
}

String _shortModelName(String value) {
  final compact = value.trim();
  if (compact.isEmpty) return '未配置模型';

  // The supplier is already shown separately. Remove a namespace and make
  // the common GPT identifier compact enough for the composer pill.
  var short = compact.split('/').last;
  if (short.toLowerCase().startsWith('gpt')) {
    short = short.substring(3).replaceFirst(RegExp(r'^[-_]+'), '');
    short = short.replaceAll(RegExp(r'[-_]+'), '');
  }
  if (short.isEmpty) short = compact;
  if (short.length <= 16) return short;
  return '${short.substring(0, 13)}...';
}

String _providerUsageText(ProviderUsageSnapshot? usage) {
  if (usage == null) return '';
  if (usage.balance != null) {
    final balance = usage.balance!;
    final text = '余额 ${_formatDecimal(balance.remaining)} ${balance.currency}';
    return usage.planName == null ? text : '$text · ${usage.planName}';
  }
  if (usage.windows.isNotEmpty) {
    final window = usage.windows.first;
    return '${window.label} ${window.usedPercent.round()}%';
  }
  if (usage.planName != null) return usage.planName!;
  if (usage.status == 'error' || usage.status == 'unsupported') return '额度不可用';
  return '';
}

String _providerCompactUsageText(ProviderUsageSnapshot? usage) {
  final balance = usage?.balance;
  if (balance != null) return _formatDecimal(balance.remaining);
  if (usage != null && usage.windows.isNotEmpty) {
    return '${usage.windows.first.usedPercent.round()}%';
  }
  return '';
}

String _formatDecimal(double value) {
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  return value.toStringAsFixed(2);
}

class _MissingProvider extends StatelessWidget {
  const _MissingProvider({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.icon(
        onPressed: onOpenSettings,
        icon: const Icon(Icons.settings_outlined),
        label: const Text('先配置 AI 供应商'),
      ),
    );
  }
}

class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.attachments, required this.onRemove});

  final List<AiAttachment> attachments;
  final ValueChanged<AiAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final attachment = attachments[index];
          return InputChip(
            avatar: Icon(
              attachment.isImage
                  ? Icons.image_outlined
                  : Icons.insert_drive_file_outlined,
              size: 17,
            ),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: Text(attachment.name, overflow: TextOverflow.ellipsis),
            ),
            onDeleted: () => onRemove(attachment),
          );
        },
      ),
    );
  }
}

class _ChatUtilityBar extends StatelessWidget {
  const _ChatUtilityBar({
    required this.hasProject,
    required this.hasServers,
    required this.onProjectFiles,
    required this.onServerFiles,
    required this.onTerminal,
  });

  final bool hasProject;
  final bool hasServers;
  final VoidCallback? onProjectFiles;
  final VoidCallback? onServerFiles;
  final VoidCallback? onTerminal;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      width: 84,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: hasProject ? '手机项目文件夹' : '当前对话未绑定手机项目',
            onPressed: onProjectFiles,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(
              fixedSize: const Size(28, 28),
              minimumSize: Size.zero,
              maximumSize: const Size(28, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.folder_special_outlined, size: 17),
          ),
          IconButton(
            tooltip: hasServers ? '服务器文件夹' : '尚未添加服务器',
            onPressed: onServerFiles,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(
              fixedSize: const Size(28, 28),
              minimumSize: Size.zero,
              maximumSize: const Size(28, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.dns_outlined, size: 17),
          ),
          IconButton(
            tooltip: hasServers ? '服务器终端' : '尚未添加服务器',
            onPressed: onTerminal,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(
              fixedSize: const Size(28, 28),
              minimumSize: Size.zero,
              maximumSize: const Size(28, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.terminal_outlined, size: 14),
          ),
        ],
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined, size: 46),
          SizedBox(height: 12),
          Text('从这里开始对话，或选择手机 Agent 运维服务器'),
        ],
      ),
    );
  }
}

class _LoadEarlierTile extends StatelessWidget {
  const _LoadEarlierTile({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history_rounded, size: 18),
          label: Text(loading ? '正在加载' : '加载更早记录'),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ConversationFooter extends StatelessWidget {
  const _ConversationFooter({
    required this.controller,
    required this.server,
    required this.task,
    required this.executionMode,
    required this.onOpenDashboard,
    required this.onFirstHostKey,
  });

  final AppController controller;
  final ServerProfile? server;
  final Task? task;
  final String executionMode;
  final VoidCallback? onOpenDashboard;
  final FutureOr<bool> Function(SshHostKey key)? onFirstHostKey;

  @override
  Widget build(BuildContext context) {
    final hasServerStatus =
        server != null &&
        task != null &&
        onOpenDashboard != null &&
        onFirstHostKey != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 1, 12, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (hasServerStatus)
            Expanded(
              child: _ServerStatusSummary(
                controller: controller,
                server: server!,
                onOpenDashboard: onOpenDashboard!,
                onFirstHostKey: onFirstHostKey!,
              ),
            )
          else
            const Spacer(),
          _ExecutionModeStatus(executionMode: executionMode),
        ],
      ),
    );
  }
}

class _ExecutionModeStatus extends StatelessWidget {
  const _ExecutionModeStatus({required this.executionMode});

  final String executionMode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, description, color) = switch (executionMode) {
      'auto' => ('自由', '自由执行', colors.primary),
      'auto_review' => ('审查', '自动审查后执行', colors.secondary),
      _ => ('确认', '执行前确认', colors.outline),
    };
    return Tooltip(
      message: '工具审批：$description',
      child: Semantics(
        label: '工具审批：$description',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.policy_outlined, size: 11, color: color),
              const SizedBox(width: 2),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 8,
                  height: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerStatusSummary extends StatefulWidget {
  const _ServerStatusSummary({
    required this.controller,
    required this.server,
    required this.onOpenDashboard,
    required this.onFirstHostKey,
  });

  final AppController controller;
  final ServerProfile server;
  final VoidCallback onOpenDashboard;
  final FutureOr<bool> Function(SshHostKey key) onFirstHostKey;

  @override
  State<_ServerStatusSummary> createState() => _ServerStatusSummaryState();
}

class _ServerStatusSummaryState extends State<_ServerStatusSummary> {
  static const _refreshInterval = Duration(seconds: 30);

  ServerDashboard? _dashboard;
  Timer? _refreshTimer;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _load());
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _ServerStatusSummary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.server.id != oldWidget.server.id) {
      _dashboard = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final dashboard = await widget.controller.loadServerDashboard(
        widget.server,
        onFirstHostKey: widget.onFirstHostKey,
      );
      if (mounted) setState(() => _dashboard = dashboard);
    } catch (_) {
      // The full dashboard remains the place to inspect a connection error.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _dashboard;
    final cpu = dashboard?.cpuUsage;
    final memory = dashboard == null ? null : _firstPercent(dashboard.memory);
    final systemDisk = dashboard == null ? null : _diskPercent(dashboard, '/');
    final dataDisk = dashboard == null ? null : _diskPercent(dashboard, '/www');
    final summary =
        'C${_percent(cpu)}  内${_percent(memory)}  '
        '盘${_percent(systemDisk)}  数${_percent(dataDisk)}';

    return Semantics(
      button: true,
      label:
          '服务器状态：CPU ${_percent(cpu)}，内存 ${_percent(memory)}，'
          '系统盘 ${_percent(systemDisk)}，数据盘 ${_percent(dataDisk)}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onOpenDashboard,
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            width: double.infinity,
            height: 16,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 8,
                  height: 1,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

int? _diskPercent(ServerDashboard dashboard, String mount) {
  for (final disk in dashboard.disks) {
    if (disk.mount == mount) return disk.usedPercent;
  }
  if (mount == '/') return _firstPercent(dashboard.disk);
  return null;
}

int? _firstPercent(String value) {
  final match = RegExp(r'(\d{1,3})%').firstMatch(value);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String _percent(int? value) => value == null ? '—' : '$value%';

class _TaskStatusBar extends StatefulWidget {
  const _TaskStatusBar({required this.task, required this.events});

  final Task task;
  final List<TaskEvent> events;

  @override
  State<_TaskStatusBar> createState() => _TaskStatusBarState();
}

class _TaskStatusBarState extends State<_TaskStatusBar> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant _TaskStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_normalizedTaskStatus(oldWidget.task.status) !=
        _normalizedTaskStatus(widget.task.status)) {
      _syncClock();
    }
  }

  void _syncClock() {
    _clock?.cancel();
    if (_activeTaskStatus(_normalizedTaskStatus(widget.task.status))) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final presentation = _taskStatusPresentation(widget.task, widget.events);
    final colors = Theme.of(context).colorScheme;
    final color = _taskStatusColor(presentation.status, colors);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final maxWidth = (screenWidth * 0.48).clamp(112.0, 184.0).toDouble();
    final borderColor = color.withValues(alpha: 0.35);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: presentation.accessibleLabel,
        child: Container(
          constraints: const BoxConstraints(minHeight: 12),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: 0.52),
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(3),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  presentation.label,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w600,
                    fontSize: 7,
                    height: 1,
                  ),
                ),
                const SizedBox(width: 3),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 78),
                  child: Text(
                    presentation.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 7,
                      height: 1,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Text(
                  presentation.time,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontFamily: 'monospace',
                    fontSize: 7,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskStatusPresentation {
  const _TaskStatusPresentation({
    required this.status,
    required this.label,
    required this.detail,
    required this.time,
  });

  final String status;
  final String label;
  final String detail;
  final String time;

  String get accessibleLabel => '$label，$detail';
}

_TaskStatusPresentation _taskStatusPresentation(
  Task task,
  List<TaskEvent> events,
) {
  final status = _normalizedTaskStatus(task.status);
  final detail = _taskStatusDetail(status, events);
  return _TaskStatusPresentation(
    status: status,
    label: _taskStatusLabel(status),
    detail: detail,
    time: _taskStatusTime(task, status, events),
  );
}

String _normalizedTaskStatus(String status) {
  return switch (status) {
    'unknown' => 'uncertain',
    'cancelled' || 'canceled' => 'interrupted',
    _ => status,
  };
}

bool _activeTaskStatus(String status) => const {
  'queued',
  'running',
  'waiting',
  'stopping',
  'uncertain',
}.contains(status);

String _taskStatusLabel(String status) {
  return switch (status) {
    'queued' => '等待执行',
    'running' => '执行中',
    'waiting' => '等待确认',
    'stopping' => '正在终止任务',
    'uncertain' => '确认任务状态',
    'completed' => '已完成',
    'failed' => '执行失败',
    'interrupted' => '已终止',
    _ => '状态延迟',
  };
}

String _taskStatusDetail(String status, List<TaskEvent> events) {
  switch (status) {
    case 'queued':
      return '等待执行';
    case 'waiting':
      return '等待确认';
    case 'stopping':
      return '发送终止请求';
    case 'uncertain':
      return '核对是否已送达';
    case 'completed':
      return '执行结束';
    case 'failed':
      return '执行发生错误';
    case 'interrupted':
      return '已停止执行';
  }

  for (final event in events.reversed) {
    switch (event.type) {
      case 'assistant.delta':
        return '生成回复';
      case 'tool.started':
        return _toolStatusPhase(event.payload['name']);
      case 'task.started':
      case 'tool.completed':
      case 'tool.failed':
        return '处理中';
    }
  }
  return '处理中';
}

String _toolStatusPhase(Object? value) {
  final name = value is String ? value : '';
  if (name == 'image.generate') return '生成图片';
  if (name.startsWith('terminal.')) return '执行命令';
  if (name == 'file.write' ||
      name == 'file.replace' ||
      name == 'project.write' ||
      name == 'project.replace' ||
      name == 'server.download_to_project') {
    return '修改文件';
  }
  return '调用工具';
}

String _taskStatusTime(Task task, String status, List<TaskEvent> events) {
  // A conversation can contain several runs. The duration belongs to the
  // latest run, not to the first run ever recorded for this conversation.
  final startedAt =
      _lastTaskEventTime(events, 'task.started') ?? task.createdAt;
  if (status == 'queued') {
    return '已排队 ${_formatTaskDuration(DateTime.now().toUtc().difference(task.createdAt))}';
  }
  if (_activeTaskStatus(status)) {
    return '已运行 ${_formatTaskDuration(DateTime.now().toUtc().difference(startedAt))}';
  }

  final finishedAt = _lastTerminalTaskEventTime(events) ?? task.updatedAt;
  final prefix = switch (status) {
    'completed' => '完成于',
    'failed' => '失败于',
    'interrupted' => '终止于',
    _ => '更新于',
  };
  final duration = finishedAt.isAfter(startedAt)
      ? ' · 用时 ${_formatTaskDuration(finishedAt.difference(startedAt))}'
      : '';
  return '$prefix ${_formatTaskClock(finishedAt)}$duration';
}

DateTime? _lastTaskEventTime(List<TaskEvent> events, String type) {
  for (final event in events.reversed) {
    if (event.type == type) return event.timestamp;
  }
  return null;
}

DateTime? _lastTerminalTaskEventTime(List<TaskEvent> events) {
  for (final event in events.reversed) {
    if (event.type == 'task.completed' ||
        event.type == 'task.failed' ||
        event.type == 'task.cancelled' ||
        event.type == 'task.unknown') {
      return event.timestamp;
    }
  }
  return null;
}

String _formatTaskDuration(Duration duration) {
  final seconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分 ${seconds % 60} 秒';
  final hours = minutes ~/ 60;
  return '$hours 小时 ${minutes % 60} 分';
}

String _formatTaskClock(DateTime timestamp) {
  final local = timestamp.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}';
}

Color _taskStatusColor(String status, ColorScheme colors) {
  return switch (status) {
    'running' || 'stopping' => colors.primary,
    'queued' || 'waiting' || 'uncertain' => colors.tertiary,
    'completed' => Colors.green,
    'failed' || 'interrupted' => colors.error,
    _ => colors.outline,
  };
}

class _EventPresentation {
  const _EventPresentation({required this.event, this.related});

  final TaskEvent event;
  final TaskEvent? related;
}

List<_EventPresentation> _eventPresentations(List<TaskEvent> events) {
  final presentations = <_EventPresentation>[];
  final consumed = <String>{};
  for (var index = 0; index < events.length; index++) {
    final event = events[index];
    if (consumed.contains(event.eventId)) continue;
    switch (event.type) {
      case 'assistant.delta':
      case 'task.started':
      case 'task.completed':
      case 'task.cancel_requested':
        continue;
      case 'tool.started':
        TaskEvent? related;
        for (var next = index + 1; next < events.length; next++) {
          final candidate = events[next];
          if ((candidate.type == 'tool.completed' ||
                  candidate.type == 'tool.failed') &&
              _sameToolEvent(event, candidate)) {
            related = candidate;
            consumed.add(candidate.eventId);
            break;
          }
        }
        presentations.add(_EventPresentation(event: event, related: related));
      case 'tool.completed':
      case 'tool.failed':
        presentations.add(_EventPresentation(event: event));
      default:
        presentations.add(_EventPresentation(event: event));
    }
  }
  return presentations;
}

bool _sameToolEvent(TaskEvent first, TaskEvent second) {
  final firstId = first.payload['id'];
  final secondId = second.payload['id'];
  if (firstId is String && secondId is String && firstId.isNotEmpty) {
    return firstId == secondId;
  }
  final firstCallId = first.payload['call_id'];
  final secondCallId = second.payload['call_id'];
  return firstCallId is String &&
      secondCallId is String &&
      firstCallId.isNotEmpty &&
      firstCallId == secondCallId;
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.controller,
    required this.presentation,
    super.key,
  });

  final AppController controller;
  final _EventPresentation presentation;

  @override
  Widget build(BuildContext context) {
    final event = presentation.event;
    if (_isToolEvent(event.type)) {
      return _ToolEventTile(
        controller: controller,
        started: event.type == 'tool.started' ? event : null,
        result: event.type == 'tool.started' ? presentation.related : event,
      );
    }
    if (_isStatusEvent(event.type)) {
      return _StatusTile(event: event);
    }
    return _MessageBubble(
      text: _eventBody(event),
      isUser: event.type == 'user.message',
      attachments: _readChatAttachments(event.payload['attachments']),
      controller: controller,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.text,
    required this.isUser,
    this.streaming = false,
    this.attachments = const [],
    this.controller,
  });

  final String text;
  final bool isUser;
  final bool streaming;
  final List<AiAttachment> attachments;
  final AppController? controller;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty && attachments.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final avatarColor = isUser ? colors.primary : colors.tertiary;
    final content = isUser
        ? SelectableText(text)
        : MarkdownBody(
            data: text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
          );
    final bubble = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isUser
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 5),
            bottomRight: Radius.circular(isUser ? 5 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (attachments.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final attachment in attachments)
                    ActionChip(
                      avatar: Icon(
                        attachment.isImage
                            ? Icons.image_outlined
                            : Icons.insert_drive_file_outlined,
                        size: 16,
                      ),
                      label: Text(
                        attachment.name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: controller == null || attachment.id == null
                          ? null
                          : () => _showStoredAttachment(
                              context,
                              controller!,
                              attachment,
                            ),
                    ),
                ],
              ),
            if (attachments.isNotEmpty && text.trim().isNotEmpty)
              const SizedBox(height: 6),
            if (text.trim().isNotEmpty) content,
            if (text.trim().isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: '复制整段消息',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制整段消息'),
                        duration: Duration(milliseconds: 900),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SizedBox(
            width: double.infinity,
            child: Row(
              mainAxisAlignment: isUser
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isUser) ...[
                  _MessageAvatar(
                    icon: streaming
                        ? Icons.autorenew_rounded
                        : Icons.auto_awesome_rounded,
                    color: avatarColor,
                    label: 'AI 回复',
                  ),
                  const SizedBox(width: 8),
                ],
                // Both sides use a flexible child so long messages wrap
                // inside the available width instead of leaving the screen.
                Flexible(fit: FlexFit.loose, child: bubble),
                if (isUser) ...[
                  const SizedBox(width: 8),
                  _MessageAvatar(
                    icon: Icons.person_outline_rounded,
                    color: avatarColor,
                    label: '你的消息',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageAvatar extends StatelessWidget {
  const _MessageAvatar({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      child: CircleAvatar(
        radius: 14,
        backgroundColor: color.withValues(alpha: 0.14),
        child: Icon(icon, size: 17, color: color),
      ),
    );
  }
}

class _ToolEventTile extends StatelessWidget {
  const _ToolEventTile({required this.controller, this.started, this.result});

  final AppController controller;
  final TaskEvent? started;
  final TaskEvent? result;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final failed = result?.type == 'tool.failed';
    final finished = result != null;
    final name = started?.payload['name'] ?? result?.payload['name'] ?? '工具';
    final status = failed
        ? '失败'
        : finished
        ? '已完成'
        : '执行中';
    final icon = failed
        ? Icons.error_outline_rounded
        : finished
        ? Icons.check_circle_outline_rounded
        : Icons.pending_outlined;
    final iconColor = failed
        ? colors.error
        : finished
        ? colors.primary
        : colors.secondary;
    final arguments = started?.payload['arguments'];
    final resultValue = result?.type == 'tool.failed'
        ? result?.payload['error'] ?? '执行失败'
        : result?.payload['result'];
    return Container(
      margin: const EdgeInsets.only(bottom: 3),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          minTileHeight: 32,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -4),
          tilePadding: const EdgeInsets.symmetric(horizontal: 6),
          childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
          leading: Icon(icon, color: iconColor, size: 17),
          title: Text(
            '$name · $status',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1),
          ),
          children: [
            if (arguments != null)
              _ToolDetail(title: '参数', value: _prettyValue(arguments)),
            if (resultValue is Map &&
                resultValue['attachment_id'] is String &&
                resultValue['mime_type'] is String)
              _GeneratedImagePreview(
                controller: controller,
                attachment: AiAttachment(
                  id: resultValue['attachment_id'] as String,
                  name: resultValue['name'] is String
                      ? resultValue['name'] as String
                      : 'generated-image',
                  mimeType: resultValue['mime_type'] as String,
                  byteLength: resultValue['bytes'] is int
                      ? resultValue['bytes'] as int
                      : null,
                ),
              ),
            if (result != null)
              _ToolDetail(title: '结果', value: _prettyValue(resultValue)),
          ],
        ),
      ),
    );
  }
}

class _GeneratedImagePreview extends StatelessWidget {
  const _GeneratedImagePreview({
    required this.controller,
    required this.attachment,
  });

  final AppController controller;
  final AiAttachment attachment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => _showStoredAttachment(context, controller, attachment),
        icon: const Icon(Icons.image_outlined, size: 16),
        label: const Text('查看生成图片'),
      ),
    );
  }
}

Future<void> _showStoredAttachment(
  BuildContext context,
  AppController controller,
  AiAttachment attachment,
) {
  final attachmentId = attachment.id;
  if (attachmentId == null) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(attachment.name, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 560,
        child: FutureBuilder<Uint8List>(
          future: controller.loadAttachmentBytes(attachmentId),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text('附件文件不可用');
            }
            final bytes = snapshot.data;
            if (bytes == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (!attachment.isImage) {
              return Text('${attachment.mimeType} · ${bytes.length} bytes');
            }
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 4,
              child: Image.memory(bytes, fit: BoxFit.contain),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 10, height: 1)),
          const SizedBox(height: 3),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.15,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.event});

  final TaskEvent event;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isError = event.type == 'task.failed' || event.type == 'task.unknown';
    final icon = switch (event.type) {
      'task.cancelled' => Icons.stop_circle_outlined,
      'task.recovered' => Icons.history_toggle_off_rounded,
      'task.unknown' => Icons.help_outline_rounded,
      _ => Icons.error_outline_rounded,
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 19),
          const SizedBox(width: 8),
          Expanded(child: Text(_eventBody(event))),
        ],
      ),
    );
  }
}

class _StreamingTile extends StatelessWidget {
  const _StreamingTile({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _MessageBubble(text: text, isUser: false, streaming: true);
  }
}

String _titleFromPrompt(String prompt) {
  final compact = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
  return compact.length <= 28 ? compact : '${compact.substring(0, 28)}...';
}

bool _isToolEvent(String type) =>
    type == 'tool.started' || type == 'tool.completed' || type == 'tool.failed';

bool _isStatusEvent(String type) =>
    type == 'task.cancelled' ||
    type == 'task.failed' ||
    type == 'task.unknown' ||
    type == 'task.recovered';

String _prettyValue(Object? value) {
  if (value is String) return value;
  if (value is Map && value['data_url'] is String) {
    return const JsonEncoder.withIndent('  ')
        .convert({'generated': true, 'image': '已生成并显示在上方'});
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return '$value';
  }
}

String _eventBody(TaskEvent event) {
  final payload = event.payload;
  switch (event.type) {
    case 'user.message':
    case 'assistant.completed':
      return '${payload['text'] ?? ''}';
    case 'task.failed':
    case 'task.unknown':
      return '${payload['error'] ?? '执行失败'}';
    case 'task.cancelled':
      return '任务已停止。';
    case 'task.recovered':
      return '手机应用上次关闭时任务仍在运行，未自动重放。';
    default:
      return '';
  }
}

List<AiAttachment> _readChatAttachments(Object? value) {
  if (value is! List) return const [];
  final attachments = <AiAttachment>[];
  for (final item in value) {
    if (item is! Map) continue;
    try {
      attachments.add(AiAttachment.fromJson(Map<String, Object?>.from(item)));
    } on FormatException {
      // Ignore one malformed historical attachment and keep the message.
    }
  }
  return attachments;
}

String _mimeTypeForName(String name) {
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'json' => 'application/json',
    'md' => 'text/markdown',
    'txt' || 'log' => 'text/plain',
    'html' || 'htm' => 'text/html',
    'csv' => 'text/csv',
    'xml' => 'application/xml',
    'yaml' || 'yml' => 'text/yaml',
    'dart' ||
    'js' ||
    'ts' ||
    'java' ||
    'kt' ||
    'py' ||
    'sh' ||
    'css' => 'text/plain',
    _ => 'application/octet-stream',
  };
}
