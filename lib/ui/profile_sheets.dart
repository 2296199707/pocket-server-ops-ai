import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../domain/models.dart';
import '../ssh/ssh_connection.dart';

String _randomHex(int byteCount) {
  final random = math.Random.secure();
  return List.generate(
    byteCount,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _newWindowsDeviceId() => 'windows-${_randomHex(6)}';

String _newWindowsAgentToken() => _randomHex(32);

Future<void> showComputerPairingDialog(
  BuildContext context,
  AppController controller,
  ServerProfile profile, {
  String? registrationError,
}) async {
  try {
    final pairing = await controller.computerPairingInfo(profile);
    final compact = jsonEncode(pairing);
    final formatted = const JsonEncoder.withIndent('  ').convert(pairing);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('电脑配对信息'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  profile.isDirectWindowsComputer
                      ? '直连配置已保存。手机和电脑加入同一 Tailscale 网络后，将下面配置粘贴到 Windows Agent。'
                      : registrationError == null
                      ? '设备已登记。Windows 端只需要下面这组信息，不需要中转 API Token。'
                      : '配置已保存，但设备登记失败。启动 Windows Agent 后可在电脑菜单中重新测试连接。',
                ),
                const SizedBox(height: 12),
                SelectableText(
                  formatted,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: compact));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('电脑配对信息已复制')));
              }
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制配置'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('读取电脑配对信息失败：$error')));
  }
}

Future<ComputerRelaySetup?> showComputerRelaySetupSheet(
  BuildContext context,
  AppController controller,
) {
  return showModalBottomSheet<ComputerRelaySetup>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _ComputerRelaySetupSheet(controller: controller),
  );
}

class _ComputerRelaySetupSheet extends StatefulWidget {
  const _ComputerRelaySetupSheet({required this.controller});

  final AppController controller;

  @override
  State<_ComputerRelaySetupSheet> createState() =>
      _ComputerRelaySetupSheetState();
}

class _ComputerRelaySetupSheetState extends State<_ComputerRelaySetupSheet> {
  late final TextEditingController _publicUrl;
  String? _selectedServerId;
  String _lastSuggestedUrl = '';
  bool _working = false;
  String _workingLabel = '';
  String? _error;
  ComputerRelayPackageTransfer? _packageTransfer;

  List<ServerProfile> get _relayServers => widget.controller.servers
      .where((server) => !server.isWindowsComputer)
      .toList(growable: false);

  ServerProfile? get _selectedServer {
    final id = _selectedServerId;
    if (id == null) return null;
    for (final server in _relayServers) {
      if (server.id == id) return server;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final servers = _relayServers;
    final pendingTransfer = widget.controller.pendingComputerRelayPackage;
    final savedId =
        pendingTransfer?.serverId ?? widget.controller.computerRelayServerId;
    _selectedServerId = servers.any((server) => server.id == savedId)
        ? savedId
        : servers.isEmpty
        ? null
        : servers.first.id;
    final selected = _selectedServer;
    _lastSuggestedUrl = selected == null
        ? ''
        : _suggestedComputerRelayUrl(selected);
    _packageTransfer = pendingTransfer;
    _publicUrl = TextEditingController(
      text:
          pendingTransfer?.relayUrl ??
          widget.controller.computerRelayUrl ??
          _lastSuggestedUrl,
    );
  }

  @override
  void dispose() {
    _publicUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final servers = _relayServers;
    final savedUrl = widget.controller.computerRelayUrl;
    final savedServer = widget.controller.computerRelayServer;
    return _SheetFrame(
      child: ListView(
        shrinkWrap: true,
        children: [
          Text('中转服务器设置', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            '请选择一台已绑定的 SSH 服务器作为唯一安装目标。手机不会遍历其他服务器；安装提示词允许 AI 在这台服务器上完成中转部署，并按现有站点结构接入 Caddy/Nginx。',
          ),
          if (savedUrl != null) ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('已保存的中转配置'),
              subtitle: Text('${savedServer?.name ?? '服务器已删除'} · $savedUrl'),
              trailing: TextButton(
                onPressed: _working ? null : _useSaved,
                child: const Text('直接使用'),
              ),
            ),
            const Divider(height: 1),
          ],
          if (servers.isEmpty) ...[
            const SizedBox(height: 20),
            const Text('请先在服务器页面添加一个 SSH 服务器。'),
          ] else ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _selectedServerId,
              decoration: const InputDecoration(labelText: '已绑定的 SSH 服务器'),
              items: [
                for (final server in servers)
                  DropdownMenuItem(
                    value: server.id,
                    child: Text(
                      '${server.name} · ${server.host}:${server.port}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _working
                  ? null
                  : (value) {
                      if (value == null) return;
                      final server = servers.firstWhere(
                        (item) => item.id == value,
                      );
                      final suggested = _suggestedComputerRelayUrl(server);
                      setState(() {
                        _selectedServerId = value;
                        _packageTransfer = null;
                        if (_publicUrl.text.trim().isEmpty ||
                            _publicUrl.text.trim() == _lastSuggestedUrl) {
                          _publicUrl.text = suggested;
                        }
                        _lastSuggestedUrl = suggested;
                      });
                    },
            ),
            TextFormField(
              controller: _publicUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '公网中转地址',
                hintText: 'https://relay.example.com/computer-relay',
                helperText: '自动按服务器地址填入建议值；必须与现有 HTTPS/WSS 反向代理一致。',
              ),
              onChanged: (_) {
                if (_packageTransfer != null) {
                  setState(() => _packageTransfer = null);
                }
              },
            ),
            const SizedBox(height: 12),
            Text(
              '手机可以上传离线安装包；如果中转已安装，也可以直接读取配置，不会重复上传。中转使用独立目录和 Compose 项目，AI 只为指定路径补充反向代理，不覆盖现有网站。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_packageTransfer != null) ...[
              const SizedBox(height: 16),
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '安装包已上传',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(_packageTransfer!.remotePath),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: EdgeInsets.zero,
                        title: const Text('查看安装提示词'),
                        children: [
                          SelectableText(_packageTransfer!.prompt),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _working ? null : _copyInstallPrompt,
                              icon: const Icon(Icons.copy_outlined),
                              label: const Text('复制提示词'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _working ? null : _readInstalledSetup,
              icon: const Icon(Icons.sync_outlined),
              label: Text(
                _packageTransfer == null ? '中转已安装，跳过上传并读取配置' : '我已让 AI 安装，读取配置',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _working ? null : _uploadPackage,
              icon: _working
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.install_desktop_outlined),
              label: Text(
                _working
                    ? _workingLabel
                    : _packageTransfer == null
                    ? '上传安装包并复制提示词'
                    : '重新上传安装包并复制提示词',
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _useSaved() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final setup = await widget.controller.configuredComputerRelay();
      if (setup == null) throw StateError('已保存的中转配置不可用，请重新安装并读取');
      if (mounted) Navigator.pop(context, setup);
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _uploadPackage() async {
    final server = _selectedServer;
    if (server == null) {
      setState(() => _error = '请选择已绑定的 SSH 服务器');
      return;
    }
    if (_publicUrl.text.trim().isEmpty) {
      setState(() => _error = '请输入公网中转地址');
      return;
    }
    final confirmed = await _confirmRelayPackageUpload(
      context,
      server: server,
      publicUrl: _publicUrl.text.trim(),
      remotePath: '/tmp/pocket-server-ops-computer-relay.tar.gz',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _working = true;
      _workingLabel = '正在上传安装包…';
      _error = null;
    });
    try {
      final transfer = await widget.controller.uploadComputerRelayPackage(
        server: server,
        publicUrl: _publicUrl.text,
        onFirstHostKey: (key) => _confirmRelayHostKey(context, key),
      );
      if (!mounted) return;
      setState(() {
        _packageTransfer = transfer;
        _working = false;
        _workingLabel = '';
      });
      await _copyInstallPrompt(showMessage: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = false;
          _workingLabel = '';
          _error = '$error';
        });
      }
    }
  }

  Future<void> _copyInstallPrompt({bool showMessage = false}) async {
    final transfer = _packageTransfer;
    if (transfer == null) return;
    await Clipboard.setData(ClipboardData(text: transfer.prompt));
    if (showMessage && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('安装包已上传，安装提示词已复制')));
    }
  }

  Future<void> _readInstalledSetup() async {
    final server = _selectedServer;
    final publicUrl = _publicUrl.text.trim();
    if (server == null) {
      setState(() => _error = '请选择已绑定的 SSH 服务器');
      return;
    }
    if (publicUrl.isEmpty) {
      setState(() => _error = '请输入公网中转地址');
      return;
    }
    setState(() {
      _working = true;
      _workingLabel = '正在读取中转配置…';
      _error = null;
    });
    try {
      final setup = await widget.controller.readComputerRelaySetup(
        server: server,
        publicUrl: publicUrl,
        onFirstHostKey: (key) => _confirmRelayHostKey(context, key),
      );
      if (mounted) Navigator.pop(context, setup);
    } catch (error) {
      if (mounted) {
        setState(() {
          _working = false;
          _workingLabel = '';
          _error = '$error';
        });
      }
    }
  }
}

String _suggestedComputerRelayUrl(ServerProfile server) {
  final rawHost = server.host.trim();
  final parsed = Uri.tryParse(
    rawHost.contains('://') ? rawHost : 'https://$rawHost',
  );
  if (parsed == null || parsed.host.isEmpty) return '';
  return parsed
      .replace(
        scheme: 'https',
        path: '/computer-relay',
        query: '',
        fragment: '',
      )
      .toString();
}

Future<bool> _confirmRelayHostKey(BuildContext context, SshHostKey key) async {
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认中转服务器指纹'),
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

Future<bool> _confirmRelayPackageUpload(
  BuildContext context, {
  required ServerProfile server,
  required String publicUrl,
  required String remotePath,
}) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认上传中转安装包'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('即将通过 SSH 向以下服务器上传离线中转安装包：'),
                const SizedBox(height: 12),
                Text(
                  server.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  '${server.username}@${server.host}:${server.port}',
                ),
                const SizedBox(height: 12),
                const Text('公网中转地址'),
                const SizedBox(height: 4),
                SelectableText(publicUrl),
                const SizedBox(height: 16),
                const Text(
                  '安装包只会写入当前服务器的临时目录。上传后由你指定的 AI 执行安装，并可在这台服务器上为指定地址配置 Caddy/Nginx；现有网站和其他路由必须保留。',
                ),
                const SizedBox(height: 8),
                SelectableText('上传路径：$remotePath'),
                const SizedBox(height: 8),
                Text(
                  '请确认该服务器供应商允许运行中转服务。部分供应商可能限制此类服务。',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认上传'),
            ),
          ],
        ),
      ) ??
      false;
}

Future<void> showServerEditor(
  BuildContext context,
  AppController controller, [
  ServerProfile? existing,
]) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _ServerEditorSheet(controller: controller, existing: existing),
  );
}

class _ServerEditorSheet extends StatefulWidget {
  const _ServerEditorSheet({required this.controller, this.existing});

  final AppController controller;
  final ServerProfile? existing;

  @override
  State<_ServerEditorSheet> createState() => _ServerEditorSheetState();
}

class _ServerEditorSheetState extends State<_ServerEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _secret;
  late final TextEditingController _passphrase;
  late final TextEditingController _directory;
  late final TextEditingController _relayUrl;
  late final TextEditingController _directUrl;
  late final TextEditingController _deviceId;
  late final TextEditingController _relayApiToken;
  late final TextEditingController _deviceToken;
  String _targetType = serverTargetTypeSsh;
  String _computerConnectionMode = windowsConnectionModeRelay;
  String _authType = 'password';
  bool _clearPassphrase = false;
  bool _saving = false;
  bool _refreshingRelayToken = false;
  String? _relayServerId;
  bool _relayServerSelectionChanged = false;
  String? _error;

  List<ServerProfile> get _relayServers => widget.controller.servers
      .where((server) => !server.isWindowsComputer)
      .toList(growable: false);

  ServerProfile? get _selectedRelayServer {
    final id = _relayServerId;
    if (id == null) return null;
    for (final server in _relayServers) {
      if (server.id == id) return server;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final profile = widget.existing;
    _name = TextEditingController(text: profile?.name);
    _host = TextEditingController(text: profile?.host);
    _port = TextEditingController(text: '${profile?.port ?? 22}');
    _username = TextEditingController(text: profile?.username);
    _secret = TextEditingController();
    _passphrase = TextEditingController();
    _directory = TextEditingController(text: profile?.defaultWorkingDirectory);
    _computerConnectionMode = profile?.isDirectWindowsComputer == true
        ? windowsConnectionModeDirect
        : windowsConnectionModeRelay;
    _relayUrl = TextEditingController(
      text: _computerConnectionMode == windowsConnectionModeRelay
          ? profile?.relayUrl
          : null,
    );
    _directUrl = TextEditingController(
      text: _computerConnectionMode == windowsConnectionModeDirect
          ? profile?.relayUrl
          : null,
    );
    _deviceId = TextEditingController(text: profile?.deviceId);
    _relayApiToken = TextEditingController();
    _deviceToken = TextEditingController();
    _targetType = profile?.targetType ?? serverTargetTypeSsh;
    _authType = profile?.isWindowsComputer == true
        ? 'password'
        : profile?.authType ?? 'password';
    final savedRelayServerId = widget.controller.computerRelayServerId;
    _relayServerId =
        _relayServers.any((server) => server.id == savedRelayServerId)
        ? savedRelayServerId
        : null;
    if (profile == null && _targetType == serverTargetTypeWindows) {
      _ensureWindowsPairingFields();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _secret.dispose();
    _passphrase.dispose();
    _directory.dispose();
    _relayUrl.dispose();
    _directUrl.dispose();
    _deviceId.dispose();
    _relayApiToken.dispose();
    _deviceToken.dispose();
    super.dispose();
  }

  void _ensureWindowsPairingFields() {
    if (_deviceId.text.trim().isEmpty) {
      _deviceId.text = _newWindowsDeviceId();
    }
    if (_deviceToken.text.trim().isEmpty) {
      _deviceToken.text = _newWindowsAgentToken();
    }
    if (_directory.text.trim().isEmpty) {
      _directory.text = r'C:\Users\Public\PocketServerOps';
    }
    if (_computerConnectionMode == windowsConnectionModeRelay &&
        _relayUrl.text.trim().isEmpty &&
        widget.controller.computerRelayUrl != null) {
      _relayUrl.text = widget.controller.computerRelayUrl!;
    }
    if (_computerConnectionMode == windowsConnectionModeRelay &&
        _relayUrl.text.trim().isEmpty) {
      final server = _selectedRelayServer;
      if (server != null) {
        final suggested = _suggestedComputerRelayUrl(server);
        if (suggested.isNotEmpty) {
          _relayUrl.text = suggested;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.existing == null ? '添加目标服务器' : '编辑目标服务器',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: _required,
            ),
            DropdownButtonFormField<String>(
              initialValue: _targetType,
              decoration: const InputDecoration(labelText: '目标类型'),
              items: const [
                DropdownMenuItem(
                  value: serverTargetTypeSsh,
                  child: Text('SSH 服务器'),
                ),
                DropdownMenuItem(
                  value: serverTargetTypeWindows,
                  child: Text('Windows 电脑'),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _targetType = value;
                  if (value == serverTargetTypeWindows) {
                    _secret.clear();
                    _passphrase.clear();
                    _clearPassphrase = false;
                    if (widget.existing == null ||
                        widget.existing?.isWindowsComputer != true) {
                      _ensureWindowsPairingFields();
                    }
                  }
                });
              },
            ),
            if (_targetType == serverTargetTypeWindows) ...[
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: windowsConnectionModeRelay,
                    icon: Icon(Icons.hub_outlined),
                    label: Text('中转'),
                  ),
                  ButtonSegment(
                    value: windowsConnectionModeDirect,
                    icon: Icon(Icons.lan_outlined),
                    label: Text('Tailscale 直连'),
                  ),
                ],
                selected: {_computerConnectionMode},
                onSelectionChanged: _saving
                    ? null
                    : (values) {
                        setState(() {
                          _computerConnectionMode = values.first;
                          _error = null;
                          _ensureWindowsPairingFields();
                        });
                      },
              ),
              const SizedBox(height: 12),
              if (_computerConnectionMode == windowsConnectionModeRelay) ...[
                DropdownButtonFormField<String>(
                  initialValue: _relayServerId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '中转服务器（SSH）'),
                  hint: const Text('请选择已绑定的 SSH 服务器'),
                  items: [
                    for (final server in _relayServers)
                      DropdownMenuItem(
                        value: server.id,
                        child: Text(
                          '${server.name} · ${server.host}:${server.port}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _saving || _refreshingRelayToken
                      ? null
                      : (value) {
                          if (value == null) return;
                          final server = _relayServers.firstWhere(
                            (item) => item.id == value,
                          );
                          setState(() {
                            _relayServerId = value;
                            _relayServerSelectionChanged = true;
                            _relayApiToken.clear();
                            if (_relayUrl.text.trim().isEmpty) {
                              final suggested = _suggestedComputerRelayUrl(
                                server,
                              );
                              if (suggested.isNotEmpty) {
                                _relayUrl.text = suggested;
                              }
                            }
                            _error = null;
                          });
                        },
                  validator: (value) =>
                      _targetType == serverTargetTypeWindows &&
                          _computerConnectionMode ==
                              windowsConnectionModeRelay &&
                          _relayServers.isNotEmpty
                      ? _required(value)
                      : null,
                ),
                if (_relayServers.isEmpty) const Text('请先添加一个 SSH 服务器作为中转服务器。'),
                TextFormField(
                  controller: _relayUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '中转服务器地址（手机）',
                    hintText: 'https://relay.example.com',
                  ),
                  validator: (value) =>
                      _targetType == serverTargetTypeWindows &&
                          _computerConnectionMode == windowsConnectionModeRelay
                      ? _required(value)
                      : null,
                ),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _chooseComputerRelay,
                  icon: const Icon(Icons.hub_outlined),
                  label: const Text('选择已绑定服务器一键设置中转'),
                ),
                TextFormField(
                  controller: _relayApiToken,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: '中转 API Token（仅手机）',
                    hintText: widget.existing == null
                        ? '选择中转服务器后点击刷新自动获取'
                        : '留空则保留已有 Token',
                    suffixIcon: IconButton(
                      tooltip: '从已选中转服务器读取 Token',
                      onPressed: _saving || _refreshingRelayToken
                          ? null
                          : _refreshRelayToken,
                      icon: _refreshingRelayToken
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_outlined),
                    ),
                  ),
                  validator: (value) {
                    if (_targetType == serverTargetTypeWindows &&
                        _computerConnectionMode == windowsConnectionModeRelay &&
                        (widget.existing == null ||
                            _relayServerSelectionChanged) &&
                        (value?.trim().isEmpty ?? true)) {
                      return '请先选择中转服务器后点击刷新';
                    }
                    return null;
                  },
                ),
              ] else ...[
                TextFormField(
                  controller: _directUrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '电脑直连地址',
                    hintText: 'http://100.64.0.10:8788',
                    helperText: '填写电脑的 Tailscale IP；同一局域网也可填写局域网 IP。',
                  ),
                  validator: (value) =>
                      _targetType == serverTargetTypeWindows &&
                          _computerConnectionMode == windowsConnectionModeDirect
                      ? _required(value)
                      : null,
                ),
              ],
              TextFormField(
                controller: _deviceId,
                decoration: InputDecoration(
                  labelText: 'Windows 设备 ID',
                  suffixIcon: IconButton(
                    tooltip: '重新生成设备 ID',
                    onPressed: () =>
                        setState(() => _deviceId.text = _newWindowsDeviceId()),
                    icon: const Icon(Icons.refresh_outlined),
                  ),
                ),
                validator: (value) => _targetType == serverTargetTypeWindows
                    ? _required(value)
                    : null,
              ),
              TextFormField(
                controller: _deviceToken,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Windows Agent Token',
                  hintText: widget.existing == null ? null : '留空则保留已有 Token',
                  suffixIcon: IconButton(
                    tooltip: '重新生成 Agent Token',
                    onPressed: () => setState(
                      () => _deviceToken.text = _newWindowsAgentToken(),
                    ),
                    icon: const Icon(Icons.refresh_outlined),
                  ),
                ),
                validator: (value) {
                  if (_targetType == serverTargetTypeWindows &&
                      widget.existing == null &&
                      (value?.trim().isEmpty ?? true)) {
                    return '请输入 Windows Agent Token';
                  }
                  return null;
                },
              ),
              Text(
                _computerConnectionMode == windowsConnectionModeDirect
                    ? '直连使用 Agent Token 认证；手机和电脑需要加入同一 Tailscale 网络。'
                    : '设备 ID 和 Agent Token 会自动生成；中转 API Token 只保存在手机。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else ...[
              TextFormField(
                controller: _host,
                decoration: const InputDecoration(labelText: '主机地址'),
                validator: _required,
              ),
              TextFormField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'SSH 端口'),
                validator: _portValidator,
              ),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
                validator: _required,
              ),
              DropdownButtonFormField<String>(
                initialValue: _authType,
                decoration: const InputDecoration(labelText: '认证方式'),
                items: const [
                  DropdownMenuItem(value: 'password', child: Text('密码')),
                  DropdownMenuItem(value: 'privateKey', child: Text('私钥 PEM')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      if (value != _authType) {
                        _secret.clear();
                        if (value != 'privateKey') _passphrase.clear();
                      }
                      _authType = value;
                      if (value != 'privateKey') _clearPassphrase = false;
                    });
                  }
                },
              ),
              TextFormField(
                controller: _secret,
                obscureText: _authType == 'password',
                maxLines: _authType == 'privateKey' ? 4 : 1,
                decoration: InputDecoration(
                  labelText: _authType == 'password' ? 'SSH 密码' : '私钥 PEM',
                  hintText: widget.existing == null ? null : '留空则保留已有凭据',
                ),
                validator: (value) {
                  if (widget.existing == null && (value?.isEmpty ?? true)) {
                    return '请输入密码或私钥';
                  }
                  return null;
                },
              ),
              if (_authType == 'privateKey') ...[
                TextFormField(
                  controller: _passphrase,
                  enabled: !_clearPassphrase,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '私钥口令（可选）'),
                ),
                if (widget.existing?.credentialPassphraseRef != null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('清除已有私钥口令'),
                    value: _clearPassphrase,
                    onChanged: (value) =>
                        setState(() => _clearPassphrase = value ?? false),
                  ),
              ],
              Text(
                '密码和私钥只保存在手机安全存储，不会发送给 AI。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            TextFormField(
              controller: _directory,
              decoration: const InputDecoration(labelText: '默认工作目录'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final savedProfile = await widget.controller.saveServer(
        existing: widget.existing,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text),
        username: _username.text.trim(),
        secret: _secret.text,
        workingDirectory: _directory.text.trim(),
        authType: _authType,
        passphrase: _passphrase.text,
        clearPassphrase: _clearPassphrase,
        targetType: _targetType,
        computerConnectionMode: _computerConnectionMode,
        relayUrl: _computerConnectionMode == windowsConnectionModeDirect
            ? _directUrl.text
            : _relayUrl.text,
        deviceId: _deviceId.text,
        relayApiToken: _relayApiToken.text,
        deviceToken: _deviceToken.text,
      );
      if (savedProfile.isWindowsComputer && mounted) {
        String? registrationError;
        try {
          await widget.controller.registerComputer(savedProfile);
        } catch (error) {
          registrationError = '$error';
        }
        if (!mounted) return;
        await showComputerPairingDialog(
          context,
          widget.controller,
          savedProfile,
          registrationError: registrationError,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _chooseComputerRelay() async {
    final setup = await showComputerRelaySetupSheet(context, widget.controller);
    if (!mounted || setup == null) return;
    setState(() {
      _relayServerId = setup.serverId;
      _relayUrl.text = setup.relayUrl;
      _relayApiToken.text = setup.apiToken;
      _relayServerSelectionChanged = false;
      _error = null;
    });
  }

  Future<void> _refreshRelayToken() async {
    final server = _selectedRelayServer;
    if (server == null) {
      setState(
        () => _error = _relayServers.isEmpty
            ? '请先添加一个 SSH 服务器作为中转服务器'
            : '请先选择中转服务器',
      );
      return;
    }

    var publicUrl = _relayUrl.text.trim();
    if (publicUrl.isEmpty) publicUrl = widget.controller.computerRelayUrl ?? '';
    if (publicUrl.isEmpty) {
      setState(() => _error = '请先选择中转服务器并填写公网中转地址');
      return;
    }
    setState(() {
      _refreshingRelayToken = true;
      _error = null;
    });
    try {
      final setup = await widget.controller.readComputerRelaySetup(
        server: server,
        publicUrl: publicUrl,
        onFirstHostKey: (key) => _confirmRelayHostKey(context, key),
      );
      if (!mounted) return;
      setState(() {
        _relayUrl.text = setup.relayUrl;
        _relayApiToken.text = setup.apiToken;
        _relayServerSelectionChanged = false;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _refreshingRelayToken = false);
    }
  }
}

Future<void> showProviderEditor(
  BuildContext context,
  AppController controller, [
  ProviderProfile? existing,
]) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) =>
        _ProviderEditorSheet(controller: controller, existing: existing),
  );
}

class _ProviderEditorSheet extends StatefulWidget {
  const _ProviderEditorSheet({required this.controller, this.existing});

  final AppController controller;
  final ProviderProfile? existing;

  @override
  State<_ProviderEditorSheet> createState() => _ProviderEditorSheetState();
}

class _ProviderEditorSheetState extends State<_ProviderEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _secret;
  String _imageModel = '';
  String _reasoningEffort = 'default';
  String _wireApi = 'responses';
  String _contextWindowMode = defaultContextWindowMode;
  bool _isDefault = false;
  bool _saving = false;
  bool _loadingModels = false;
  List<String> _models = const [];
  Map<String, ProviderModelMetadata> _modelMetadata = const {};
  final List<TextEditingController> _customReasoningInputs = [];
  final List<String> _customReasoningValues = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.existing;
    _name = TextEditingController(text: profile?.name);
    _baseUrl = TextEditingController(text: profile?.baseUrl);
    _model = TextEditingController(text: profile?.model);
    _imageModel = profile == null
        ? ''
        : widget.controller.imageModelFor(profile.id);
    _secret = TextEditingController();
    _reasoningEffort = profile?.reasoningEffort ?? 'default';
    _wireApi = profile?.wireApi ?? 'responses';
    _contextWindowMode = normalizeContextWindowMode(profile?.contextWindowMode);
    _isDefault = profile?.isDefault ?? false;
    _modelMetadata = profile?.modelMetadata ?? const {};
    for (final effort in profile?.customReasoningEfforts ?? const []) {
      _customReasoningInputs.add(TextEditingController(text: effort));
      _customReasoningValues.add(effort);
    }
    _models = {
      for (final key in _modelMetadata.keys)
        if (key.trim().isNotEmpty) key.trim(),
      for (final metadata in _modelMetadata.values)
        if (metadata.model.trim().isNotEmpty) metadata.model.trim(),
    }.toList()..sort();
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _secret.dispose();
    for (final input in _customReasoningInputs) {
      input.dispose();
    }
    super.dispose();
  }

  List<String> get _customReasoningEfforts => normalizeCustomReasoningEfforts(
    _customReasoningInputs.map((input) => input.text),
  );

  List<String> get _defaultModelOptions {
    final models = <String>{
      ..._models,
      if (_model.text.trim().isNotEmpty) _model.text.trim(),
    };
    return models.toList()..sort();
  }

  List<String> get _imageModelOptions {
    final models = <String>{
      ..._models,
      if (_imageModel.trim().isNotEmpty) _imageModel.trim(),
    };
    return models.toList()..sort();
  }

  ProviderProfile _draftProfile() {
    return ProviderProfile(
      id: widget.existing?.id ?? 'provider-editor',
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim(),
      reasoningEffort: _reasoningEffort,
      customReasoningEfforts: _customReasoningEfforts,
      wireApi: _wireApi,
      contextWindowMode: _contextWindowMode,
      apiKeyRef: widget.existing?.apiKeyRef,
      isDefault: _isDefault,
      modelMetadata: _modelMetadata,
    );
  }

  ProviderModelMetadata? get _selectedModelMetadata {
    final model = _model.text.trim();
    if (model.isEmpty) return null;
    return resolveProviderModelMetadata(_draftProfile(), model);
  }

  List<String> get _reasoningOptions => reasoningEffortValuesForModel(
    _draftProfile(),
    _model.text,
    preserveCurrent: _reasoningEffort,
  );

  String get _reasoningHelperText {
    final levels = _selectedModelMetadata?.supportedReasoningLevels;
    if (levels == null) return '供应商未返回能力列表，提供 Default / Low / High / Max';
    if (levels.isEmpty) return '供应商声明当前模型没有可调推理强度';
    return '按当前模型返回的 supported_reasoning_levels 显示';
  }

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              widget.existing == null ? '添加 AI 供应商' : '编辑 AI 供应商',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _ProviderPresetButton(
                  label: 'OpenAI',
                  onPressed: () => _applyPreset(
                    name: 'OpenAI',
                    baseUrl: 'https://api.openai.com/v1',
                    model: 'gpt-5.6',
                    wireApi: 'responses',
                  ),
                ),
                _ProviderPresetButton(
                  label: 'DeepSeek',
                  onPressed: () => _applyPreset(
                    name: 'DeepSeek',
                    baseUrl: 'https://api.deepseek.com/v1',
                    model: 'deepseek-chat',
                    wireApi: 'chat-completions',
                    imageModel: '',
                  ),
                ),
                _ProviderPresetButton(
                  label: 'OpenCode',
                  onPressed: () => _applyPreset(
                    name: 'OpenCode',
                    baseUrl: 'https://opencode.ai/zen/go/v1',
                    model: '',
                    wireApi: 'chat-completions',
                    imageModel: '',
                  ),
                ),
                _ProviderPresetButton(
                  label: '通用',
                  onPressed: () => _applyPreset(
                    name: '通用 OpenAI 兼容',
                    baseUrl: '',
                    model: '',
                    wireApi: 'responses',
                    imageModel: '',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
              validator: _required,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _baseUrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Base URL'),
              validator: _required,
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _models.isEmpty
                      ? TextFormField(
                          controller: _model,
                          decoration: const InputDecoration(labelText: '默认模型'),
                          validator: _required,
                          onChanged: (_) => setState(() {}),
                        )
                      : DropdownButtonFormField<String>(
                          initialValue:
                              _defaultModelOptions.contains(_model.text.trim())
                              ? _model.text.trim()
                              : null,
                          decoration: const InputDecoration(labelText: '默认模型'),
                          items: [
                            for (final model in _defaultModelOptions)
                              DropdownMenuItem(
                                value: model,
                                child: Text(model),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _model.text = value);
                            }
                          },
                        ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新模型列表',
                  onPressed: _loadingModels ? null : _loadModels,
                  icon: _loadingModels
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _imageModel.trim().isEmpty
                  ? ''
                  : _imageModelOptions.contains(_imageModel.trim())
                  ? _imageModel.trim()
                  : '',
              decoration: InputDecoration(
                labelText: '图片模型',
                helperText: _models.isEmpty
                    ? '先刷新模型列表；没有生图能力请选择“无”'
                    : '从同一模型列表中手动指定，应用不会猜测模型能力',
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('无')),
                for (final model in _imageModelOptions)
                  DropdownMenuItem(value: model, child: Text(model)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _imageModel = value);
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: wireApiOptions.contains(_wireApi)
                  ? _wireApi
                  : 'responses',
              decoration: const InputDecoration(labelText: '协议'),
              items: [
                for (final api in wireApiOptions)
                  DropdownMenuItem(value: api, child: Text(wireApiLabel(api))),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _wireApi = value);
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _reasoningEffort,
              decoration: InputDecoration(
                labelText: '默认推理强度',
                helperText: _reasoningHelperText,
              ),
              items: [
                for (final effort in _reasoningOptions)
                  DropdownMenuItem(
                    value: effort,
                    child: Text(_reasoningOptionLabel(effort)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _reasoningEffort = value);
              },
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '自定义推理值',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: '添加自定义推理值',
                  visualDensity: VisualDensity.compact,
                  onPressed: _addCustomReasoningEffort,
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
            Text(
              '仅供应商未提供的自定义值需要填写；保存时忽略空值和重复值。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            for (var index = 0; index < _customReasoningInputs.length; index++)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _customReasoningInputs[index],
                        decoration: InputDecoration(
                          labelText: '自定义推理值 ${index + 1}',
                          hintText: '例如 medium 或供应商自定义值',
                        ),
                        onChanged: (value) =>
                            _onCustomReasoningChanged(index, value),
                      ),
                    ),
                    IconButton(
                      tooltip: '删除自定义推理值',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _removeCustomReasoningEffort(index),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _contextWindowMode,
              decoration: const InputDecoration(labelText: '上下文窗口'),
              items: [
                for (final mode in contextWindowModeOptions)
                  DropdownMenuItem(
                    value: mode,
                    child: Text(contextWindowModeLabel(mode)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _contextWindowMode = value);
                }
              },
            ),
            const SizedBox(height: 10),
            Text(
              '默认使用 Codex 的 context_window；扩展使用模型提供的 '
              'max_context_window。模型没有更大上限时两档相同。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _secret,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: widget.existing == null ? null : '留空则保留已有 Key',
              ),
              validator: (value) {
                if (widget.existing == null && (value?.isEmpty ?? true)) {
                  return '请输入 API Key';
                }
                return null;
              },
            ),
            const SizedBox(height: 10),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('设为默认供应商'),
              value: _isDefault,
              onChanged: (value) => setState(() => _isDefault = value),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.saveProvider(
        existing: widget.existing,
        name: _name.text.trim(),
        baseUrl: _baseUrl.text.trim(),
        model: _model.text.trim(),
        reasoningEffort: _reasoningEffort,
        customReasoningEfforts: _customReasoningEfforts,
        wireApi: _wireApi,
        contextWindowMode: _contextWindowMode,
        secret: _secret.text,
        isDefault: _isDefault,
        modelMetadata: _modelMetadata,
        imageModel: _imageModel,
      );
      try {
        await widget.controller.loadProviderModelMetadata(saved);
      } catch (error) {
        if (mounted) {
          setState(() {
            _saving = false;
            _error = '供应商已保存，读取模型失败：$error';
          });
        }
        return;
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _loadModels() async {
    final profile = ProviderProfile(
      id: widget.existing?.id ?? 'model-test',
      name: _name.text.trim().isEmpty ? '模型测试' : _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      model: _model.text.trim().isEmpty ? 'unknown' : _model.text.trim(),
      reasoningEffort: _reasoningEffort,
      wireApi: _wireApi,
      contextWindowMode: _contextWindowMode,
      apiKeyRef: widget.existing?.apiKeyRef,
      isDefault: _isDefault,
      customReasoningEfforts: _customReasoningEfforts,
    );
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      final metadata = await widget.controller.loadProviderModelMetadata(
        profile,
        secret: _secret.text.isEmpty ? null : _secret.text,
      );
      if (mounted) {
        setState(() {
          _models = {
            for (final item in metadata)
              if (item.model.trim().isNotEmpty) item.model.trim(),
          }.toList()..sort();
          _modelMetadata = {
            ..._modelMetadata,
            for (final item in metadata)
              item.model: _modelMetadata[item.model]?.mergedWith(item) ?? item,
          };
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '读取模型失败：$error');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _applyPreset({
    required String name,
    required String baseUrl,
    required String model,
    required String wireApi,
    String imageModel = '',
  }) {
    setState(() {
      _name.text = name;
      _baseUrl.text = baseUrl;
      _model.text = model;
      _wireApi = wireApi;
      _imageModel = imageModel;
      _reasoningEffort = defaultReasoningEffort;
      for (final input in _customReasoningInputs) {
        input.dispose();
      }
      _customReasoningInputs.clear();
      _customReasoningValues.clear();
      _models = const [];
      _modelMetadata = const {};
    });
  }

  void _addCustomReasoningEffort() {
    setState(() {
      _customReasoningInputs.add(TextEditingController());
      _customReasoningValues.add('');
    });
  }

  void _onCustomReasoningChanged(int index, String value) {
    final previous = _customReasoningValues[index].trim();
    _customReasoningValues[index] = value;
    final previousStillConfigured = _customReasoningInputs.asMap().entries.any(
      (entry) => entry.key != index && entry.value.text.trim() == previous,
    );
    if (_reasoningEffort == previous && !previousStillConfigured) {
      _reasoningEffort = value.trim().isEmpty
          ? defaultReasoningEffort
          : value.trim();
    }
    setState(() {});
  }

  void _removeCustomReasoningEffort(int index) {
    final input = _customReasoningInputs.removeAt(index);
    _customReasoningValues.removeAt(index);
    final removed = input.text.trim();
    input.dispose();
    if (_reasoningEffort == removed &&
        !_customReasoningInputs.any((item) => item.text.trim() == removed)) {
      _reasoningEffort = defaultReasoningEffort;
    }
    setState(() {});
  }

  String _reasoningOptionLabel(String effort) {
    if (_customReasoningEfforts.contains(effort.trim())) {
      return '自定义：$effort';
    }
    final defaultLevel = _selectedModelMetadata?.defaultReasoningLevel;
    if (effort == defaultReasoningEffort && defaultLevel != null) {
      return '${reasoningEffortLabel(effort)}（目录默认：$defaultLevel）';
    }
    return '${reasoningEffortLabel(effort)}（$effort）';
  }
}

class _ProviderPresetButton extends StatelessWidget {
  const _ProviderPresetButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      child: Text(label),
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: child,
      ),
    );
  }
}

String? _required(String? value) {
  return value == null || value.trim().isEmpty ? '必填' : null;
}

String? _portValidator(String? value) {
  final port = int.tryParse(value ?? '');
  return port != null && port > 0 && port <= 65535 ? null : '请输入有效端口';
}
